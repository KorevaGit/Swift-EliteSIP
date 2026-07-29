import Foundation

/// Идентификатор диалога для `Replaces` (RFC 3891).
///
/// При консультационном переводе REFER уходит по исходному разговору, а в
/// Refer-To описывает второй, консультационный. Сервер создаёт новый INVITE к
/// адресату и этим заголовком просит заменить уже существующий диалог.
public struct SIPDialogIdentifier: Sendable, Hashable {
    public let callID: String
    public let localTag: String
    public let remoteTag: String

    public init(callID: String, localTag: String, remoteTag: String) {
        self.callID = callID
        self.localTag = localTag
        self.remoteTag = remoteTag
    }

    init(dialog: SIPDialog) {
        self.init(
            callID: dialog.callID,
            localTag: dialog.localTag,
            remoteTag: dialog.remoteTag
        )
    }

    /// Значение Replaces с точки зрения получателя нового INVITE.
    ///
    /// Для локального диалога его собственный тег станет `from-tag`, а тег
    /// консультационного собеседника — `to-tag`: новый INVITE получит именно
    /// тот собеседник.
    public var headerValue: String {
        "\(callID);to-tag=\(remoteTag);from-tag=\(localTag)"
    }
}

/// Ход перевода после отправки REFER.
public enum SIPTransferEvent: Sendable, Equatable {
    /// Сервер принял REFER и начал перевод (обычно 202 Accepted).
    case accepted
    /// NOTIFY сообщил успешный финальный ответ на созданный INVITE.
    case succeeded
    /// REFER или созданный им INVITE завершился отказом.
    case failed(status: Int, reason: String)
}

public enum SIPTransferError: Error, Sendable, Equatable, CustomStringConvertible {
    case noActiveCall
    case emptyTarget
    case invalidTarget
    case alreadyTransferring
    case rejected(status: Int, reason: String)
    case timeout
    case transportFailed(String)

    public var description: String {
        switch self {
        case .noActiveCall: "разговора нет"
        case .emptyTarget: "не задан номер перевода"
        case .invalidTarget: "номер перевода содержит недопустимые символы"
        case .alreadyTransferring: "перевод уже выполняется"
        case .rejected(let status, let reason): "отказ \(status) \(reason)"
        case .timeout: "сервер не ответил"
        case .transportFailed(let reason): "сеть: \(reason)"
        }
    }
}

extension SIPDialogIdentifier {

    /// Кодирует значение Replaces как значение URI-header в Refer-To.
    ///
    /// `;` и `=` внутри query обязаны быть percent-encoded: иначе часть
    /// прокси воспринимает их как параметры самого Refer-To URI.
    var percentEncodedHeaderValue: String {
        // Не берём готовый urlQueryAllowed: он оставляет `%`, `@`, `&` и ряд
        // других разделителей. Вложенное значение header безопасно сохраняет
        // смысл только с белым списком RFC 3986 unreserved.
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-._~")
        )
        return headerValue.addingPercentEncoding(withAllowedCharacters: allowed) ?? headerValue
    }
}

/// Разбирает первую строку `message/sipfrag`, присылаемого в NOTIFY:
/// `SIP/2.0 200 OK`.
func parseSIPFragmentStatus(_ body: Data) -> (status: Int, reason: String)? {
    guard let text = String(data: body, encoding: .utf8),
          let firstLine = text.split(whereSeparator: \.isNewline).first
    else { return nil }

    let parts = firstLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
    guard parts.count >= 2,
          parts[0].caseInsensitiveCompare("SIP/2.0") == .orderedSame,
          let status = Int(parts[1])
    else { return nil }

    return (status, parts.count == 3 ? String(parts[2]) : "")
}
