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

    // Входящий INVITE со всеми его случаями разобран отдельно, в
    // `IncomingCallTests`: с M3 это уже не «отказ на неподдерживаемое», а
    // полноценный звонок со своей транзакцией и своими таймерами.

    @Test("Входящий REFER отклоняется явно: удалённо управлять переводом нельзя")
    func rejectsInboundRefer() async throws {
        let server = acceptingServer()
        let agent = await registeredAgent(server)

        // Исходящий REFER в M5 поддерживается, но принимать удалённую команду
        // перевода — отдельная политика. Отвечаем 501, а не молчим.
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
        #expect(response.statusCode == 501)
        #expect(response.headers["Allow"] != nil)
    }
}
