import Foundation
import Testing
@testable import SIPCore

@Suite("Исходящий звонок", .timeLimit(.minutes(1)))
struct CallTests {

    /// Сервер, который ведёт себя как настоящий: требует авторизацию у любого
    /// запроса без заголовка Authorization и принимает его с ним. Так проверка
    /// не зависит от порядка запросов и не ломается от лишней регистрации.
    private func makeServer() -> ScriptedSIPServer {
        ScriptedSIPServer { request, _ in
            guard request.headers["Authorization"] != nil else {
                return ScriptedSIPServer.unauthorized(to: request)
            }
            switch request.method {
            case .register:
                return ScriptedSIPServer.registrationAccepted(to: request)
            case .invite:
                // Ответ на INVITE присылаем вручную: их несколько.
                return nil
            default:
                return ScriptedSIPServer.response(to: request, status: 200)
            }
        }
    }

    private func makeAgent(_ server: ScriptedSIPServer) async -> SIPUserAgent {
        let agent = SIPUserAgent(
            account: testAccount(),
            credentials: testCredentials,
            channel: server,
            timers: fastTimers()
        )
        await agent.start()
        _ = await waitUntil { await agent.registrationState.isRegistered }
        return agent
    }

    private func sdpOffer() -> Data {
        Data("v=0\r\no=- 1 1 IN IP4 10.0.0.5\r\ns=EliteSIP\r\nc=IN IP4 10.0.0.5\r\nt=0 0\r\nm=audio 16384 RTP/AVP 0\r\n".utf8)
    }

    private func answer(to invite: SIPRequest, status: Int = 200) -> SIPResponse {
        let body = Data("v=0\r\no=root 1 1 IN IP4 172.17.0.2\r\ns=Asterisk\r\nc=IN IP4 172.17.0.2\r\nt=0 0\r\nm=audio 14028 RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\n".utf8)
        var response = ScriptedSIPServer.response(
            to: invite,
            status: status,
            extraHeaders: [
                (SIPHeaderName.contact, "<sip:600@172.17.0.2:5060>"),
                (SIPHeaderName.contentType, "application/sdp"),
            ]
        )
        response.body = body
        return response
    }

    private func lastInvite(_ server: ScriptedSIPServer) -> SIPRequest? {
        server.receivedRequests.last { $0.method == .invite }
    }

    @Test("Звонок доходит до ответа и подтверждается ACK")
    func callIsAnsweredAndAcknowledged() async throws {
        let server = makeServer()
        let agent = await makeAgent(server)

        let events = await agent.placeCall(to: "600", offer: sdpOffer())
        let collector = Task { () -> (states: [String], body: Data?) in
            var states: [String] = []
            var answerBody: Data?
            for await event in events {
                switch event {
                case .state(let state): states.append("\(state)")
                case .answered(let body, _): answerBody = body
                case .failed(let status, let reason): states.append("failed \(status) \(reason)")
                case .ended: return (states, answerBody)
                }
            }
            return (states, answerBody)
        }

        // chan_sip требует авторизацию и на INVITE, поэтому первый уходит без
        // неё, а второй — уже подписанный.
        #expect(await waitUntil { server.receivedRequests.filter { $0.method == .invite }.count >= 2 })
        let invite = try #require(lastInvite(server))
        #expect(invite.headers["Authorization"] != nil)
        #expect(invite.contentType == "application/sdp")
        #expect(!invite.body.isEmpty, "предложение SDP должно уехать в теле INVITE")

        server.inject(response: ScriptedSIPServer.response(to: invite, status: 100))
        server.inject(response: ScriptedSIPServer.response(to: invite, status: 180))
        server.inject(response: answer(to: invite))

        #expect(await waitUntil { await agent.callState == .answered })

        // ACK на 2xx уходит на Contact из ответа и вне транзакции.
        #expect(await waitUntil { server.receivedRequests.contains { $0.method == .ack } })
        let ack = try #require(server.receivedRequests.last { $0.method == .ack })
        #expect(ack.uri.host == "172.17.0.2", "ACK идёт на Contact собеседника, а не на адрес из To")
        #expect(ack.cseq?.number == invite.cseq?.number, "номер CSeq у ACK тот же, что у INVITE")
        #expect(ack.to?.tag != nil)

        await agent.hangUp()
        let result = await collector.value
        #expect(result.body?.isEmpty == false, "тело ответа должно дойти до вызывающего")

        await agent.stop()
    }

    @Test("Занято объясняется человеческим языком")
    func busyIsExplained() async throws {
        let server = makeServer()
        let agent = await makeAgent(server)

        let events = await agent.placeCall(to: "600", offer: sdpOffer())
        let collector = Task { () -> String? in
            for await event in events {
                if case .failed(_, let reason) = event { return reason }
            }
            return nil
        }

        #expect(await waitUntil { server.receivedRequests.filter { $0.method == .invite }.count >= 2 })
        let invite = try #require(lastInvite(server))
        server.inject(response: ScriptedSIPServer.response(to: invite, status: 486))

        // «Сервер ответил 486» оператору не говорит ничего, «занято» — говорит всё.
        #expect(await collector.value == "занято")
        #expect(await agent.callState == nil, "после отказа звонок не должен считаться активным")

        await agent.stop()
    }

    @Test("Отбой после ответа отправляет BYE внутри диалога")
    func hangUpSendsBye() async throws {
        let server = makeServer()
        let agent = await makeAgent(server)

        _ = await agent.placeCall(to: "600", offer: sdpOffer())
        #expect(await waitUntil { server.receivedRequests.filter { $0.method == .invite }.count >= 2 })
        let invite = try #require(lastInvite(server))
        server.inject(response: answer(to: invite))
        #expect(await waitUntil { await agent.callState == .answered })

        await agent.hangUp()

        #expect(await waitUntil { server.receivedRequests.contains { $0.method == .bye } })
        let bye = try #require(server.receivedRequests.last { $0.method == .bye })
        #expect(bye.uri.host == "172.17.0.2", "BYE идёт на Contact собеседника")
        #expect(bye.callID == invite.callID)
        #expect(bye.to?.tag != nil, "внутри диалога тег собеседника обязателен")
        // CSeq обязан вырасти: повтор номера сервер счёл бы ретрансмиссией.
        #expect((bye.cseq?.number ?? 0) > (invite.cseq?.number ?? 0))
        #expect(await agent.callState == nil)

        await agent.stop()
    }

    @Test("Отбой до ответа отправляет CANCEL, а не BYE")
    func hangUpBeforeAnswerCancels() async throws {
        let server = makeServer()
        let agent = await makeAgent(server)

        _ = await agent.placeCall(to: "600", offer: sdpOffer())
        #expect(await waitUntil { server.receivedRequests.filter { $0.method == .invite }.count >= 2 })
        let invite = try #require(lastInvite(server))
        server.inject(response: ScriptedSIPServer.response(to: invite, status: 180))
        #expect(await waitUntil { await agent.callState == .ringing })

        await agent.hangUp()

        // Диалога ещё нет — BYE отправлять некуда и незачем.
        #expect(await waitUntil { server.receivedRequests.contains { $0.method == .cancel } })
        #expect(!server.receivedRequests.contains { $0.method == .bye })

        await agent.stop()
    }

    @Test("Входящий BYE завершает звонок и получает 200")
    func inboundByeEndsCall() async throws {
        let server = makeServer()
        let agent = await makeAgent(server)

        let events = await agent.placeCall(to: "600", offer: sdpOffer())
        let collector = Task { () -> String? in
            for await event in events {
                if case .ended(let reason) = event { return reason }
            }
            return nil
        }

        #expect(await waitUntil { server.receivedRequests.filter { $0.method == .invite }.count >= 2 })
        let invite = try #require(lastInvite(server))
        server.inject(response: answer(to: invite))
        #expect(await waitUntil { await agent.callState == .answered })

        var bye = SIPRequest(method: .bye, uri: SIPURI(user: "100", host: "192.168.1.50"))
        bye.headers.append(SIPHeaderName.via, "SIP/2.0/UDP 172.17.0.2:5060;branch=z9hG4bKbye1")
        bye.headers.append(SIPHeaderName.from, "<sip:600@127.0.0.1>;tag=as1a2b3c")
        bye.headers.append(SIPHeaderName.to, invite.headers[SIPHeaderName.from] ?? "")
        bye.headers.append(SIPHeaderName.callID, invite.callID ?? "")
        bye.headers.append(SIPHeaderName.cseq, "1 BYE")
        server.inject(request: bye)

        // Ответить обязаны: иначе Asterisk повторяет BYE и держит диалог.
        #expect(await waitUntil { server.sentResponses.contains { $0.cseq?.method == .bye && $0.statusCode == 200 } })
        #expect(await collector.value == "собеседник завершил звонок")
        #expect(await agent.callState == nil)

        await agent.stop()
    }

    @Test("Второй звонок при активном первом отклоняется")
    func rejectsSecondCall() async throws {
        let server = makeServer()
        let agent = await makeAgent(server)

        _ = await agent.placeCall(to: "600", offer: sdpOffer())
        #expect(await waitUntil { !server.receivedRequests.filter { $0.method == .invite }.isEmpty })

        let second = await agent.placeCall(to: "601", offer: sdpOffer())
        var reason: String?
        for await event in second {
            if case .failed(_, let text) = event { reason = text }
        }
        // Линия одна: несколько появятся в M5 вместе с переводом.
        #expect(reason == "звонок уже идёт")

        await agent.stop()
    }

    @Test("Пустой номер отклоняется до отправки запроса")
    func rejectsEmptyTarget() async throws {
        let server = makeServer()
        let agent = await makeAgent(server)

        let before = server.receivedRequests.filter { $0.method == .invite }.count
        let events = await agent.placeCall(to: "   ", offer: sdpOffer())

        var reason: String?
        for await event in events {
            if case .failed(_, let text) = event { reason = text }
        }
        #expect(reason == "не задан номер")
        #expect(server.receivedRequests.filter { $0.method == .invite }.count == before)

        await agent.stop()
    }
}
