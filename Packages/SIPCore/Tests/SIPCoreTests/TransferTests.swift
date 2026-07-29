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
        #expect(result.last == .failed(status: 486, reason: "занято"))
        await agent.stop()
    }

    @Test("message/sipfrag разбирает код и причину")
    func parsesSIPFragment() {
        let parsed = parseSIPFragmentStatus(Data("SIP/2.0 503 Service Unavailable\r\n".utf8))
        #expect(parsed?.status == 503)
        #expect(parsed?.reason == "Service Unavailable")
        #expect(parseSIPFragmentStatus(Data("garbage".utf8)) == nil)
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
