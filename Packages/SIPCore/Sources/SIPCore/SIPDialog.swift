import Foundation

/// Диалог SIP — то, что связывает запросы одного звонка между собой.
///
/// Существует потому, что ACK, BYE, re-INVITE и REFER обязаны нести те же
/// Call-ID и теги, что и установивший диалог INVITE, идти по тому же набору
/// маршрутов и на тот же Contact собеседника. Собрать это по месту из ответа
/// каждый раз — верный способ получить 481 «диалог не существует».
public struct SIPDialog: Sendable, Hashable {

    public let callID: String
    public let localTag: String
    public let remoteTag: String

    public var localAddress: NameAddress
    public var remoteAddress: NameAddress

    /// Contact собеседника: куда отправлять запросы внутри диалога. Это НЕ то же,
    /// что адрес в To — за NAT они почти всегда разные.
    public var remoteTarget: SIPURI

    /// Набор маршрутов из Record-Route. Для исходящего звонка порядок
    /// обратный тому, в каком заголовки пришли в ответе.
    public var routeSet: [SIPURI]

    /// Номер CSeq для следующего запроса от нас.
    public var localSequence: Int

    /// Инициировали ли диалог мы. От этого зависит, чей tag куда идёт.
    public let isInitiator: Bool

    public init(
        callID: String,
        localTag: String,
        remoteTag: String,
        localAddress: NameAddress,
        remoteAddress: NameAddress,
        remoteTarget: SIPURI,
        routeSet: [SIPURI] = [],
        localSequence: Int,
        isInitiator: Bool
    ) {
        self.callID = callID
        self.localTag = localTag
        self.remoteTag = remoteTag
        self.localAddress = localAddress
        self.remoteAddress = remoteAddress
        self.remoteTarget = remoteTarget
        self.routeSet = routeSet
        self.localSequence = localSequence
        self.isInitiator = isInitiator
    }

    /// Собирает диалог из успешного ответа на наш INVITE.
    public init?(initiatorRequest request: SIPRequest, response: SIPResponse) {
        guard response.isSuccess,
              let callID = response.callID,
              let from = response.from ?? request.from,
              let to = response.to,
              let localTag = from.tag,
              let remoteTag = to.tag,
              let cseq = request.cseq
        else { return nil }

        // Contact ответа — обязательный элемент: без него неизвестно, куда
        // отправлять ACK и BYE. Падать назад на адрес из To нельзя, за NAT это
        // приведёт в никуда.
        guard let contact = response.contacts.first?.uri else { return nil }

        // Record-Route в ответе идёт в порядке от нас к собеседнику,
        // а маршрутизировать надо в том же направлении — значит порядок
        // сохраняется как есть (RFC 3261 §12.1.2).
        let routes = response.headers.values(SIPHeaderName.recordRoute)
            .compactMap { NameAddress($0)?.uri }

        self.init(
            callID: callID,
            localTag: localTag,
            remoteTag: remoteTag,
            localAddress: from,
            remoteAddress: to,
            remoteTarget: contact,
            routeSet: routes,
            localSequence: cseq.number,
            isInitiator: true
        )
    }

    /// Собирает диалог из принятого нами INVITE и нашего же 200 OK.
    ///
    /// Зеркало инициаторского случая, и зеркалить приходится всё: наш тег
    /// теперь в To, чужой — во From, маршрут из Record-Route берётся в обратном
    /// порядке (RFC 3261 §12.1.1), а счётчик CSeq для наших запросов начинается
    /// с нуля — номер из INVITE принадлежит другой стороне.
    public init?(responderRequest request: SIPRequest, localTag: String) {
        guard let callID = request.callID,
              let from = request.from,
              let to = request.to,
              let remoteTag = from.tag
        else { return nil }

        // Contact запроса — единственный адрес, куда можно слать BYE. За NAT он
        // отличается от того, что стоит во From, и падать назад на From нельзя.
        guard let contact = request.contacts.first?.uri else { return nil }

        let routes = request.headers.values(SIPHeaderName.recordRoute)
            .compactMap { NameAddress($0)?.uri }
            .reversed()

        self.init(
            callID: callID,
            localTag: localTag,
            remoteTag: remoteTag,
            localAddress: to,
            remoteAddress: from,
            remoteTarget: contact,
            routeSet: Array(routes),
            localSequence: 0,
            isInitiator: false
        )
    }

    // MARK: - Построение запросов внутри диалога

    /// Куда физически отправлять запрос: первый lr-маршрут, если он есть,
    /// иначе Contact собеседника.
    public var requestDestination: SIPURI {
        if let first = routeSet.first, first.hasParameter("lr") {
            return first
        }
        return remoteTarget
    }

    /// Готовит запрос внутри диалога. CSeq наращивается вызывающим через
    /// `nextSequence()` — кроме ACK, который обязан повторить номер INVITE.
    public func makeRequest(
        _ method: SIPMethod,
        sequence: Int,
        via: SIPVia,
        contact: NameAddress? = nil,
        userAgent: String? = nil,
        maxForwards: Int = 70
    ) -> SIPRequest {
        var request = SIPRequest(method: method, uri: remoteTarget)
        request.headers.append(SIPHeaderName.via, via.description)
        request.headers.append(SIPHeaderName.maxForwards, String(maxForwards))

        var from = localAddress
        from.tag = localTag
        request.headers.append(SIPHeaderName.from, from.description)

        var to = remoteAddress
        to.tag = remoteTag
        request.headers.append(SIPHeaderName.to, to.description)

        request.headers.append(SIPHeaderName.callID, callID)
        request.headers.append(SIPHeaderName.cseq, "\(sequence) \(method.rawValue)")

        // Route повторяет набор маршрутов; без него запрос внутри диалога
        // может не дойти через прокси.
        for route in routeSet {
            request.headers.append(SIPHeaderName.route, NameAddress(uri: route).description)
        }

        if let contact {
            request.headers.append(SIPHeaderName.contact, contact.description)
        }
        if let userAgent {
            request.headers.append(SIPHeaderName.userAgent, userAgent)
        }

        return request
    }

    /// Следующий номер CSeq. Возвращает обновлённый диалог, чтобы номер нельзя
    /// было случайно использовать дважды.
    public func nextSequence() -> (dialog: SIPDialog, sequence: Int) {
        var copy = self
        copy.localSequence += 1
        return (copy, copy.localSequence)
    }

    /// Совпадает ли ответ или запрос с этим диалогом.
    ///
    /// Сравниваются все три составляющих идентификатора диалога: Call-ID и оба
    /// тега. Только Call-ID недостаточно — при перезвоне он может повториться.
    public func matches(callID: String, localTag: String?, remoteTag: String?) -> Bool {
        guard callID == self.callID else { return false }
        guard let localTag, let remoteTag else { return false }
        return localTag == self.localTag && remoteTag == self.remoteTag
    }
}
