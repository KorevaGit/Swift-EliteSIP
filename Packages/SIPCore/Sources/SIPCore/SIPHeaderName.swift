/// Канонизация имён заголовков.
///
/// В SIP имя заголовка регистронезависимо и у части заголовков есть однобуквенная
/// компактная форма (RFC 3261 §20). Хранить их как пришло — значит ловить баги
/// вида «`Call-ID` есть, а `call-id` нет». Поэтому при разборе имя сразу
/// приводится к каноническому виду, а компактная форма разворачивается.
public enum SIPHeaderName {

    // MARK: - Часто используемые имена

    public static let via = "Via"
    public static let from = "From"
    public static let to = "To"
    public static let callID = "Call-ID"
    public static let cseq = "CSeq"
    public static let contact = "Contact"
    public static let maxForwards = "Max-Forwards"
    public static let expires = "Expires"
    public static let contentLength = "Content-Length"
    public static let contentType = "Content-Type"
    public static let userAgent = "User-Agent"
    public static let allow = "Allow"
    public static let supported = "Supported"
    public static let authorization = "Authorization"
    public static let proxyAuthorization = "Proxy-Authorization"
    public static let wwwAuthenticate = "WWW-Authenticate"
    public static let proxyAuthenticate = "Proxy-Authenticate"
    public static let route = "Route"
    public static let recordRoute = "Record-Route"
    public static let referTo = "Refer-To"
    public static let referredBy = "Referred-By"
    public static let event = "Event"
    public static let subscriptionState = "Subscription-State"
    public static let minExpires = "Min-Expires"
    public static let retryAfter = "Retry-After"
    public static let reason = "Reason"
    public static let requireHeader = "Require"

    /// Компактные формы (RFC 3261 §20 и RFC 3515/6665 для refer/event).
    private static let compactForms: [String: String] = [
        "i": callID,
        "m": contact,
        "e": "Content-Encoding",
        "l": contentLength,
        "c": contentType,
        "f": from,
        "s": "Subject",
        "k": supported,
        "t": to,
        "v": via,
        "r": referTo,
        "b": referredBy,
        "o": event,
        "u": "Allow-Events",
    ]

    /// Каноническое написание для заголовков, где Title-Case недостаточно.
    private static let canonicalSpellings: [String: String] = {
        let names = [
            via, from, to, callID, cseq, contact, maxForwards, expires,
            contentLength, contentType, userAgent, allow, supported,
            authorization, proxyAuthorization, wwwAuthenticate, proxyAuthenticate,
            route, recordRoute, referTo, referredBy, event, subscriptionState,
            minExpires, retryAfter, reason, requireHeader,
            "Content-Encoding", "Subject", "Allow-Events", "Accept",
            "Session-Expires", "Min-SE", "Unsupported", "Proxy-Require",
            "Warning", "Server", "Date", "Timestamp", "Organization",
            "Subject", "Priority", "In-Reply-To", "Replaces", "Referred-By",
        ]
        return Dictionary(names.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
    }()

    /// Заголовки, у которых несколько значений законно перечисляются через
    /// запятую в одной строке.
    ///
    /// Список именно белый, а не чёрный, и это принципиально: в
    /// `WWW-Authenticate: Digest realm="a", nonce="b"` запятая разделяет
    /// параметры одного значения. Разрезав такой заголовок, мы получим мусор.
    private static let commaSeparatedHeaders: Set<String> = [
        via.lowercased(), route.lowercased(), recordRoute.lowercased(),
        contact.lowercased(), allow.lowercased(), supported.lowercased(),
        requireHeader.lowercased(), "proxy-require", "unsupported",
        "allow-events", "accept", "content-encoding", "accept-encoding",
        "accept-language", "in-reply-to",
    ]

    /// Приводит имя к каноническому виду, разворачивая компактную форму.
    public static func canonical(_ name: some StringProtocol) -> String {
        let lowered = name.trimmedSIPName.lowercased()

        if lowered.count == 1, let expanded = compactForms[lowered] {
            return expanded
        }

        if let known = canonicalSpellings[lowered] {
            return known
        }

        // Незнакомый заголовок: Title-Case по дефисам, чтобы хотя бы выглядел
        // однородно с остальными.
        return lowered
            .split(separator: "-", omittingEmptySubsequences: false)
            .map { part in
                guard let first = part.first else { return "" }
                return first.uppercased() + part.dropFirst()
            }
            .joined(separator: "-")
    }

    public static func allowsCommaSeparatedValues(_ canonicalName: String) -> Bool {
        commaSeparatedHeaders.contains(canonicalName.lowercased())
    }
}

private extension StringProtocol {
    var trimmedSIPName: String {
        String(Substring(String(self)).trimmedSIP)
    }
}
