import Compat
import Foundation
import Testing
@testable import SIPCore

@Suite("Транзакция INVITE", .timeLimit(.minutes(1)))
struct InviteTransactionTests {

    /// Собирает актор транзакций поверх поддельного сервера, который сам ничего
    /// не отвечает: ответы тест присылает вручную, как это и происходит с
    /// INVITE — их несколько на один запрос.
    private func makeLayer(transport: SIPTransport = .udp) async -> (SIPTransactionLayer, ScriptedSIPServer) {
        let server = ScriptedSIPServer(transport: transport) { _, _ in nil }
        let layer = SIPTransactionLayer(channel: server, timers: fastTimers())
        await layer.start()
        _ = try? await layer.waitUntilReady()
        return (layer, server)
    }

    private func makeInvite(branch: String = "z9hG4bKinvite1") -> SIPRequest {
        var request = SIPRequest(method: .invite, uri: SIPURI(user: "600", host: "127.0.0.1"))
        request.headers.append(SIPHeaderName.via, "SIP/2.0/UDP 192.168.1.50:5060;branch=\(branch);rport")
        request.headers.append(SIPHeaderName.maxForwards, "70")
        request.headers.append(SIPHeaderName.from, "<sip:100@127.0.0.1>;tag=localtag")
        request.headers.append(SIPHeaderName.to, "<sip:600@127.0.0.1>")
        request.headers.append(SIPHeaderName.callID, "call-invite-1")
        request.headers.append(SIPHeaderName.cseq, "20 INVITE")
        request.headers.append(SIPHeaderName.contact, "<sip:100@192.168.1.50:5060>")
        return request
    }

    private func response(
        _ status: Int,
        toTag: String? = "servertag",
        branch: String = "z9hG4bKinvite1",
        contact: String? = "<sip:600@172.17.0.2:5060>"
    ) -> SIPResponse {
        var headers = SIPHeaders()
        headers.append(SIPHeaderName.via, "SIP/2.0/UDP 192.168.1.50:5060;branch=\(branch)")
        headers.append(SIPHeaderName.from, "<sip:100@127.0.0.1>;tag=localtag")
        if let toTag {
            headers.append(SIPHeaderName.to, "<sip:600@127.0.0.1>;tag=\(toTag)")
        } else {
            headers.append(SIPHeaderName.to, "<sip:600@127.0.0.1>")
        }
        headers.append(SIPHeaderName.callID, "call-invite-1")
        headers.append(SIPHeaderName.cseq, "20 INVITE")
        if let contact {
            headers.append(SIPHeaderName.contact, contact)
        }
        return SIPResponse(statusCode: status, headers: headers)
    }

    @Test("Гудки и ответ: 100, 180, 200")
    func provisionalThenSuccess() async throws {
        let (layer, server) = await makeLayer()
        let events = await layer.sendInvite(makeInvite())

        let collector = Task { () -> [String] in
            var names: [String] = []
            for await event in events {
                switch event {
                case .provisional(let response): names.append("prov\(response.statusCode)")
                case .success(let response): names.append("ok\(response.statusCode)")
                case .failure(let response): names.append("fail\(response.statusCode)")
                case .timeout: names.append("timeout")
                case .transportFailed: names.append("transport")
                }
            }
            return names
        }

        #expect(await waitUntil { server.receivedRequests.contains { $0.method == .invite } })
        server.inject(response: response(100, toTag: nil, contact: nil))
        server.inject(response: response(180, contact: nil))
        server.inject(response: response(200))

        let names = await collector.value
        #expect(names == ["prov100", "prov180", "ok200"])

        // ACK на 2xx слой НЕ отправляет: он идёт вне транзакции, по маршруту
        // диалога, и это обязанность вызывающей стороны.
        #expect(!server.receivedRequests.contains { $0.method == .ack })

        await layer.stop()
    }

    @Test("На неуспешный ответ слой сам отправляет ACK")
    func failureIsAcknowledgedByLayer() async throws {
        let (layer, server) = await makeLayer()
        let events = await layer.sendInvite(makeInvite())

        // Возвращаем первое же событие, каким бы оно ни было: если вместо отказа
        // придёт таймаут, сообщение об ошибке должно это показать, а не просто
        // сказать «не 486».
        let collector = Task { () -> String in
            for await event in events {
                switch event {
                case .provisional(let r): return "prov\(r.statusCode)"
                case .success(let r): return "ok\(r.statusCode)"
                case .failure(let r): return "fail\(r.statusCode)"
                case .timeout: return "timeout"
                case .transportFailed(let reason): return "transport:\(reason)"
                }
            }
            return "поток закрылся без событий"
        }

        #expect(await waitUntil { server.receivedRequests.contains { $0.method == .invite } })
        server.inject(response: response(486))

        let first = await collector.value
        #expect(first == "fail486", "первое событие: \(first)")

        // ACK на 3xx–6xx — часть транзакции, и отправить его обязан слой.
        #expect(await waitUntil { server.receivedRequests.contains { $0.method == .ack } })
        let ack = try #require(server.receivedRequests.last { $0.method == .ack })
        #expect(ack.topVia?.branch == "z9hG4bKinvite1", "ACK внутри транзакции несёт тот же branch")
        #expect(ack.to?.tag == "servertag")
        #expect(ack.cseq?.number == 20)

        await layer.stop()
    }

    @Test("Ретрансмиссия INVITE до первого ответа")
    func retransmitsUntilAnswered() async throws {
        let (layer, server) = await makeLayer()
        _ = await layer.sendInvite(makeInvite())

        // Таймер A: интервал удваивается без ограничения T2 — в отличие от
        // не-INVITE, где он упирается в T2.
        #expect(await waitUntil { server.receivedRequests.filter { $0.method == .invite }.count >= 2 })

        let invites = server.receivedRequests.filter { $0.method == .invite }
        #expect(invites[0].topVia?.branch == invites[1].topVia?.branch, "ретрансмиссия — тот же запрос")
        #expect(invites[0].cseq?.number == invites[1].cseq?.number)

        await layer.stop()
    }

    @Test("Первый 1xx прекращает ретрансмиссии")
    func provisionalStopsRetransmissions() async throws {
        let (layer, server) = await makeLayer()
        _ = await layer.sendInvite(makeInvite())

        #expect(await waitUntil { !server.receivedRequests.isEmpty })
        server.inject(response: response(180, contact: nil))

        // Даём заведомо больше нескольких интервалов T1.
        try await Task.sleep(.milliseconds(500))
        let count = server.receivedRequests.filter { $0.method == .invite }.count
        #expect(count <= 2, "после 1xx запрос повторять не нужно, отправлено \(count)")

        await layer.stop()
    }

    @Test("Молчание сервера заканчивается таймаутом, а гудки — нет")
    func timeoutOnlyWhileCalling() async throws {
        let (layer, server) = await makeLayer()

        // Таймер B с быстрыми таймерами — 50 мс * 64 = 3.2 с.
        let events = await layer.sendInvite(makeInvite())
        let collector = Task { () -> Bool in
            for await event in events {
                if case .timeout = event { return true }
            }
            return false
        }
        #expect(await collector.value, "без единого ответа транзакция обязана завершиться таймаутом")

        // А вот после 1xx таймера быть не должно: гудки могут идти сколько
        // угодно, и обрывать их — решение пользователя, а не стека.
        let second = await layer.sendInvite(makeInvite(branch: "z9hG4bKinvite2"))
        #expect(await waitUntil { server.receivedRequests.count >= 2 })
        server.inject(response: response(180, branch: "z9hG4bKinvite2", contact: nil))

        let stillRinging = Task { () -> Bool in
            for await event in second {
                if case .timeout = event { return false }
            }
            return true
        }
        try await Task.sleep(.seconds(4))
        #expect(!stillRinging.isCancelled)
        stillRinging.cancel()

        await layer.stop()
    }

    @Test("CANCEL отправляется с тем же branch и только до финального ответа")
    func cancelSharesBranchAndStops() async throws {
        let (layer, server) = await makeLayer()
        _ = await layer.sendInvite(makeInvite())

        #expect(await waitUntil { !server.receivedRequests.isEmpty })
        server.inject(response: response(180, contact: nil))

        let cancelled = try await layer.cancelInvite(branch: "z9hG4bKinvite1")
        #expect(cancelled)
        #expect(await waitUntil { server.receivedRequests.contains { $0.method == .cancel } })

        let cancel = try #require(server.receivedRequests.last { $0.method == .cancel })
        #expect(cancel.topVia?.branch == "z9hG4bKinvite1")
        #expect(cancel.cseq?.number == 20)

        // Отвечаем 487, как это делает сервер после CANCEL.
        server.inject(response: response(487))
        #expect(await waitUntil { server.receivedRequests.contains { $0.method == .ack } })

        // Отменять больше нечего.
        #expect(try await layer.cancelInvite(branch: "z9hG4bKinvite1") == false)

        await layer.stop()
    }

    @Test("Отмена неизвестной транзакции ничего не ломает")
    func cancelUnknownIsHarmless() async throws {
        let (layer, _) = await makeLayer()
        #expect(try await layer.cancelInvite(branch: "нет-такого") == false)
        await layer.stop()
    }

    @Test("На надёжном транспорте INVITE не повторяется")
    func noRetransmitOverTLS() async throws {
        let (layer, server) = await makeLayer(transport: .tls)
        _ = await layer.sendInvite(makeInvite())

        try await Task.sleep(.milliseconds(600))
        let count = server.receivedRequests.filter { $0.method == .invite }.count
        #expect(count == 1, "доставку гарантирует TCP, отправлено \(count)")

        await layer.stop()
    }
}
