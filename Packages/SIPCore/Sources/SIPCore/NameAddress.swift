import Foundation

/// Значение заголовков From, To, Contact, Refer-To: `"Имя" <sip:100@host>;tag=x`.
public struct NameAddress: Sendable, Hashable, CustomStringConvertible {

    public var displayName: String?
    public var uri: SIPURI
    /// Параметры заголовка — это НЕ параметры URI. `<sip:a@b;transport=tls>;tag=1`:
    /// transport принадлежит URI, tag — заголовку.
    public var parameters: [SIPURI.Parameter]

    public init(displayName: String? = nil, uri: SIPURI, parameters: [SIPURI.Parameter] = []) {
        self.displayName = displayName
        self.uri = uri
        self.parameters = parameters
    }

    public init?(_ text: some StringProtocol) {
        let body = Substring(String(text)).trimmedSIP
        guard !body.isEmpty else { return nil }

        if let open = body.firstIndex(of: "<") {
            guard let close = body[open...].firstIndex(of: ">") else { return nil }

            let namePart = body[..<open].trimmedSIP
            displayName = namePart.isEmpty ? nil : SIPLexer.unquoted(namePart)

            guard let uri = SIPURI(body[body.index(after: open)..<close]) else { return nil }
            self.uri = uri

            let tail = body[body.index(after: close)...].trimmedSIP
            parameters = tail.isEmpty ? [] : SIPLexer.parseParameters(tail)
        } else {
            // Без угловых скобок display name невозможен, а параметры после ';'
            // принадлежат заголовку, не URI (RFC 3261 §20.10).
            displayName = nil
            if let semicolon = body.firstIndex(of: ";") {
                guard let uri = SIPURI(body[..<semicolon].trimmedSIP) else { return nil }
                self.uri = uri
                parameters = SIPLexer.parseParameters(body[semicolon...])
            } else {
                guard let uri = SIPURI(body) else { return nil }
                self.uri = uri
                parameters = []
            }
        }
    }

    // MARK: - Параметры

    public subscript(parameter name: String) -> String? {
        get {
            parameters.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        set {
            if let index = parameters.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                if let newValue {
                    parameters[index].value = newValue
                } else {
                    parameters.remove(at: index)
                }
            } else if let newValue {
                parameters.append(SIPURI.Parameter(name: name, value: newValue))
            }
        }
    }

    /// Тег диалога. Его сравнение — основа маршрутизации ответов и запросов
    /// внутри диалога, поэтому он вынесен отдельным свойством.
    public var tag: String? {
        get { self[parameter: "tag"] }
        set { self[parameter: "tag"] = newValue }
    }

    /// Значение `expires` у Contact в ответе на REGISTER: Asterisk может
    /// вернуть срок именно здесь, а не в заголовке Expires.
    public var expires: Int? {
        self[parameter: "expires"].flatMap { Int($0) }
    }

    // MARK: - Сериализация

    public var description: String {
        var result = ""
        if let displayName, !displayName.isEmpty {
            result += SIPLexer.quotedIfNeeded(displayName) + " "
        }
        // URI всегда в угловых скобках: без них параметры URI и параметры
        // заголовка становятся неразличимы для принимающей стороны.
        result += "<\(uri)>"
        for parameter in parameters {
            result += ";\(parameter.name)"
            if let value = parameter.value {
                result += "=\(SIPLexer.quotedIfNeeded(value))"
            }
        }
        return result
    }
}
