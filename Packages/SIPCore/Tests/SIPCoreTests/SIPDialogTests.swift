import Foundation
import Testing
@testable import SIPCore

@Suite("Диалог SIP")
struct SIPDialogTests {

    private func makeInvite() -> SIPRequest {
        var request = SIPRequest(method: .invite, uri: SIPURI(user: "600", host: "127.0.0.1"))
        request.headers.append(SIPHeaderName.via, "SIP/2.0/UDP 192.168.1.50:5060;branch=z9hG4bKinv1;rport")
        request.headers.append(SIPHeaderName.maxForwards, "70")
        request.headers.append(SIPHeaderName.from, "\"Agent 100\" <sip:100@127.0.0.1>;tag=localtag")
        request.headers.append(SIPHeaderName.to, "<sip:600@127.0.0.1>")
        request.headers.append(SIPHeaderName.callID, "call-abc@mac.local")
        request.headers.append(SIPHeaderName.cseq, "20 INVITE")
        request.headers.append(SIPHeaderName.contact, "<sip:100@192.168.1.50:5060>")
        return request
    }

    private func makeOK(
        toTag: String = "as77aa11",
        contact: String = "<sip:600@172.17.0.2:5060>",
        recordRoutes: [String] = []
    ) -> SIPResponse {
        var headers = SIPHeaders()
        headers.append(SIPHeaderName.via, "SIP/2.0/UDP 192.168.1.50:5060;branch=z9hG4bKinv1;received=192.168.65.1;rport=54321")
        for route in recordRoutes {
            headers.append(SIPHeaderName.recordRoute, route)
        }
        headers.append(SIPHeaderName.from, "\"Agent 100\" <sip:100@127.0.0.1>;tag=localtag")
        headers.append(SIPHeaderName.to, "<sip:600@127.0.0.1>;tag=\(toTag)")
        headers.append(SIPHeaderName.callID, "call-abc@mac.local")
        headers.append(SIPHeaderName.cseq, "20 INVITE")
        headers.append(SIPHeaderName.contact, contact)
        return SIPResponse(statusCode: 200, headers: headers)
    }

    @Test("Собирается из 200 OK на наш INVITE")
    func buildsFromSuccess() throws {
        let dialog = try #require(SIPDialog(initiatorRequest: makeInvite(), response: makeOK()))

        #expect(dialog.callID == "call-abc@mac.local")
        #expect(dialog.localTag == "localtag")
        #expect(dialog.remoteTag == "as77aa11")
        #expect(dialog.localSequence == 20)
        #expect(dialog.isInitiator)

        // Remote target — это Contact из ответа, а не адрес из To. За NAT они
        // почти всегда разные, и BYE на адрес из To не дойдёт.
        #expect(dialog.remoteTarget.host == "172.17.0.2")
        #expect(dialog.remoteTarget.port == 5060)
    }

    @Test("Без Contact в ответе диалог не создаётся")
    func requiresContact() {
        var headers = SIPHeaders()
        headers.append(SIPHeaderName.from, "<sip:100@127.0.0.1>;tag=localtag")
        headers.append(SIPHeaderName.to, "<sip:600@127.0.0.1>;tag=remotetag")
        headers.append(SIPHeaderName.callID, "c1")
        headers.append(SIPHeaderName.cseq, "20 INVITE")

        // Падать назад на адрес из To было бы хуже, чем не создать диалог:
        // запросы уходили бы в никуда, а ошибка проявилась бы позже и глуше.
        #expect(SIPDialog(initiatorRequest: makeInvite(), response: SIPResponse(statusCode: 200, headers: headers)) == nil)
    }

    @Test("Неуспешный ответ диалога не создаёт")
    func ignoresFailure() {
        var headers = SIPHeaders()
        headers.append(SIPHeaderName.to, "<sip:600@127.0.0.1>;tag=t")
        headers.append(SIPHeaderName.callID, "c1")
        headers.append(SIPHeaderName.cseq, "20 INVITE")
        headers.append(SIPHeaderName.contact, "<sip:600@172.17.0.2>")
        #expect(SIPDialog(initiatorRequest: makeInvite(), response: SIPResponse(statusCode: 486, headers: headers)) == nil)
    }

    @Test("Набор маршрутов берётся из Record-Route")
    func capturesRouteSet() throws {
        let dialog = try #require(SIPDialog(
            initiatorRequest: makeInvite(),
            response: makeOK(recordRoutes: ["<sip:proxy1.example.com;lr>", "<sip:proxy2.example.com;lr>"])
        ))
        #expect(dialog.routeSet.count == 2)
        #expect(dialog.routeSet.first?.host == "proxy1.example.com")

        // При наличии lr-маршрута запрос физически уходит на него, а не на
        // Contact собеседника.
        #expect(dialog.requestDestination.host == "proxy1.example.com")
    }

    @Test("Без маршрутов запрос идёт прямо на Contact")
    func destinationWithoutRoutes() throws {
        let dialog = try #require(SIPDialog(initiatorRequest: makeInvite(), response: makeOK()))
        #expect(dialog.requestDestination.host == "172.17.0.2")
    }

    @Test("Запрос внутри диалога несёт правильные теги и маршруты")
    func buildsInDialogRequest() throws {
        let dialog = try #require(SIPDialog(
            initiatorRequest: makeInvite(),
            response: makeOK(recordRoutes: ["<sip:proxy1.example.com;lr>"])
        ))
        let (updated, sequence) = dialog.nextSequence()
        #expect(sequence == 21, "CSeq обязан расти")

        var via = SIPVia(transport: .udp, host: "192.168.1.50", port: 5060)
        via.branch = SIPToken.branch()

        let bye = updated.makeRequest(.bye, sequence: sequence, via: via)

        #expect(bye.method == .bye)
        #expect(bye.uri.host == "172.17.0.2", "Request-URI — это Contact собеседника")
        #expect(bye.from?.tag == "localtag")
        #expect(bye.to?.tag == "as77aa11")
        #expect(bye.callID == "call-abc@mac.local")
        #expect(bye.cseq?.number == 21)
        #expect(bye.cseq?.method == .bye)
        #expect(bye.headers.values(SIPHeaderName.route).count == 1)
    }

    @Test("nextSequence не выдаёт один номер дважды")
    func sequenceIsNotReused() throws {
        let dialog = try #require(SIPDialog(initiatorRequest: makeInvite(), response: makeOK()))

        // Метод возвращает новый диалог именно для того, чтобы номер нельзя было
        // случайно использовать повторно: сервер счёл бы это ретрансмиссией.
        let (afterFirst, first) = dialog.nextSequence()
        let (_, second) = afterFirst.nextSequence()
        #expect(first == 21)
        #expect(second == 22)

        let (_, repeated) = dialog.nextSequence()
        #expect(repeated == 21, "исходный диалог не меняется")
    }

    @Test("Сопоставление требует совпадения всех трёх составляющих")
    func matchingNeedsAllParts() throws {
        let dialog = try #require(SIPDialog(initiatorRequest: makeInvite(), response: makeOK()))

        #expect(dialog.matches(callID: "call-abc@mac.local", localTag: "localtag", remoteTag: "as77aa11"))
        // Только Call-ID недостаточно: при перезвоне он может повториться.
        #expect(!dialog.matches(callID: "call-abc@mac.local", localTag: "localtag", remoteTag: "другой"))
        #expect(!dialog.matches(callID: "другой", localTag: "localtag", remoteTag: "as77aa11"))
        #expect(!dialog.matches(callID: "call-abc@mac.local", localTag: nil, remoteTag: "as77aa11"))
    }
}

@Suite("ACK и CANCEL")
struct InviteHelperTests {

    private func makeInvite() -> SIPRequest {
        var request = SIPRequest(method: .invite, uri: SIPURI(user: "600", host: "127.0.0.1"))
        request.headers.append(SIPHeaderName.via, "SIP/2.0/UDP 192.168.1.50:5060;branch=z9hG4bKinv1")
        request.headers.append(SIPHeaderName.from, "<sip:100@127.0.0.1>;tag=localtag")
        request.headers.append(SIPHeaderName.to, "<sip:600@127.0.0.1>")
        request.headers.append(SIPHeaderName.callID, "call-abc")
        request.headers.append(SIPHeaderName.cseq, "20 INVITE")
        request.headers.append(SIPHeaderName.route, "<sip:proxy;lr>")
        return request
    }

    @Test("ACK на неуспешный ответ берёт тег из ответа")
    func failureACK() throws {
        var headers = SIPHeaders()
        headers.append(SIPHeaderName.via, "SIP/2.0/UDP 192.168.1.50:5060;branch=z9hG4bKinv1")
        headers.append(SIPHeaderName.from, "<sip:100@127.0.0.1>;tag=localtag")
        headers.append(SIPHeaderName.to, "<sip:600@127.0.0.1>;tag=servertag")
        headers.append(SIPHeaderName.callID, "call-abc")
        headers.append(SIPHeaderName.cseq, "20 INVITE")
        let busy = SIPResponse(statusCode: 486, headers: headers)

        let ack = SIPTransactionLayer.makeFailureACK(for: makeInvite(), response: busy)

        #expect(ack.method == .ack)
        // Тег собеседника есть только в ответе — без него сервер ACK не опознает.
        #expect(ack.to?.tag == "servertag")
        #expect(ack.from?.tag == "localtag")
        #expect(ack.callID == "call-abc")
        #expect(ack.cseq?.number == 20, "номер CSeq тот же, что у INVITE")
        #expect(ack.cseq?.method == .ack)
        // Тот же branch: этот ACK — часть транзакции INVITE.
        #expect(ack.topVia?.branch == "z9hG4bKinv1")
        #expect(ack.headers.values(SIPHeaderName.route).count == 1)
    }

    @Test("CANCEL повторяет branch отменяемого INVITE")
    func cancelSharesBranch() {
        let cancel = SIPTransactionLayer.makeCancel(for: makeInvite())

        #expect(cancel.method == .cancel)
        // По branch сервер понимает, какую транзакцию отменять.
        #expect(cancel.topVia?.branch == "z9hG4bKinv1")
        #expect(cancel.cseq?.number == 20)
        #expect(cancel.cseq?.method == .cancel)
        #expect(cancel.uri.user == "600")
        #expect(cancel.to?.tag == nil, "тега в To ещё нет — ответ не приходил")
    }

    @Test("Ключ транзакции включает метод")
    func transactionKeyIncludesMethod() {
        // Иначе CANCEL, который обязан нести branch отменяемого INVITE,
        // затирал бы его транзакцию.
        let invite = SIPTransactionLayer.transactionKey(branch: "z9hG4bK1", method: .invite)
        let cancel = SIPTransactionLayer.transactionKey(branch: "z9hG4bK1", method: .cancel)
        #expect(invite != cancel)
    }
}
