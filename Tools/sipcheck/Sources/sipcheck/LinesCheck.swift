import Foundation
import MediaCore
import SIPCore

/// Живой прогон многолинейности против настоящего Asterisk.
///
/// Юнит-тесты проверяют, что клиент адресует линии правильно. Здесь проверяется
/// то, чего они увидеть не могут: как chan_sip ведёт себя с тремя диалогами
/// одного пира, доходит ли повторный INVITE на удержание по нужной линии, и
/// доводит ли сервер до конца REFER с Replaces. Звуковая карта не нужна: линий
/// три, а микрофон один, и подъём тракта здесь только мешал бы.
enum LinesCheck {

    /// Одна линия под проверкой: диалог, своя пара портов и счёт принятого.
    final class Probe: @unchecked Sendable {

        let number: String
        let callID: String
        let reservation: RTPPortReservation
        let offer: SessionDescription

        private let lock = NSLock()
        private var storage = Storage()
        private var sender: Task<Void, Never>?

        private struct Storage {
            var answered = false
            var failure: String?
            var ending: String?
            var negotiated: NegotiatedMedia?
            var rtp: RTPSession?
            var received = 0
            var local: SessionDescription?
        }

        init(number: String, callID: String, reservation: RTPPortReservation, offer: SessionDescription) {
            self.number = number
            self.callID = callID
            self.reservation = reservation
            self.offer = offer
            storage.local = offer
        }

        var isAnswered: Bool { lock.withLock { storage.answered } }
        var failure: String? { lock.withLock { storage.failure } }
        var ending: String? { lock.withLock { storage.ending } }
        var negotiated: NegotiatedMedia? { lock.withLock { storage.negotiated } }
        var received: Int { lock.withLock { storage.received } }
        var localDescription: SessionDescription? { lock.withLock { storage.local } }

        func remember(local description: SessionDescription) {
            lock.withLock { storage.local = description }
        }

        func fail(_ reason: String) { lock.withLock { storage.failure = reason } }
        func end(_ reason: String) { lock.withLock { storage.ending = reason } }

        /// Обнуляет счёт принятого — так меряется поток за конкретный отрезок.
        func resetReceived() { lock.withLock { storage.received = 0 } }

        /// Поднимает поток RTP по согласованным параметрам и начинает слать
        /// тишину. Звуковой карты здесь нет: важно, что путь живой в обе
        /// стороны, а не как он звучит.
        func startStream(negotiated media: NegotiatedMedia) throws {
            let rtp = try RTPSession(
                configuration: .init(negotiated: media),
                localPort: reservation.rtpPort,
                remoteHost: media.remoteAddress,
                remotePort: media.remotePort
            )
            rtp.onReceivedPacket = { [weak self] _ in
                guard let self else { return }
                lock.withLock { storage.received += 1 }
            }
            reservation.activate()
            rtp.start()

            lock.withLock {
                storage.answered = true
                storage.negotiated = media
                storage.rtp = rtp
            }

            let silence = SIPCheck.silenceFrame(for: media)
            let interval = media.packetTimeMilliseconds
            sender = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    lock.withLock { storage.rtp }?.send(encodedFrame: silence)
                    try? await Task.sleep(for: .milliseconds(interval))
                }
            }
        }

        func stop() {
            sender?.cancel()
            sender = nil
            lock.withLock { storage.rtp }?.stop()
            reservation.release()
        }
    }

    // MARK: - Общая часть

    /// Заводит линию и доводит её до разговора.
    private static func openLine(
        agent: SIPUserAgent,
        to number: String,
        address: String,
        codecs: [AudioCodec],
        secureMedia: Bool,
        timeout: Double = 20
    ) async -> Probe? {
        let reservation: RTPPortReservation
        do {
            reservation = try RTPSession.reservePortPair()
        } catch {
            print("❌ не удалось занять порт RTP: \(error)")
            return nil
        }

        let offer = SDPNegotiator.makeOffer(
            address: address,
            port: reservation.rtpPort,
            codecs: codecs,
            security: secureMedia ? .sdesRequired : .none
        )

        let call = await agent.placeCall(to: number, offer: offer.encodedData)
        let probe = Probe(
            number: number,
            callID: call.callID,
            reservation: reservation,
            offer: offer
        )
        print("→ линия \(number): Call-ID \(call.callID), RTP \(reservation.rtpPort)/\(reservation.rtcpPort)")

        Task {
            for await event in call.events {
                switch event {
                case .state(let state):
                    print("   \(number): \(state)")
                case .answered(let body, _):
                    do {
                        let answer = try SessionDescription(parsing: body)
                        let media = try SDPNegotiator.resolveAnswer(answer, toOffer: offer, supported: codecs)
                        try probe.startStream(negotiated: media)
                        print("   \(number): согласовано \(media.codec.sdpName) на \(media.remoteAddress):\(media.remotePort)")
                    } catch {
                        probe.fail("разбор ответа SDP не удался: \(error)")
                    }
                case .failed(_, let reason):
                    probe.fail(reason)
                case .ended(let reason):
                    probe.end(reason)
                }
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if probe.isAnswered || probe.failure != nil || probe.ending != nil { break }
            try? await Task.sleep(for: .milliseconds(100))
        }

        if let failure = probe.failure ?? probe.ending {
            print("❌ линия \(number) не поднялась: \(failure)")
            probe.stop()
            return nil
        }
        guard probe.isAnswered else {
            print("❌ линия \(number): ответа не дождались")
            probe.stop()
            return nil
        }
        return probe
    }

    /// Ставит линию на удержание или снимает — тем же путём, что приложение.
    @discardableResult
    private static func setHold(
        _ hold: Bool,
        on probe: Probe,
        agent: SIPUserAgent,
        codecs: [AudioCodec]
    ) async -> Bool {
        guard let local = probe.localDescription else { return false }
        let reoffer = SDPNegotiator.makeReoffer(from: local, direction: hold ? .sendonly : .sendrecv)
        do {
            let answerBody = try await agent.reinvite(callID: probe.callID, offer: reoffer.encodedData)
            probe.remember(local: reoffer)
            if !answerBody.isEmpty {
                let answer = try SessionDescription(parsing: answerBody)
                _ = try SDPNegotiator.resolveAnswer(answer, toOffer: reoffer, supported: codecs)
            }
            print("   \(probe.number): \(hold ? "на удержании" : "вернулась в разговор")")
            return true
        } catch {
            print("❌ \(probe.number): \(hold ? "удержание" : "возврат") не удалось: \(error)")
            return false
        }
    }

    private static func measure(_ probe: Probe, seconds: Double) async -> Int {
        probe.resetReceived()
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
        return probe.received
    }

    // MARK: - Параллельные линии

    /// Три линии сразу: свои пары портов, своё удержание, свой отбой.
    static func runParallel(
        agent: SIPUserAgent,
        host: String,
        numbers: [String],
        codecs: [AudioCodec],
        secureMedia: Bool
    ) async -> Bool {
        let address = await agent.mediaAddress ?? host
        var probes: [Probe] = []
        var passed = true

        func finish() async {
            for probe in probes {
                await agent.hangUp(callID: probe.callID)
                probe.stop()
            }
        }

        print("\n=== Параллельные линии: \(numbers.joined(separator: ", "))")

        for number in numbers {
            // Активная линия уходит на удержание перед следующей — ровно так же,
            // как это делает панель при консультации.
            if let current = probes.last {
                guard await setHold(true, on: current, agent: agent, codecs: codecs) else {
                    passed = false
                    await finish()
                    return false
                }
            }

            guard let probe = await openLine(
                agent: agent,
                to: number,
                address: address,
                codecs: codecs,
                secureMedia: secureMedia
            ) else {
                await finish()
                return false
            }
            probes.append(probe)

            let lines = await agent.lines
            print("   линий у агента: \(lines.count) — \(lines.map(\.peer).joined(separator: ", "))")
        }

        // 1. Пары портов не пересекаются. Это та самая резервация из M6b,
        //    только теперь их три и живут они одновременно.
        let rtpPorts = probes.map(\.reservation.rtpPort)
        let rtcpPorts = probes.map(\.reservation.rtcpPort)
        let distinct = Set(rtpPorts).count == probes.count
            && Set(rtcpPorts).count == probes.count
            && Set(rtpPorts).isDisjoint(with: Set(rtcpPorts))
        print(distinct
            ? "✅ пары RTP/RTCP различны: \(zip(rtpPorts, rtcpPorts).map { "\($0)/\($1)" }.joined(separator: " "))"
            : "❌ пары портов пересеклись: \(rtpPorts) / \(rtcpPorts)")
        passed = passed && distinct

        // 2. Четвёртая линия отклоняется, не отправляя INVITE.
        let extra = await agent.placeCall(to: numbers.first ?? "600", offer: probes[0].offer.encodedData)
        var extraFailure: String?
        for await event in extra.events {
            if case .failed(_, let reason) = event { extraFailure = reason }
        }
        let rejected = extraFailure?.contains("линии") == true
        print(rejected
            ? "✅ линия сверх потолка отклонена: \(extraFailure ?? "")"
            : "❌ линия сверх потолка не отклонена: \(extraFailure ?? "нет отказа")")
        passed = passed && rejected

        // 3. Поток идёт по активной линии и не идёт по удержанным.
        guard let active = probes.last else { return false }
        let held = probes.dropLast()
        for probe in held { probe.resetReceived() }
        let activeCount = await measure(active, seconds: 3)
        let heldCounts = held.map(\.received)

        print(activeCount > 0
            ? "✅ активная линия \(active.number) принимает RTP: \(activeCount) пакетов за 3 с"
            : "❌ активная линия \(active.number) не принимает RTP")
        passed = passed && activeCount > 0
        for (probe, count) in zip(held, heldCounts) {
            // Сервер на удержании обычно замолкает, но это его право, а не наша
            // гарантия: чужой звук мы всё равно не отдаём в тракт. Поэтому здесь
            // цифра для протокола, а не приговор.
            print("   удержанная линия \(probe.number): \(count) пакетов за те же 3 с")
        }

        // 4. Возврат на первую линию: удержание снимается именно с неё.
        guard let first = probes.first, probes.count > 1 else {
            await finish()
            return passed
        }
        _ = await setHold(true, on: active, agent: agent, codecs: codecs)
        let returned = await setHold(false, on: first, agent: agent, codecs: codecs)
        passed = passed && returned

        let firstCount = await measure(first, seconds: 3)
        print(firstCount > 0
            ? "✅ линия \(first.number) вернулась в разговор: \(firstCount) пакетов за 3 с"
            : "❌ линия \(first.number) после возврата молчит")
        passed = passed && firstCount > 0

        // 5. Отбой одной линии не трогает остальные.
        let victim = probes.removeLast()
        await agent.hangUp(callID: victim.callID)
        victim.stop()
        try? await Task.sleep(for: .milliseconds(500))
        let survivors = await agent.lines
        let survived = survivors.count == probes.count
            && !survivors.contains { $0.callID == victim.callID }
        print(survived
            ? "✅ после отбоя \(victim.number) остались линии: \(survivors.map(\.peer).joined(separator: ", "))"
            : "❌ отбой одной линии задел остальные: осталось \(survivors.count)")
        passed = passed && survived

        await finish()
        try? await Task.sleep(for: .milliseconds(500))
        let left = await agent.lines
        print(left.isEmpty ? "✅ все линии закрыты" : "❌ линии остались: \(left.map(\.peer))")
        return passed && left.isEmpty
    }

    // MARK: - Консультационный перевод

    /// Клиент на удержании, разговор с коллегой, REFER с Replaces.
    static func runConsultation(
        agent: SIPUserAgent,
        host: String,
        client: String,
        colleague: String,
        codecs: [AudioCodec],
        secureMedia: Bool
    ) async -> Bool {
        let address = await agent.mediaAddress ?? host
        print("\n=== Консультационный перевод: клиент \(client), коллега \(colleague)")

        guard let clientLine = await openLine(
            agent: agent, to: client, address: address, codecs: codecs, secureMedia: secureMedia
        ) else { return false }

        guard await setHold(true, on: clientLine, agent: agent, codecs: codecs) else {
            await agent.hangUp(callID: clientLine.callID)
            clientLine.stop()
            return false
        }

        guard let colleagueLine = await openLine(
            agent: agent, to: colleague, address: address, codecs: codecs, secureMedia: secureMedia
        ) else {
            await agent.hangUp(callID: clientLine.callID)
            clientLine.stop()
            return false
        }

        guard let replaces = await agent.dialogIdentifier(of: colleagueLine.callID) else {
            print("❌ консультационный диалог не собрался — Replaces собрать не из чего")
            await agent.hangUp(callID: colleagueLine.callID)
            await agent.hangUp(callID: clientLine.callID)
            colleagueLine.stop()
            clientLine.stop()
            return false
        }
        print("→ REFER по линии \(client), Replaces = \(replaces.headerValue)")

        var outcome: SIPTransferEvent?
        let events = await agent.transfer(
            callID: clientLine.callID,
            to: colleague,
            replacing: replaces
        )
        for await event in events {
            print("   перевод: \(event)")
            outcome = event
            if case .accepted = event { continue }
            break
        }

        let succeeded = outcome == .succeeded
        print(succeeded
            ? "✅ сервер подтвердил консультационный перевод"
            : "❌ перевод не подтверждён: \(outcome.map { "\($0)" } ?? "результата не было")")

        // После успеха обе наши ноги не нужны. Порядок тот же, что в панели.
        await agent.hangUp(callID: clientLine.callID)
        await agent.hangUp(callID: colleagueLine.callID)
        clientLine.stop()
        colleagueLine.stop()

        try? await Task.sleep(for: .milliseconds(500))
        let left = await agent.lines
        print(left.isEmpty ? "✅ линии закрыты" : "❌ линии остались: \(left.map(\.peer))")
        return succeeded && left.isEmpty
    }
}
