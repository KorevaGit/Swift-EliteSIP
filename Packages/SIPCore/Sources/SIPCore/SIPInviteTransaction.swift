import Foundation

/// Что происходит с исходящим INVITE.
public enum SIPInviteEvent: Sendable {
    /// 1xx: пошли гудки. Может прийти несколько раз.
    case provisional(SIPResponse)
    /// 2xx: собеседник ответил.
    ///
    /// ACK на 2xx отправляет вызывающая сторона, а не слой транзакций, и это
    /// требование RFC 3261 §17.1.1.3: такой ACK идёт ВНЕ транзакции, по
    /// маршруту диалога и на Contact из ответа. Слой этого маршрута не знает.
    case success(SIPResponse)
    /// 3xx–6xx. ACK на такой ответ — часть транзакции, слой уже его отправил.
    case failure(SIPResponse)
    /// Истёк таймер B: 64*T1, по умолчанию 32 секунды без всякого ответа.
    case timeout
    case transportFailed(reason: String)
}

extension SIPTransactionLayer {

    /// Ключ таблицы транзакций.
    ///
    /// Branch сам по себе не годится: CANCEL по RFC обязан нести тот же branch,
    /// что и отменяемый INVITE, и без метода в ключе эти две транзакции
    /// затирали бы друг друга.
    static func transactionKey(branch: String, method: SIPMethod) -> String {
        "\(branch)|\(method.rawValue)"
    }

    /// Собирает ACK на неуспешный финальный ответ.
    ///
    /// Отличается от ACK на 2xx: этот идёт с тем же branch, что INVITE, на тот
    /// же Request-URI и внутри той же транзакции.
    static func makeFailureACK(for request: SIPRequest, response: SIPResponse) -> SIPRequest {
        var ack = SIPRequest(method: .ack, uri: request.uri)

        if let via = request.headers[SIPHeaderName.via] {
            ack.headers.append(SIPHeaderName.via, via)
        }
        ack.headers.append(SIPHeaderName.maxForwards, "70")
        if let from = request.headers[SIPHeaderName.from] {
            ack.headers.append(SIPHeaderName.from, from)
        }
        // To берём ИЗ ОТВЕТА: там уже есть тег собеседника, а в нашем запросе
        // его не было. Без этого сервер ACK не опознает.
        if let to = response.headers[SIPHeaderName.to] ?? request.headers[SIPHeaderName.to] {
            ack.headers.append(SIPHeaderName.to, to)
        }
        if let callID = request.headers[SIPHeaderName.callID] {
            ack.headers.append(SIPHeaderName.callID, callID)
        }
        if let cseq = request.cseq {
            ack.headers.append(SIPHeaderName.cseq, "\(cseq.number) \(SIPMethod.ack.rawValue)")
        }
        // Route повторяем: ACK должен пройти тем же путём.
        for route in request.headers.values(SIPHeaderName.route) {
            ack.headers.append(SIPHeaderName.route, route)
        }
        return ack
    }

    /// Собирает CANCEL для ещё не отвеченного INVITE.
    static func makeCancel(for request: SIPRequest) -> SIPRequest {
        var cancel = SIPRequest(method: .cancel, uri: request.uri)

        // Тот же branch, что у INVITE — так сервер понимает, что отменять.
        if let via = request.headers[SIPHeaderName.via] {
            cancel.headers.append(SIPHeaderName.via, via)
        }
        cancel.headers.append(SIPHeaderName.maxForwards, "70")
        for name in [SIPHeaderName.from, SIPHeaderName.to, SIPHeaderName.callID] {
            if let value = request.headers[name] {
                cancel.headers.append(name, value)
            }
        }
        if let cseq = request.cseq {
            cancel.headers.append(SIPHeaderName.cseq, "\(cseq.number) \(SIPMethod.cancel.rawValue)")
        }
        for route in request.headers.values(SIPHeaderName.route) {
            cancel.headers.append(SIPHeaderName.route, route)
        }
        return cancel
    }
}
