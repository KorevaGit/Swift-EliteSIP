import Foundation
import Testing
@testable import SIPCore

/// Повторный INVITE в обе стороны — то, из чего сделано удержание.
///
/// Проверяется то, что на живой АТС различить нельзя: разговор в обоих случаях
/// продолжается, а звук пропадает или остаётся в одну сторону. Своё
/// пересогласование — что запрос собран внутри диалога и подтверждён; чужое —
/// что мы отвечаем новым описанием, а не прежним, и что встречные предложения
/// не сцепляются намертво.
@Suite("Пересогласование", .timeLimit(.minutes(1)))
struct RenegotiationTests {

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

    /// Предложение удержания: то же, но с a=sendonly и следующей версией.
    private static let holdSDP = offerSDP
        .replacingOccurrences(of: "a=sendrecv", with: "a=sendonly")
        .replacingOccurrences(of: "o=root 1 1", with: "o=root 1 2")

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

    private static let heldAnswerSDP = answerSDP
        .replacingOccurrences(of: "a=sendrecv", with: "a=recvonly")

    private func makeInvite(
        callID: String = "reneg-1",
        branch: String = "z9hG4bKinbound1",
        sequence: Int = 102,
        body: String = offerSDP
    ) -> SIPRequest {
        var request = SIPRequest(
            method: .invite,
            uri: SIPURI(user: "100", host: "192.168.1.50"),
            body: Data(body.utf8)
        )
        request.headers.append(SIPHeaderName.via, "SIP/2.0/UDP 172.17.0.2:5060;branch=\(branch);rport")
        request.headers.append(SIPHeaderName.maxForwards, "70")
        request.headers.append(SIPHeaderName.from, "\"AutoDialer\" <sip:2929@172.17.0.2>;tag=as77aabb")
        request.headers.append(SIPHeaderName.to, "<sip:100@192.168.1.50>")
        request.headers.append(SIPHeaderName.callID, callID)
        request.headers.append(SIPHeaderName.cseq, "\(sequence) INVITE")
        request.headers.append(SIPHeaderName.contact, "<sip:2929@172.17.0.2:5060>")
        request.headers.append(SIPHeaderName.contentType, "application/sdp")
        return request
    }

    /// Повторный INVITE внутри уже установленного диалога: с нашим тегом в To.
    private func makeReinvite(
        toTag: String,
        sequence: Int = 103,
        branch: String = "z9hG4bKinbound2",
        body: String = holdSDP
    ) -> SIPRequest {
        var request = makeInvite(branch: branch, sequence: sequence, body: body)
        request.headers.set(SIPHeaderName.to, to: "<sip:100@192.168.1.50>;tag=\(toTag)")
        return request
    }

    private func makeACK(to invite: SIPRequest, toTag: String) -> SIPRequest {
        var ack = SIPRequest(method: .ack, uri: SIPURI(user: "100", host: "192.168.1.50"))
        ack.headers.append(SIPHeaderName.via, "SIP/2.0/UDP 172.17.0.2:5060;branch=z9hG4bKack-own")
        ack.headers.append(SIPHeaderName.from, invite.headers[SIPHeaderName.from] ?? "")
        ack.headers.append(SIPHeaderName.to, "<sip:100@192.168.1.50>;tag=\(toTag)")
        ack.headers.append(SIPHeaderName.callID, invite.callID ?? "")
        ack.headers.append(SIPHeaderName.cseq, "\(invite.cseq?.number ?? 1) ACK")
        return ack
    }

    /// Сервер, который отвечает только на регистрацию.
    ///
    /// Молчание в ответ на INVITE здесь обязательно: ответы на повторный INVITE
    /// тесты подают руками, а автоответ на любой запрос подтверждал бы наше
    /// пересогласование раньше, чем тест успевает вмешаться.
    private func acceptingServer() -> ScriptedSIPServer {
        ScriptedSIPServer(transport: .udp) { request, index in
            guard request.method == .register else { return nil }
            return index == 0
                ? ScriptedSIPServer.unauthorized(to: request)
                : ScriptedSIPServer.registrationAccepted(to: request)
        }
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

    /// Доводит входящий звонок до разговора и возвращает наш тег.
    private func answeredCall(on agent: SIPUserAgent, server: ScriptedSIPServer) async throws -> String {
        let events = agent.events
        let pending = Task { () -> SIPIncomingCall? in
            for await event in events {
                if case .incomingCall(let call) = event { return call }
            }
            return nil
        }

        let invite = makeInvite()
        server.inject(request: invite)
        _ = try #require(await pending.value)
        _ = await agent.answerIncomingCall(answer: Data(Self.answerSDP.utf8))

        let toTag = try #require(server.sentResponses.last { $0.statusCode == 200 }?.to?.tag)
        server.inject(request: makeACK(to: invite, toTag: toTag))
        _ = await waitUntil { await agent.callState == .answered }
        return toTag
    }

    // MARK: - Чужое пересогласование

    @Test("Ответ на чужое удержание собирает пересогласователь, а не прежний SDP")
    func answersReinviteWithFreshDescription() async throws {
        let server = acceptingServer()
        let agent = await registeredAgent(server)

        let seen = OfferBox()
        await agent.setMediaRenegotiator { offer in
            seen.store(offer)
            return Data(Self.heldAnswerSDP.utf8)
        }

        let toTag = try await answeredCall(on: agent, server: server)
        let before = server.sentResponses.count

        server.inject(request: makeReinvite(toTag: toTag))
        #expect(await waitUntil { server.sentResponses.count > before })
        await agent.stop()

        // Предложение обязано доехать до приложения целиком: удержание видно
        // только в теле, и разбирать его — не дело слоя сигнализации.
        #expect(seen.value == Data(Self.holdSDP.utf8))

        let ok = try #require(server.sentResponses.last { $0.statusCode == 200 && $0.cseq?.method == .invite })
        #expect(ok.body == Data(Self.heldAnswerSDP.utf8))
        #expect(ok.contentType == "application/sdp")
        // Тег диалога меняться не должен: это тот же разговор.
        #expect(ok.to?.tag == toTag)
    }

    @Test("Повторный INVITE с чужим локальным тегом получает 481")
    func foreignDialogReinviteIsRejected() async throws {
        let server = acceptingServer()
        let agent = await registeredAgent(server)

        let seen = OfferBox()
        await agent.setMediaRenegotiator { offer in
            seen.store(offer)
            return Data(Self.heldAnswerSDP.utf8)
        }

        _ = try await answeredCall(on: agent, server: server)
        let before = server.sentResponses.count

        server.inject(request: makeReinvite(toTag: "wrong-local-tag"))
        #expect(await waitUntil {
            server.sentResponses.dropFirst(before).contains {
                $0.statusCode == 481 && $0.cseq?.method == .invite
            }
        })

        #expect(seen.value == nil, "чужое предложение не должно дойти до media-слоя")
        #expect(await agent.callState == .answered)
        await agent.stop()
    }

    @Test("Повторный INVITE подтверждается сразу: сначала 100, потом 200")
    func sendsTryingBeforeAnswer() async throws {
        let server = acceptingServer()
        let agent = await registeredAgent(server)
        await agent.setMediaRenegotiator { _ in Data(Self.heldAnswerSDP.utf8) }

        let toTag = try await answeredCall(on: agent, server: server)
        let before = server.sentResponses.count

        server.inject(request: makeReinvite(toTag: toTag))
        #expect(await waitUntil {
            server.sentResponses.dropFirst(before).contains { $0.statusCode == 200 }
        })
        await agent.stop()

        // На UDP ретрансмиссии INVITE начинаются через полсекунды, а пересборка
        // медиа столько вполне может занять.
        let after = server.sentResponses.dropFirst(before).filter { $0.cseq?.method == .invite }
        #expect(after.first?.statusCode == 100)
        #expect(after.last?.statusCode == 200)
    }

    @Test("Пересогласователь отказался — уходит 488, а не молчание")
    func rejectsUnacceptableOfferWith488() async throws {
        let server = acceptingServer()
        let agent = await registeredAgent(server)
        await agent.setMediaRenegotiator { _ in nil }

        let toTag = try await answeredCall(on: agent, server: server)
        let before = server.sentResponses.count

        server.inject(request: makeReinvite(toTag: toTag))
        #expect(await waitUntil {
            server.sentResponses.dropFirst(before).contains { $0.statusCode == 488 }
        })
        await agent.stop()

        // Разговор при этом продолжается на прежних параметрах — RFC 3261 §14.1.
        let last = try #require(server.sentResponses.last { $0.cseq?.method == .invite })
        #expect(last.statusCode == 488)
    }

    @Test("Повторный INVITE без предложения подтверждается прежним описанием")
    func answersEmptyReinviteWithCurrentDescription() async throws {
        let server = acceptingServer()
        let agent = await registeredAgent(server)
        await agent.setMediaRenegotiator { _ in
            Issue.record("пересогласовывать нечего: предложения не было")
            return nil
        }

        let toTag = try await answeredCall(on: agent, server: server)
        let before = server.sentResponses.count

        var empty = makeReinvite(toTag: toTag, body: "")
        empty.headers.remove(SIPHeaderName.contentType)
        server.inject(request: empty)
        #expect(await waitUntil {
            server.sentResponses.dropFirst(before).contains { $0.statusCode == 200 }
        })
        await agent.stop()

        let ok = try #require(server.sentResponses.last { $0.statusCode == 200 && $0.cseq?.method == .invite })
        #expect(ok.body == Data(Self.answerSDP.utf8))
    }

    // MARK: - Своё пересогласование

    @Test("Своё удержание уходит повторным INVITE внутри диалога")
    func sendsReinviteWithinDialog() async throws {
        let server = acceptingServer()
        let agent = await registeredAgent(server)
        await agent.setMediaRenegotiator { _ in nil }

        let toTag = try await answeredCall(on: agent, server: server)

        let held = Data(Self.answerSDP
            .replacingOccurrences(of: "a=sendrecv", with: "a=sendonly").utf8)

        let reinvite = Task { try await agent.reinvite(offer: held) }

        #expect(await waitUntil {
            server.receivedRequests.contains { $0.method == .invite && $0.body == held }
        })

        let request = try #require(server.receivedRequests.last { $0.method == .invite })
        var accepted = ScriptedSIPServer.response(
            to: request,
            status: 200,
            toTag: "as77aabb",
            extraHeaders: [
                (SIPHeaderName.contact, "<sip:2929@172.17.0.2:5060>"),
                (SIPHeaderName.contentType, "application/sdp"),
            ]
        )
        accepted.body = Data(Self.heldAnswerSDP.utf8)
        server.inject(response: accepted)

        // Тело ответа отдаётся вызывающему байтами: разбирать SDP — не дело
        // слоя сигнализации ни на первом INVITE, ни на повторном.
        #expect(try await reinvite.value == Data(Self.heldAnswerSDP.utf8))

        // Запрос обязан быть внутри диалога: тот же Call-ID, оба тега на месте,
        // CSeq больше, чем у INVITE, и адрес — Contact собеседника.
        #expect(request.callID == "reneg-1")
        #expect(request.from?.tag == toTag)
        #expect(request.to?.tag == "as77aabb")
        #expect((request.cseq?.number ?? 0) > 0)
        #expect(request.uri.description.contains("2929@172.17.0.2:5060"))
        #expect(request.contacts.isEmpty == false, "без Contact собеседник не найдёт нас для следующего запроса")

        // И подтверждён ACK с тем же номером CSeq.
        let ack = try #require(server.receivedRequests.last { $0.method == .ack })
        #expect(ack.cseq?.number == request.cseq?.number)

        await agent.stop()
    }

    @Test("Отказ на своё удержание разговор не рвёт")
    func failedReinviteKeepsCallAlive() async throws {
        let server = acceptingServer()
        let agent = await registeredAgent(server)
        await agent.setMediaRenegotiator { _ in nil }

        _ = try await answeredCall(on: agent, server: server)

        let reinvite = Task { try await agent.reinvite(offer: Data(Self.answerSDP.utf8)) }
        #expect(await waitUntil { server.receivedRequests.contains { $0.method == .invite } })

        let request = try #require(server.receivedRequests.last { $0.method == .invite })
        server.inject(response: ScriptedSIPServer.response(to: request, status: 488, toTag: "as77aabb"))

        do {
            _ = try await reinvite.value
            Issue.record("отказ обязан дойти до вызывающего, а не потеряться")
        } catch SIPRenegotiationError.rejected(let status, _) {
            #expect(status == 488)
        }

        // Главное: звонок продолжается. Оператор потерял удержание, а не связь.
        #expect(await agent.callState == .answered)
        await agent.stop()
    }

    @Test("Встречное предложение получает 491, а не второй ответ")
    func answersGlareWith491() async throws {
        let server = acceptingServer()
        let agent = await registeredAgent(server)
        await agent.setMediaRenegotiator { _ in
            Issue.record("на встречное предложение отвечать 491, а не пересогласовывать")
            return nil
        }

        let toTag = try await answeredCall(on: agent, server: server)

        // Наш INVITE ушёл и ответа ещё нет — ровно то состояние, в котором
        // встречное предложение обязано получить отказ.
        let reinvite = Task { try? await agent.reinvite(offer: Data(Self.answerSDP.utf8)) }
        #expect(await waitUntil { server.receivedRequests.contains { $0.method == .invite } })

        server.inject(request: makeReinvite(toTag: toTag, sequence: 104, branch: "z9hG4bKglare"))
        #expect(await waitUntil { server.sentResponses.contains { $0.statusCode == 491 } })

        reinvite.cancel()
        await agent.stop()
    }
}

/// Ящик для предложения, увиденного пересогласователем.
///
/// Замыкание уходит в актор, поэтому просто переменной не обойтись.
private final class OfferBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Data?

    func store(_ data: Data) { lock.withLock { storage = data } }
    var value: Data? { lock.withLock { storage } }
}
