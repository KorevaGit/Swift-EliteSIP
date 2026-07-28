import Foundation

/// Что происходит с входящим INVITE после того, как мы на него ответили.
///
/// Слой транзакций сам по себе звонок не ведёт, но две вещи знает только он:
/// дошёл ли до собеседника наш финальный ответ и не пора ли перестать его
/// повторять. Обе важны для звонка целиком, поэтому уезжают наверх событием.
public enum SIPServerInviteEvent: Sendable {
    /// Пришёл ACK: собеседник принял наш ответ, повторять его больше не нужно.
    case acknowledged(callID: String)

    /// ACK не пришёл за 64*T1.
    ///
    /// По RFC 3261 §13.3.1.4 это конец: диалог формально установлен нашим 200,
    /// но подтверждения нет, и звонок надо закрывать через BYE. Иначе получится
    /// разговор, о котором знаем только мы.
    case notAcknowledged(callID: String)
}

extension SIPTransactionLayer {

    /// Ключ, по которому ACK находит серверную транзакцию.
    ///
    /// Branch не годится: ACK на 2xx по RFC 3261 §17.1.1.3 — отдельная
    /// транзакция со своим branch, и совпадать с INVITE он не обязан. Общими
    /// остаются Call-ID и номер CSeq, их и берём.
    static func acknowledgementKey(callID: String, sequence: Int) -> String {
        "\(callID)|\(sequence)"
    }

    static func acknowledgementKey(for message: some SIPMessageProtocol) -> String? {
        guard let callID = message.callID, let cseq = message.cseq else { return nil }
        return acknowledgementKey(callID: callID, sequence: cseq.number)
    }
}
