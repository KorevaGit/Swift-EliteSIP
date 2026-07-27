import Foundation
import Testing
@testable import SIPCore

@Suite("Входящие запросы", .timeLimit(.minutes(1)))
struct InboundRequestTests {

    /// OPTIONS в том виде, в каком его шлёт chan_sip при qualify=yes.
    private func makeOptions(callID: String = "qualify-1", cseq: Int = 102) -> SIPRequest {
        var request = SIPRequest(method: .options, uri: SIPURI(user: "100", host: "192.168.1.50"))
        request.headers.append(SIPHeaderName.via, "SIP/2.0/UDP 172.17.0.2:5060;branch=z9hG4bK\(callID);rport")
        request.headers.append(SIPHeaderName.maxForwards, "70")
        request.headers.append(SIPHeaderName.from, "\"asterisk\" <sip:asterisk@172.17.0.2>;tag=as3f4d5e")
        request.headers.append(SIPHeaderName.to, "<sip:100@192.168.1.50>")
        request.headers.append(SIPHeaderName.callID, callID)
        request.headers.append(SIPHeaderName.cseq, "\(cseq) OPTIONS")
        return request
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

    private func acceptingServer(transport: SIPTransport = .udp) -> ScriptedSIPServer {
        ScriptedSIPServer(transport: transport) { request, index in
            index == 0
                ? ScriptedSIPServer.unauthorized(to: request)
                : ScriptedSIPServer.registrationAccepted(to: request)
        }
    }

    @Test("На OPTIONS отвечаем 200 — иначе пир уходит в UNREACHABLE")
    func answersOptions() async throws {
        let server = acceptingServer()
        let agent = await registeredAgent(server)

        let options = makeOptions()
        server.inject(request: options)

        #expect(await waitUntil { !server.sentResponses.isEmpty })
        await agent.stop()

        let response = try #require(server.sentResponses.first)
        #expect(response.statusCode == 200)

        // Ответ обязан вернуть Via, Call-ID и CSeq запроса: по ним Asterisk
        // сопоставляет его со своей транзакцией.
        #expect(response.topVia?.branch == options.topVia?.branch)
        #expect(response.callID == options.callID)
        #expect(response.cseq?.number == options.cseq?.number)
        #expect(response.cseq?.method == .options)
        #expect(response.from?.tag == "as3f4d5e")
        #expect(response.to?.tag != nil, "свой тег в To обязателен")
        #expect(response.headers["Allow"]?.contains("INVITE") == true)
        #expect(response.contacts.isEmpty == false)
    }

    @Test("Ретрансмиссия OPTIONS получает тот же ответ, а не второй новый")
    func repeatsResponseForRetransmission() async throws {
        let server = acceptingServer()
        let agent = await registeredAgent(server)

        let options = makeOptions()
        server.inject(request: options)
        #expect(await waitUntil { server.sentResponses.count == 1 })

        server.inject(request: options)
        #expect(await waitUntil { server.sentResponses.count == 2 })
        await agent.stop()

        let responses = server.sentResponses
        #expect(responses.count == 2)
        #expect(responses[0].to?.tag == responses[1].to?.tag, "тег в To не должен меняться между ретрансмиссиями")
        #expect(responses[0].cseq?.number == responses[1].cseq?.number)
    }

    @Test("Входящий INVITE в M1 честно отклоняется, а не игнорируется")
    func rejectsInviteForNow() async throws {
        let server = acceptingServer()
        let agent = await registeredAgent(server)

        var invite = SIPRequest(method: .invite, uri: SIPURI(user: "100", host: "192.168.1.50"))
        invite.headers.append(SIPHeaderName.via, "SIP/2.0/UDP 172.17.0.2:5060;branch=z9hG4bKinvite1")
        invite.headers.append(SIPHeaderName.from, "\"101\" <sip:101@172.17.0.2>;tag=as99")
        invite.headers.append(SIPHeaderName.to, "<sip:100@192.168.1.50>")
        invite.headers.append(SIPHeaderName.callID, "call-invite-1")
        invite.headers.append(SIPHeaderName.cseq, "1 INVITE")
        server.inject(request: invite)

        #expect(await waitUntil { !server.sentResponses.isEmpty })
        await agent.stop()

        let response = try #require(server.sentResponses.first)
        // Молчание заставило бы Asterisk ждать таймаута и держать канал занятым.
        #expect(response.statusCode == 480)
        #expect(response.callID == "call-invite-1")
    }

    @Test("Неподдерживаемый метод получает 405 со списком Allow")
    func rejectsUnknownMethod() async throws {
        let server = acceptingServer()
        let agent = await registeredAgent(server)

        // REFER мы начнём обрабатывать только в M5, и до тех пор он не заявлен
        // в Allow — значит на него должен приходить честный 405.
        var request = SIPRequest(method: .refer, uri: SIPURI(user: "100", host: "192.168.1.50"))
        request.headers.append(SIPHeaderName.via, "SIP/2.0/UDP 172.17.0.2:5060;branch=z9hG4bKrefer1")
        request.headers.append(SIPHeaderName.from, "<sip:asterisk@172.17.0.2>;tag=as1")
        request.headers.append(SIPHeaderName.to, "<sip:100@192.168.1.50>")
        request.headers.append(SIPHeaderName.callID, "refer-1")
        request.headers.append(SIPHeaderName.cseq, "1 REFER")
        server.inject(request: request)

        #expect(await waitUntil { !server.sentResponses.isEmpty })
        await agent.stop()

        let response = try #require(server.sentResponses.first)
        #expect(response.statusCode == 405)
        #expect(response.headers["Allow"] != nil, "405 без Allow не говорит клиенту ничего полезного")
    }
}
