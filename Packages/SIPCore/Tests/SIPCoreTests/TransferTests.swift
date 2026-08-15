import Foundation
import Testing
@testable import SIPCore

@Suite("Перевод", .timeLimit(.minutes(1)))
struct TransferTests {

    private let offer = Data(
        "v=0\r\no=- 1 1 IN IP4 10.0.0.5\r\ns=-\r\nc=IN IP4 10.0.0.5\r\nt=0 0\r\nm=audio 16000 RTP/AVP 0\r\n".utf8
    )

    private func server() -> ScriptedSIPServer {
        ScriptedSIPServer { request, _ in
            guard request.headers[SIPHeaderName.authorization] != nil else {
                return ScriptedSIPServer.unauthorized(to: request)
            }
            switch request.method {
            case .register:
                return ScriptedSIPServer.registrationAccepted(to: request)
            case .invite:
                return nil
            case .refer:
                return ScriptedSIPServer.response(to: request, status: 202)
            default:
                return ScriptedSIPServer.response(to: request, status: 200)
            }
        }
    }

    private func answeredAgent(
        _ server: ScriptedSIPServer
    ) async throws -> (agent: SIPUserAgent, invite: SIPRequest) {
        let agent = SIPUserAgent(
            account: testAccount(),
            credentials: testCredentials,
            channel: server,
            timers: fastTimers()
        )
        await agent.start()
        #expect(await waitUntil { await agent.registrationState.isRegistered })

        _ = await agent.placeCall(to: "600", offer: offer)
        #expect(await waitUntil {
            server.receivedRequests.filter { $0.method == .invite }.count >= 2
        })
        let invite = try #require(server.receivedRequests.last { $0.method == .invite })

        var ok = ScriptedSIPServer.response(
            to: invite,
            status: 200,
            extraHeaders: [(SIPHeaderName.contact, "<sip:600@172.17.0.2:5060>")]
        )
        ok.body = offer
        ok.headers.append(SIPHeaderName.contentType, "application/sdp")
        server.inject(response: ok)
        #expect(await waitUntil { await agent.callState == .answered })
        return (agent, invite)
    }

    private func notify(
        for invite: SIPRequest,
        status: Int,
        reason: String,
        terminated: Bool = true
    ) -> SIPRequest {
        var request = SIPRequest(
            method: .notify,
            uri: SIPURI(user: "100", host: "192.168.1.50"),
            body: Data("SIP/2.0 \(status) \(reason)\r\n".utf8)
        )
        request.headers.append(
            SIPHeaderName.via,
            "SIP/2.0/UDP 172.17.0.2:5060;branch=z9hG4bKnotify\(status)"
        )
        request.headers.append(SIPHeaderName.from, "<sip:600@127.0.0.1>;tag=as1a2b3c")
        request.headers.append(SIPHeaderName.to, invite.headers[SIPHeaderName.from] ?? "")
        request.headers.append(SIPHeaderName.callID, invite.callID ?? "")
        request.headers.append(SIPHeaderName.cseq, "3 NOTIFY")
        request.headers.append(SIPHeaderName.event, "refer")
        request.headers.append(
            SIPHeaderName.subscriptionState,
            terminated ? "terminated;reason=noresource" : "active;expires=60"
        )
        request.headers.append(SIPHeaderName.contentType, "message/sipfrag;version=2.0")
        return request
    }

    @Test("Слепой перевод: REFER принят, результат приходит в NOTIFY")
    func blindTransfer() async throws {
        let server = server()
        let (agent, invite) = try await answeredAgent(server)

        let events = await agent.transfer(to: "601")
        let collector = Task { () -> [SIPTransferEvent] in
            var result: [SIPTransferEvent] = []
            for await event in events { result.append(event) }
            return result
        }

        #expect(await waitUntil {
            server.receivedRequests.contains { $0.method == .refer }
        })
        let refer = try #require(server.receivedRequests.last { $0.method == .refer })
        #expect(refer.headers[SIPHeaderName.referTo] == "<sip:601@127.0.0.1>")
        #expect(refer.callID == invite.callID, "REFER обязан идти внутри исходного диалога")

        var foreign = notify(for: invite, status: 200, reason: "OK")
        foreign.headers.set(
            SIPHeaderName.from,
            to: "<sip:600@127.0.0.1>;tag=wrong-remote"
        )
        foreign.headers.set(
            SIPHeaderName.via,
            to: "SIP/2.0/UDP 172.17.0.2:5060;branch=z9hG4bKnotify-foreign"
        )
        foreign.headers.set(SIPHeaderName.cseq, to: "2 NOTIFY")
        server.inject(request: foreign)
        #expect(await waitUntil {
            server.sentResponses.contains {
                $0.cseq?.method == .notify && $0.statusCode == 481
            }
        })
        #expect(await agent.callState == .answered)

        server.inject(request: notify(for: invite, status: 200, reason: "OK"))
        #expect(await collector.value == [.accepted, .succeeded])
        #expect(await waitUntil {
            server.sentResponses.contains { $0.cseq?.method == .notify && $0.statusCode == 200 }
        })
        await agent.stop()
    }

    @Test("Консультационный перевод кодирует Replaces в Refer-To")
    func attendedTransferUsesReplaces() async throws {
        let server = server()
        let (agent, invite) = try await answeredAgent(server)
        let replacement = SIPDialogIdentifier(
            callID: "consult-42@example",
            localTag: "our-consult-tag",
            remoteTag: "their-consult-tag"
        )

        let events = await agent.transfer(to: "602", replacing: replacement)
        let collector = Task {
            for await event in events {
                if case .failed = event { return false }
                if event == .succeeded { return true }
            }
            return false
        }

        #expect(await waitUntil {
            server.receivedRequests.contains { $0.method == .refer }
        })
        let refer = try #require(server.receivedRequests.last { $0.method == .refer })
        let referTo = try #require(refer.headers[SIPHeaderName.referTo])
        #expect(referTo.hasPrefix("<sip:602@127.0.0.1?Replaces="))
        #expect(referTo.contains("consult-42%40example"))
        #expect(referTo.contains("%3Bto-tag%3Dtheir-consult-tag%3Bfrom-tag%3Dour-consult-tag"))

        server.inject(request: notify(for: invite, status: 200, reason: "OK"))
        #expect(await collector.value)
        await agent.stop()
    }

    @Test("Отказ созданного INVITE объясняется результатом NOTIFY")
    func transferFailureFromNotify() async throws {
        let server = server()
        let (agent, invite) = try await answeredAgent(server)

        let events = await agent.transfer(to: "999")
        let collector = Task { () -> [SIPTransferEvent] in
            var result: [SIPTransferEvent] = []
            for await event in events { result.append(event) }
            return result
        }

        #expect(await waitUntil {
            server.receivedRequests.contains { $0.method == .refer }
        })
        server.inject(request: notify(for: invite, status: 486, reason: "Busy Here"))

        let result = await collector.value
        #expect(result.first == .accepted)
        #expect(result.last == .failed(
            status: 486,
            reason: describeCallFailure(status: 486, reason: "Busy Here")
        ))
        await agent.stop()
    }

    @Test("message/sipfrag разбирает код и причину")
    func parsesSIPFragment() {
        let parsed = parseSIPFragmentStatus(Data("SIP/2.0 503 Service Unavailable\r\n".utf8))
        #expect(parsed?.status == 503)
        #expect(parsed?.reason == "Service Unavailable")
        #expect(parseSIPFragmentStatus(Data("garbage".utf8)) == nil)
    }

    /// Копия NOTIFY с другим branch и CSeq: одинаковые значения транспорт
    /// считает ретрансмиссией и отвечает кэшированным ответом, не поднимая
    /// запрос наверх.
    private func distinct(_ request: SIPRequest, mark: String, cseq: Int) -> SIPRequest {
        var copy = request
        copy.headers.set(
            SIPHeaderName.via,
            to: "SIP/2.0/UDP 172.17.0.2:5060;branch=z9hG4bKnotify-\(mark)"
        )
        copy.headers.set(SIPHeaderName.cseq, to: "\(cseq) NOTIFY")
        return copy
    }

    @Test("Подписка закрыта без финального кода — перевод не зависает")
    func terminatedNotifyWithoutFinalStatus() async throws {
        let server = server()
        let (agent, invite) = try await answeredAgent(server)

        let collected = EventLog()
        let events = await agent.transfer(to: "601")
        let collector = Task {
            for await event in events { await collected.append(event) }
        }

        #expect(await waitUntil {
            server.receivedRequests.contains { $0.method == .refer }
        })
        #expect(await waitUntil { await collected.events == [.accepted] })

        // chan_sip сообщает промежуточный код, а затем закрывает подписку, так и
        // не сказав судьбу созданного INVITE.
        server.inject(request: notify(for: invite, status: 100, reason: "Trying", terminated: false))
        server.inject(request: distinct(
            notify(for: invite, status: 100, reason: "Trying"),
            mark: "closing",
            cseq: 4
        ))

        #expect(
            await waitUntil { await collected.events.count == 2 },
            "закрытая подписка обязана завершить перевод, а не ждать таймаута"
        )
        if case .failed = await collected.events.last {} else {
            Issue.record("после terminated ожидался отказ, получено \(await collected.events)")
        }
        #expect(await agent.callState == .answered, "исходный разговор обязан сохраниться")
        collector.cancel()
        await agent.stop()
    }

    @Test("REFER с вызовом авторизации повторяется со свежим nonce")
    func retriesReferAfterChallenge() async throws {
        let referChallenges = Counter()
        let server = ScriptedSIPServer { request, _ in
            guard request.headers[SIPHeaderName.authorization] != nil else {
                return ScriptedSIPServer.unauthorized(to: request)
            }
            switch request.method {
            case .register:
                return ScriptedSIPServer.registrationAccepted(to: request)
            case .invite:
                return nil
            case .refer:
                // Первый REFER получает свежий вызов, как это делает chan_sip
                // после смены nonce.
                if referChallenges.next() == 0 {
                    return ScriptedSIPServer.unauthorized(to: request, nonce: "second-nonce")
                }
                return ScriptedSIPServer.response(to: request, status: 202)
            default:
                return ScriptedSIPServer.response(to: request, status: 200)
            }
        }
        let (agent, invite) = try await answeredAgent(server)

        let collected = EventLog()
        let events = await agent.transfer(to: "601")
        let collector = Task {
            for await event in events { await collected.append(event) }
        }

        #expect(await waitUntil {
            server.receivedRequests.filter { $0.method == .refer }.count == 2
        })
        let refers = server.receivedRequests.filter { $0.method == .refer }
        #expect(refers[0].cseq?.number != refers[1].cseq?.number, "повтор обязан взять новый CSeq")
        #expect(refers[1].headers[SIPHeaderName.authorization]?.contains("second-nonce") == true)

        server.inject(request: notify(for: invite, status: 200, reason: "OK"))
        #expect(await waitUntil { await collected.events == [.accepted, .succeeded] })
        collector.cancel()
        await agent.stop()
    }

    @Test("Собеседник положил трубку во время перевода")
    func remoteHangUpDuringTransfer() async throws {
        let server = server()
        let (agent, invite) = try await answeredAgent(server)

        let collected = EventLog()
        let events = await agent.transfer(to: "601")
        let collector = Task {
            for await event in events { await collected.append(event) }
        }
        #expect(await waitUntil { await collected.events == [.accepted] })

        var bye = SIPRequest(method: .bye, uri: SIPURI(user: "100", host: "192.168.1.50"))
        bye.headers.append(SIPHeaderName.via, "SIP/2.0/UDP 172.17.0.2:5060;branch=z9hG4bKbye1")
        bye.headers.append(SIPHeaderName.from, "<sip:600@127.0.0.1>;tag=as1a2b3c")
        bye.headers.append(SIPHeaderName.to, invite.headers[SIPHeaderName.from] ?? "")
        bye.headers.append(SIPHeaderName.callID, invite.callID ?? "")
        bye.headers.append(SIPHeaderName.cseq, "5 BYE")
        server.inject(request: bye)

        #expect(await waitUntil { await collected.events.count == 2 })
        if case .failed = await collected.events.last {} else {
            Issue.record("завершённый разговор обязан закрыть перевод отказом")
        }
        collector.cancel()
        await agent.stop()
    }

    @Test("Сервер не сообщил результат — перевод заканчивается таймаутом")
    func transferExpiresWithoutNotify() async throws {
        let server = server()
        let agent = SIPUserAgent(
            account: testAccount(),
            credentials: testCredentials,
            channel: server,
            timers: fastTimers(),
            transferResultTimeout: .milliseconds(200)
        )
        await agent.start()
        #expect(await waitUntil { await agent.registrationState.isRegistered })
        _ = await agent.placeCall(to: "600", offer: offer)
        #expect(await waitUntil {
            server.receivedRequests.filter { $0.method == .invite }.count >= 2
        })
        let invite = try #require(server.receivedRequests.last { $0.method == .invite })
        var ok = ScriptedSIPServer.response(
            to: invite,
            status: 200,
            extraHeaders: [(SIPHeaderName.contact, "<sip:600@172.17.0.2:5060>")]
        )
        ok.body = offer
        ok.headers.append(SIPHeaderName.contentType, "application/sdp")
        server.inject(response: ok)
        #expect(await waitUntil { await agent.callState == .answered })

        let events = await agent.transfer(to: "601")
        var result: [SIPTransferEvent] = []
        for await event in events { result.append(event) }

        #expect(result.first == .accepted)
        #expect(result.last == .failed(
            status: 408,
            reason: PackageText.localized("сервер не сообщил результат перевода")
        ))
        #expect(await agent.callState == .answered, "истёкший перевод не завершает разговор")
        await agent.stop()
    }

    @Test("Номер не может подставить второй SIP-заголовок")
    func rejectsHeaderInjectionInTarget() async {
        let server = server()
        let agent = SIPUserAgent(
            account: testAccount(),
            credentials: testCredentials,
            channel: server,
            timers: fastTimers()
        )

        let events = await agent.transfer(to: "601\r\nRefer-To: <sip:999@evil>")
        var result: SIPTransferEvent?
        for await event in events { result = event }

        #expect(result == .failed(status: 0, reason: SIPTransferError.invalidTarget.description))
        #expect(server.receivedRequests.isEmpty)
    }
}

/// Накопитель событий перевода: поток читается отдельной задачей, а проверки
/// смотрят на снимок, не дожидаясь конца потока.
private actor EventLog {
    private(set) var events: [SIPTransferEvent] = []
    func append(_ event: SIPTransferEvent) { events.append(event) }
}

/// Счётчик попыток для сценарного сервера: замыкание `@Sendable`, и хранить
/// состояние прямо в нём нельзя.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            defer { value += 1 }
            return value
        }
    }
}
