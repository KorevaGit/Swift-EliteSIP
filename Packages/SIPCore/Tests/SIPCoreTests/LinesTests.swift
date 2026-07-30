import Foundation
import Testing
@testable import SIPCore

/// Три линии, адресуемые по Call-ID.
///
/// Проверяется ровно то, что нельзя увидеть на одной линии: что запрос попадает
/// в свою линию, а не в первую попавшуюся, и что операция над одной не задевает
/// соседнюю. Ошибка здесь выглядит как завершённый не тот разговор, и на живой
/// АТС ловить её поздно.
@Suite("Линии", .timeLimit(.minutes(1)))
struct LinesTests {

    private let offer = Data(
        "v=0\r\no=- 1 1 IN IP4 10.0.0.5\r\ns=-\r\nc=IN IP4 10.0.0.5\r\nt=0 0\r\nm=audio 16000 RTP/AVP 0\r\n".utf8
    )

    private func makeServer() -> ScriptedSIPServer {
        ScriptedSIPServer { request, _ in
            guard request.headers[SIPHeaderName.authorization] != nil else {
                return ScriptedSIPServer.unauthorized(to: request)
            }
            switch request.method {
            case .register:
                return ScriptedSIPServer.registrationAccepted(to: request)
            case .invite:
                // Ответы на INVITE присылаются вручную: их несколько, и линий
                // тоже несколько.
                return nil
            case .refer:
                return ScriptedSIPServer.response(to: request, status: 202)
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
        #expect(await waitUntil { await agent.registrationState.isRegistered })
        return agent
    }

    /// Заводит линию и доводит её до разговора.
    ///
    /// Тег собеседника у каждой линии свой: с одинаковым тегом проверка
    /// адресации теряет смысл — перепутанная линия совпала бы по всем полям.
    @discardableResult
    private func answeredLine(
        on agent: SIPUserAgent,
        server: ScriptedSIPServer,
        number: String,
        toTag: String
    ) async throws -> (callID: String, invite: SIPRequest) {
        let before = server.receivedRequests.filter { $0.method == .invite }.count
        let call = await agent.placeCall(to: number, offer: offer)

        // Первый INVITE уходит без авторизации, второй — подписанный.
        #expect(await waitUntil {
            server.receivedRequests.filter {
                $0.method == .invite && $0.callID == call.callID
            }.count >= 2
        })
        let invite = try #require(
            server.receivedRequests.last { $0.method == .invite && $0.callID == call.callID }
        )
        #expect(server.receivedRequests.filter { $0.method == .invite }.count >= before + 2)

        var ok = ScriptedSIPServer.response(
            to: invite,
            status: 200,
            toTag: toTag,
            extraHeaders: [(SIPHeaderName.contact, "<sip:\(number)@172.17.0.2:5060>")]
        )
        ok.body = offer
        ok.headers.append(SIPHeaderName.contentType, "application/sdp")
        server.inject(response: ok)

        #expect(await waitUntil { await agent.callState(of: call.callID) == .answered })
        return (call.callID, invite)
    }

    /// Запрос от сервера внутри уже установленного диалога.
    private func request(
        _ method: SIPMethod,
        inside invite: SIPRequest,
        toTag: String,
        branch: String,
        sequence: Int
    ) -> SIPRequest {
        var request = SIPRequest(
            method: method,
            uri: SIPURI(user: "100", host: "192.168.1.50")
        )
        request.headers.append(SIPHeaderName.via, "SIP/2.0/UDP 172.17.0.2:5060;branch=\(branch)")
        request.headers.append(SIPHeaderName.from, "<sip:600@127.0.0.1>;tag=\(toTag)")
        request.headers.append(SIPHeaderName.to, invite.headers[SIPHeaderName.from] ?? "")
        request.headers.append(SIPHeaderName.callID, invite.callID ?? "")
        request.headers.append(SIPHeaderName.cseq, "\(sequence) \(method.rawValue)")
        request.headers.append(SIPHeaderName.contact, "<sip:600@172.17.0.2:5060>")
        return request
    }

    @Test("Три линии живут одновременно и различаются по Call-ID")
    func threeLinesCoexist() async throws {
        let server = makeServer()
        let agent = await makeAgent(server)

        let first = try await answeredLine(on: agent, server: server, number: "600", toTag: "tag-600")
        let second = try await answeredLine(on: agent, server: server, number: "601", toTag: "tag-601")
        let third = try await answeredLine(on: agent, server: server, number: "602", toTag: "tag-602")

        let lines = await agent.lines
        #expect(lines.map(\.callID) == [first.callID, second.callID, third.callID],
                "линии отдаются в порядке появления")
        #expect(lines.map(\.peer) == ["600", "601", "602"])
        #expect(lines.allSatisfy { $0.state == .answered })
        #expect(await agent.hasFreeLine == false)

        // Единственной линии больше нет — значит и умолчания у адресации тоже.
        #expect(await agent.callState == nil)

        await agent.stop()
    }

    @Test("Место под линию занимается до отправки INVITE")
    func lineSlotIsReservedBeforeInvite() async throws {
        let server = makeServer()
        let agent = await makeAgent(server)

        // Четыре набора подряд, без единого ожидания между ними. Диалогов в
        // этот момент нет ни одного: `runCall` ещё ждёт готовности транспорта,
        // и если место занимать по факту INVITE, все четыре пройдут проверку
        // свободной линии.
        var placed: [SIPOutgoingCall] = []
        for number in ["600", "601", "602", "603"] {
            placed.append(await agent.placeCall(to: number, offer: offer))
        }

        // Четвёртый поток уже закрыт отказом, поэтому читается до конца сразу.
        var failure: String?
        for await event in placed[3].events {
            if case .failed(_, let reason) = event { failure = reason }
        }
        #expect(failure == "заняты все линии (3)")

        // Ждём именно INVITE, а не появления линии в словаре: линия заводится
        // на шаг раньше отправки, и счёт запросов в этот момент ещё не сошёлся.
        #expect(await waitUntil {
            Set(server.receivedRequests.filter { $0.method == .invite }.compactMap(\.callID)).count == 3
        })
        #expect(await agent.lines.count == 3)

        let invited = Set(
            server.receivedRequests.filter { $0.method == .invite }.compactMap(\.callID)
        )
        #expect(!invited.contains(placed[3].callID), "отклонённая линия INVITE не отправляет")

        await agent.stop()
    }

    @Test("BYE завершает только свою линию")
    func byeEndsOnlyItsLine() async throws {
        let server = makeServer()
        let agent = await makeAgent(server)

        let first = try await answeredLine(on: agent, server: server, number: "600", toTag: "tag-600")
        let second = try await answeredLine(on: agent, server: server, number: "601", toTag: "tag-601")

        server.inject(request: request(
            .bye,
            inside: second.invite,
            toTag: "tag-601",
            branch: "z9hG4bK-bye-second",
            sequence: 2
        ))

        #expect(await waitUntil { await agent.lines.count == 1 })
        #expect(await agent.callState(of: second.callID) == nil)
        #expect(await agent.callState(of: first.callID) == .answered,
                "чужой BYE не имеет права трогать соседнюю линию")

        // Тег второй линии по первой уже не проходит: тройка идентификаторов
        // сверяется целиком.
        server.inject(request: request(
            .bye,
            inside: first.invite,
            toTag: "tag-601",
            branch: "z9hG4bK-bye-wrong-tag",
            sequence: 3
        ))
        #expect(await waitUntil {
            server.sentResponses.contains { $0.cseq?.method == .bye && $0.statusCode == 481 }
        })
        #expect(await agent.callState(of: first.callID) == .answered)

        await agent.stop()
    }

    @Test("Повторный INVITE попадает в свою линию")
    func reinviteReachesItsOwnLine() async throws {
        let server = makeServer()
        let agent = await makeAgent(server)

        let seen = CallIDLog()
        await agent.setMediaRenegotiator { callID, _ in
            seen.store(callID)
            return Data("v=0\r\no=- 2 2 IN IP4 10.0.0.5\r\ns=-\r\nc=IN IP4 10.0.0.5\r\nt=0 0\r\nm=audio 16000 RTP/AVP 0\r\na=recvonly\r\n".utf8)
        }

        _ = try await answeredLine(on: agent, server: server, number: "600", toTag: "tag-600")
        let second = try await answeredLine(on: agent, server: server, number: "601", toTag: "tag-601")

        var reinvite = request(
            .invite,
            inside: second.invite,
            toTag: "tag-601",
            branch: "z9hG4bK-reinvite-second",
            sequence: 2
        )
        reinvite.body = Data(
            "v=0\r\no=root 2 2 IN IP4 172.17.0.2\r\ns=-\r\nc=IN IP4 172.17.0.2\r\nt=0 0\r\nm=audio 14028 RTP/AVP 0\r\na=sendonly\r\n".utf8
        )
        reinvite.headers.append(SIPHeaderName.contentType, "application/sdp")
        server.inject(request: reinvite)

        #expect(await waitUntil { seen.values.count == 1 })
        #expect(seen.values == [second.callID],
                "пересогласователь обязан знать, у какой линии сменилось медиа")

        await agent.stop()
    }

    @Test("Удержание одной линии не трогает соседнюю")
    func holdIsPerLine() async throws {
        let server = makeServer()
        let agent = await makeAgent(server)

        let first = try await answeredLine(on: agent, server: server, number: "600", toTag: "tag-600")
        let second = try await answeredLine(on: agent, server: server, number: "601", toTag: "tag-601")

        let held = Data(
            "v=0\r\no=- 2 2 IN IP4 10.0.0.5\r\ns=-\r\nc=IN IP4 10.0.0.5\r\nt=0 0\r\nm=audio 16000 RTP/AVP 0\r\na=sendonly\r\n".utf8
        )
        let reinvite = Task { try await agent.reinvite(callID: first.callID, offer: held) }

        #expect(await waitUntil {
            server.receivedRequests.contains {
                $0.method == .invite && $0.callID == first.callID && $0.cseq?.number ?? 0 > 1
            }
        })
        let sent = try #require(
            server.receivedRequests.last {
                $0.method == .invite && $0.cseq?.number ?? 0 > 1
            }
        )
        #expect(sent.callID == first.callID, "повторный INVITE уходит по своей линии")
        #expect(sent.to?.tag == "tag-600", "и с тегом своего собеседника")

        var ok = ScriptedSIPServer.response(
            to: sent,
            status: 200,
            toTag: "tag-600",
            extraHeaders: [(SIPHeaderName.contact, "<sip:600@172.17.0.2:5060>")]
        )
        ok.body = held
        ok.headers.append(SIPHeaderName.contentType, "application/sdp")
        server.inject(response: ok)

        _ = try await reinvite.value
        #expect(await agent.callState(of: first.callID) == .answered)
        #expect(await agent.callState(of: second.callID) == .answered)

        await agent.stop()
    }

    @Test("Консультационный перевод ссылается на диалог второй линии")
    func attendedTransferReplacesConsultationDialog() async throws {
        let server = makeServer()
        let agent = await makeAgent(server)

        let origin = try await answeredLine(on: agent, server: server, number: "600", toTag: "tag-600")
        let consultation = try await answeredLine(on: agent, server: server, number: "601", toTag: "tag-601")

        let replaces = try #require(await agent.dialogIdentifier(of: consultation.callID))
        #expect(replaces.callID == consultation.callID)
        #expect(replaces.remoteTag == "tag-601")

        let events = await agent.transfer(
            callID: origin.callID,
            to: "601",
            replacing: replaces
        )
        let collector = Task { () -> [SIPTransferEvent] in
            var result: [SIPTransferEvent] = []
            for await event in events { result.append(event) }
            return result
        }

        #expect(await waitUntil { server.receivedRequests.contains { $0.method == .refer } })
        let refer = try #require(server.receivedRequests.last { $0.method == .refer })
        #expect(refer.callID == origin.callID, "REFER уходит по исходной линии")
        let referTo = try #require(refer.headers[SIPHeaderName.referTo])
        #expect(referTo.contains("Replaces="))
        #expect(referTo.contains(consultation.callID.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        ) ?? consultation.callID))
        #expect(referTo.contains("to-tag%3Dtag-601"))

        // Финальный NOTIFY приходит внутри исходного диалога.
        var notify = request(
            .notify,
            inside: origin.invite,
            toTag: "tag-600",
            branch: "z9hG4bK-notify-attended",
            sequence: 3
        )
        notify.headers.append(SIPHeaderName.event, "refer")
        notify.headers.append(SIPHeaderName.subscriptionState, "terminated;reason=noresource")
        notify.headers.append(SIPHeaderName.contentType, "message/sipfrag;version=2.0")
        notify.body = Data("SIP/2.0 200 OK\r\n".utf8)
        server.inject(request: notify)

        #expect(await collector.value == [.accepted, .succeeded])

        await agent.stop()
    }

    @Test("Выход кладёт трубку на каждой линии")
    func stopEndsEveryLine() async throws {
        let server = makeServer()
        let agent = await makeAgent(server)

        let first = try await answeredLine(on: agent, server: server, number: "600", toTag: "tag-600")
        let second = try await answeredLine(on: agent, server: server, number: "601", toTag: "tag-601")

        await agent.stop()

        let byes = server.receivedRequests.filter { $0.method == .bye }
        #expect(Set(byes.compactMap(\.callID)) == [first.callID, second.callID],
                "оба диалога обязаны закрыться до снятия регистрации")

        // Снятие регистрации идёт последним: закрывать диалоги после отключения
        // транспорта уже некуда.
        let unregisterIndex = try #require(server.receivedRequests.lastIndex {
            $0.method == .register && $0.headers[SIPHeaderName.expires] == "0"
        })
        let lastByeIndex = try #require(server.receivedRequests.lastIndex { $0.method == .bye })
        #expect(lastByeIndex < unregisterIndex)
    }

    @Test("Занятому оператору входящий по-прежнему отвечает 486")
    func incomingIsRejectedWhileLineIsBusy() async throws {
        let server = makeServer()
        let agent = await makeAgent(server)

        _ = try await answeredLine(on: agent, server: server, number: "600", toTag: "tag-600")

        var invite = SIPRequest(
            method: .invite,
            uri: SIPURI(user: "100", host: "192.168.1.50"),
            body: offer
        )
        invite.headers.append(SIPHeaderName.via, "SIP/2.0/UDP 172.17.0.2:5060;branch=z9hG4bK-incoming")
        invite.headers.append(SIPHeaderName.from, "<sip:2929@127.0.0.1>;tag=queue-tag")
        invite.headers.append(SIPHeaderName.to, "<sip:100@127.0.0.1>")
        invite.headers.append(SIPHeaderName.callID, "incoming-while-busy@lab")
        invite.headers.append(SIPHeaderName.cseq, "1 INVITE")
        invite.headers.append(SIPHeaderName.contact, "<sip:2929@172.17.0.2:5060>")
        invite.headers.append(SIPHeaderName.contentType, "application/sdp")
        server.inject(request: invite)

        #expect(await waitUntil {
            server.sentResponses.contains {
                $0.callID == "incoming-while-busy@lab" && $0.statusCode == 486
            }
        })
        #expect(await agent.lines.count == 1, "отклонённый вызов линию не занимает")

        await agent.stop()
    }
}

/// Список линий, которые видел пересогласователь.
///
/// Замыкание уходит в актор, поэтому просто переменной не обойтись.
private final class CallIDLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func store(_ callID: String) { lock.withLock { storage.append(callID) } }
    var values: [String] { lock.withLock { storage } }
}
