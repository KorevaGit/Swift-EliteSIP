import Compat
import Foundation
import Testing
@testable import SIPCore

/// Приём входящего звонка целиком: от INVITE до ACK и BYE.
///
/// Проверяется именно то, что на живой АТС стоит дороже всего: коды и порядок
/// ответов, ретрансмиссия 200 OK до подтверждения, отмена вызова до ответа и
/// вторая линия. Каждый из этих случаев на Asterisk выглядит как «звонок
/// повис», и различить их без разбора трафика нельзя.
@Suite("Входящий звонок", .timeLimit(.minutes(1)))
struct IncomingCallTests {

    private static let offerSDP = """
        v=0\r
        o=root 1 1 IN IP4 172.17.0.2\r
        s=Asterisk\r
        c=IN IP4 172.17.0.2\r
        t=0 0\r
        m=audio 14002 RTP/AVP 0 101\r
        a=rtpmap:0 PCMU/8000\r
        a=rtpmap:101 telephone-event/8000\r
        a=sendrecv\r
        \r
        """

    private static let answerSDP = """
        v=0\r
        o=elitesip 1 1 IN IP4 192.168.1.50\r
        s=-\r
        c=IN IP4 192.168.1.50\r
        t=0 0\r
        m=audio 16000 RTP/AVP 0\r
        a=rtpmap:0 PCMU/8000\r
        a=sendrecv\r
        \r
        """

    /// INVITE в том виде, в каком его шлёт chan_sip с плеча очереди раздачи.
    private func makeInvite(
        callID: String = "incoming-1",
        from: String = "\"AutoDialer\" <sip:2929@172.17.0.2>;tag=as77aabb",
        branch: String = "z9hG4bKinbound1",
        sequence: Int = 102,
        contact: String? = "<sip:2929@172.17.0.2:5060>",
        body: String = offerSDP
    ) -> SIPRequest {
        var request = SIPRequest(
            method: .invite,
            uri: SIPURI(user: "100", host: "192.168.1.50"),
            body: Data(body.utf8)
        )
        request.headers.append(SIPHeaderName.via, "SIP/2.0/UDP 172.17.0.2:5060;branch=\(branch);rport")
        request.headers.append(SIPHeaderName.maxForwards, "70")
        request.headers.append(SIPHeaderName.from, from)
        request.headers.append(SIPHeaderName.to, "<sip:100@192.168.1.50>")
        request.headers.append(SIPHeaderName.callID, callID)
        request.headers.append(SIPHeaderName.cseq, "\(sequence) INVITE")
        if let contact {
            request.headers.append(SIPHeaderName.contact, contact)
        }
        request.headers.append(SIPHeaderName.contentType, "application/sdp")
        return request
    }

    /// ACK на 2xx: свой branch, тот же Call-ID и номер CSeq.
    private func makeACK(to invite: SIPRequest, toTag: String) -> SIPRequest {
        var ack = SIPRequest(method: .ack, uri: SIPURI(user: "100", host: "192.168.1.50"))
        ack.headers.append(SIPHeaderName.via, "SIP/2.0/UDP 172.17.0.2:5060;branch=z9hG4bKack-own")
        ack.headers.append(SIPHeaderName.from, invite.headers[SIPHeaderName.from] ?? "")
        ack.headers.append(SIPHeaderName.to, "<sip:100@192.168.1.50>;tag=\(toTag)")
        ack.headers.append(SIPHeaderName.callID, invite.callID ?? "")
        ack.headers.append(SIPHeaderName.cseq, "\(invite.cseq?.number ?? 1) ACK")
        return ack
    }

    private func registeredAgent(_ server: ScriptedSIPServer) async -> SIPUserAgent {
        let agent = SIPUserAgent(
            account: testAccount(transport: server.transport),
            credentials: testCredentials,
            channel: server,
            timers: fastTimers()
        )
        await agent.start()
        _ = await waitUntil { await agent.registrationState.isRegistered }
        return agent
    }

    private func acceptingServer() -> ScriptedSIPServer {
        ScriptedSIPServer(transport: .udp) { request, index in
            index == 0
                ? ScriptedSIPServer.unauthorized(to: request)
                : ScriptedSIPServer.registrationAccepted(to: request)
        }
    }

    /// Ждёт события входящего звонка от агента.
    private func awaitIncomingCall(from agent: SIPUserAgent) -> Task<SIPIncomingCall?, Never> {
        let events = agent.events
        return Task {
            for await event in events {
                if case .incomingCall(let call) = event { return call }
            }
            return nil
        }
    }

    /// Ждёт причины завершения звонка.
    private func awaitEnd(of call: SIPIncomingCall) -> Task<String?, Never> {
        let events = call.events
        return Task<String?, Never> {
            for await event in events {
                if case .ended(let reason) = event { return reason }
            }
            return nil
        }
    }

    // MARK: - Ответы на INVITE

    @Test("На INVITE отвечаем 100 и 180 — до всякого решения оператора")
    func ringsBeforeAnyDecision() async throws {
        let server = acceptingServer()
        let agent = await registeredAgent(server)
        let pending = awaitIncomingCall(from: agent)

        let invite = makeInvite()
        server.inject(request: invite)

        let call = try #require(await pending.value)
        #expect(call.callerNumber == "2929")
        #expect(call.callerName == "AutoDialer")
        #expect(call.calledNumber == "100")
        #expect(call.offer == invite.body)

        await agent.stop()

        let responses = server.sentResponses.filter { $0.cseq?.method == .invite }
        #expect(responses.map(\.statusCode).prefix(2) == [100, 180])

        // 180 обязан нести наш тег: по нему звонящий соберёт диалог, когда
        // придёт 200. Без тега Asterisk 200 OK не свяжет с этим вызовом.
        let ringing = try #require(responses.first { $0.statusCode == 180 })
        #expect(ringing.to?.tag != nil)
        #expect(ringing.callID == "incoming-1")
        #expect(ringing.contacts.isEmpty == false, "без Contact собеседнику некуда слать ACK")
    }

    @Test("Ответ на звонок уходит 200 OK с нашим SDP")
    func answersWithSDP() async throws {
        let server = acceptingServer()
        let agent = await registeredAgent(server)
        let pending = awaitIncomingCall(from: agent)

        server.inject(request: makeInvite())
        _ = try #require(await pending.value)

        let accepted = await agent.answerIncomingCall(answer: Data(Self.answerSDP.utf8))
        #expect(accepted)

        let ok = try #require(server.sentResponses.last { $0.statusCode == 200 && $0.cseq?.method == .invite })
        #expect(ok.body == Data(Self.answerSDP.utf8))
        #expect(ok.contentType == "application/sdp")
        #expect(ok.contacts.isEmpty == false)

        // Тег в 200 обязан совпасть с тем, что ушёл в 180: иначе это два
        // разных диалога, и ACK не найдёт ни один из них.
        let ringing = try #require(server.sentResponses.first { $0.statusCode == 180 })
        #expect(ok.to?.tag == ringing.to?.tag)

        await agent.stop()
    }

    @Test("Отклонение отвечает 486 — вызов вернётся в очередь следующему агенту")
    func rejectsWithBusy() async throws {
        let server = acceptingServer()
        let agent = await registeredAgent(server)
        let pending = awaitIncomingCall(from: agent)

        server.inject(request: makeInvite())
        let call = try #require(await pending.value)

        let ended = awaitEnd(of: call)

        await agent.rejectIncomingCall()
        #expect(await ended.value == PackageText.localized("отклонён"))

        let response = try #require(server.sentResponses.last { $0.cseq?.method == .invite })
        #expect(response.statusCode == 486)

        // Линия должна освободиться: следующий INVITE обязан снова зазвонить,
        // а не получить «занято» от призрака прошлого вызова.
        #expect(await agent.callState == nil)
        await agent.stop()
    }

    @Test("Вторая линия получает 486, а не молчание")
    func rejectsSecondCallAsBusy() async throws {
        let server = acceptingServer()
        let agent = await registeredAgent(server)
        let pending = awaitIncomingCall(from: agent)

        server.inject(request: makeInvite())
        _ = try #require(await pending.value)

        server.inject(request: makeInvite(callID: "incoming-2", branch: "z9hG4bKinbound2"))
        #expect(await waitUntil { server.sentResponses.contains { $0.callID == "incoming-2" } })
        await agent.stop()

        let second = try #require(server.sentResponses.last { $0.callID == "incoming-2" })
        #expect(second.statusCode == 486)
    }

    @Test("INVITE без Contact отклоняется: BYE по такому звонку слать некуда")
    func rejectsInviteWithoutContact() async throws {
        let server = acceptingServer()
        let agent = await registeredAgent(server)

        server.inject(request: makeInvite(contact: nil))
        #expect(await waitUntil { server.sentResponses.contains { $0.cseq?.method == .invite } })
        await agent.stop()

        let response = try #require(server.sentResponses.first { $0.cseq?.method == .invite })
        #expect(response.statusCode == 400)
    }

    // MARK: - Подтверждение

    @Test("200 OK повторяется, пока не придёт ACK")
    func retransmits200UntilACK() async throws {
        let server = acceptingServer()
        let agent = await registeredAgent(server)
        let pending = awaitIncomingCall(from: agent)

        let invite = makeInvite()
        server.inject(request: invite)
        _ = try #require(await pending.value)
        _ = await agent.answerIncomingCall(answer: Data(Self.answerSDP.utf8))

        let okCount: @Sendable () -> Int = {
            server.sentResponses.filter { $0.statusCode == 200 && $0.cseq?.method == .invite }.count
        }

        // На UDP потерянный 200 OK означает разговор, о котором знаем только мы:
        // INVITE после 2xx больше не повторяется, и второго шанса не будет.
        #expect(await waitUntil { okCount() >= 2 })

        let toTag = try #require(server.sentResponses.last { $0.statusCode == 200 }?.to?.tag)
        server.inject(request: makeACK(to: invite, toTag: toTag))

        // После ACK повторы обязаны прекратиться.
        try await Task.sleep(.milliseconds(400))
        let settled = okCount()
        try await Task.sleep(.milliseconds(400))
        #expect(okCount() == settled)

        await agent.stop()
    }

    @Test("ACK не повторяет ответ обратно: это подтверждение, а не запрос")
    func acknowledgementIsNotAnswered() async throws {
        let server = acceptingServer()
        let agent = await registeredAgent(server)
        let pending = awaitIncomingCall(from: agent)

        let invite = makeInvite()
        server.inject(request: invite)
        _ = try #require(await pending.value)
        _ = await agent.answerIncomingCall(answer: Data(Self.answerSDP.utf8))

        let toTag = try #require(server.sentResponses.last { $0.statusCode == 200 }?.to?.tag)
        server.inject(request: makeACK(to: invite, toTag: toTag))
        try await Task.sleep(.milliseconds(200))
        let afterACK = server.sentResponses.count

        server.inject(request: makeACK(to: invite, toTag: toTag))
        try await Task.sleep(.milliseconds(200))
        #expect(server.sentResponses.count == afterACK, "на повторный ACK отвечать нечем")

        await agent.stop()
    }

    @Test("Ретрансмиссия INVITE получает тот же 180, а не второй новый")
    func repeatsRingingForRetransmittedInvite() async throws {
        let server = acceptingServer()
        let agent = await registeredAgent(server)
        let pending = awaitIncomingCall(from: agent)

        let invite = makeInvite()
        server.inject(request: invite)
        _ = try #require(await pending.value)

        let before = server.sentResponses.count
        server.inject(request: invite)
        #expect(await waitUntil { server.sentResponses.count > before })
        await agent.stop()

        let ringing = server.sentResponses.filter { $0.statusCode == 180 }
        #expect(ringing.count >= 2)
        #expect(Set(ringing.compactMap { $0.to?.tag }).count == 1, "тег между ретрансмиссиями меняться не должен")
    }

    // MARK: - Отмена

    @Test("CANCEL до ответа: 200 на сам CANCEL и 487 на INVITE")
    func cancelBeforeAnswer() async throws {
        let server = acceptingServer()
        let agent = await registeredAgent(server)
        let pending = awaitIncomingCall(from: agent)

        let invite = makeInvite()
        server.inject(request: invite)
        let call = try #require(await pending.value)

        let ended = awaitEnd(of: call)

        var cancel = SIPRequest(method: .cancel, uri: SIPURI(user: "100", host: "192.168.1.50"))
        cancel.headers.append(SIPHeaderName.via, "SIP/2.0/UDP 172.17.0.2:5060;branch=z9hG4bKinbound1")
        cancel.headers.append(SIPHeaderName.from, invite.headers[SIPHeaderName.from] ?? "")
        cancel.headers.append(SIPHeaderName.to, "<sip:100@192.168.1.50>")
        cancel.headers.append(SIPHeaderName.callID, "incoming-1")
        cancel.headers.append(SIPHeaderName.cseq, "102 CANCEL")
        server.inject(request: cancel)

        #expect(await ended.value == PackageText.localized("отменён вызывающим"))
        await agent.stop()

        let cancelResponse = try #require(server.sentResponses.first { $0.cseq?.method == .cancel })
        #expect(cancelResponse.statusCode == 200)

        // 487 обязателен: без него Asterisk считает вызов живым и держит канал.
        let terminated = try #require(server.sentResponses.last { $0.cseq?.method == .invite })
        #expect(terminated.statusCode == 487)
    }

    // MARK: - Завершение

    @Test("BYE от собеседника завершает принятый звонок")
    func remoteByeEndsAnsweredCall() async throws {
        let server = acceptingServer()
        let agent = await registeredAgent(server)
        let pending = awaitIncomingCall(from: agent)

        let invite = makeInvite()
        server.inject(request: invite)
        let call = try #require(await pending.value)
        _ = await agent.answerIncomingCall(answer: Data(Self.answerSDP.utf8))

        let toTag = try #require(server.sentResponses.last { $0.statusCode == 200 }?.to?.tag)
        server.inject(request: makeACK(to: invite, toTag: toTag))

        let ended = awaitEnd(of: call)

        var bye = SIPRequest(method: .bye, uri: SIPURI(user: "100", host: "192.168.1.50"))
        bye.headers.append(SIPHeaderName.via, "SIP/2.0/UDP 172.17.0.2:5060;branch=z9hG4bKbye1")
        bye.headers.append(SIPHeaderName.from, invite.headers[SIPHeaderName.from] ?? "")
        bye.headers.append(SIPHeaderName.to, "<sip:100@192.168.1.50>;tag=\(toTag)")
        bye.headers.append(SIPHeaderName.callID, "incoming-1")
        bye.headers.append(SIPHeaderName.cseq, "103 BYE")
        server.inject(request: bye)

        #expect(await ended.value == PackageText.localized("собеседник завершил звонок"))
        await agent.stop()

        let response = try #require(server.sentResponses.last { $0.cseq?.method == .bye })
        #expect(response.statusCode == 200)
    }

    @Test("Свой отбой на принятом звонке уходит как BYE на Contact звонящего")
    func localHangUpSendsBye() async throws {
        let server = acceptingServer()
        let agent = await registeredAgent(server)
        let pending = awaitIncomingCall(from: agent)

        let invite = makeInvite()
        server.inject(request: invite)
        _ = try #require(await pending.value)
        _ = await agent.answerIncomingCall(answer: Data(Self.answerSDP.utf8))

        let toTag = try #require(server.sentResponses.last { $0.statusCode == 200 }?.to?.tag)
        server.inject(request: makeACK(to: invite, toTag: toTag))
        #expect(await waitUntil { await agent.callState == .answered })

        await agent.hangUp()
        #expect(await waitUntil { server.receivedRequests.contains { $0.method == .bye } })
        await agent.stop()

        let bye = try #require(server.receivedRequests.last { $0.method == .bye })
        // BYE идёт на Contact собеседника, а не на адрес из From: за NAT это
        // разные адреса, и второй никуда не ведёт.
        #expect(bye.uri.description.contains("2929@172.17.0.2:5060"))
        #expect(bye.callID == "incoming-1")
        // Свой тег в From, чужой в To — диалог со стороны отвечавшего зеркален.
        #expect(bye.from?.tag == toTag)
        #expect(bye.to?.tag == "as77aabb")
    }

    @Test("Отбой до ответа отвечает 486, а не шлёт CANCEL чужому запросу")
    func localHangUpBeforeAnswerRejects() async throws {
        let server = acceptingServer()
        let agent = await registeredAgent(server)
        let pending = awaitIncomingCall(from: agent)

        server.inject(request: makeInvite())
        _ = try #require(await pending.value)

        await agent.hangUp()
        await agent.stop()

        #expect(server.receivedRequests.contains { $0.method == .cancel } == false)
        let response = try #require(server.sentResponses.last { $0.cseq?.method == .invite })
        #expect(response.statusCode == 486)
    }
}
