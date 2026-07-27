import Foundation

/// SIP- или SIPS-URI: `sip:100@pbx.example.com:5060;transport=tls`.
///
/// Разбор осознанно неполный относительно RFC 3261 §19.1 — не поддерживаются
/// пароль в userinfo (он депрекейтед) и header-часть после `?`. Обе штуки
/// Asterisk не присылает, а недостающее лучше добавить по факту, чем нести
/// мёртвый код.
public struct SIPURI: Hashable, Sendable, CustomStringConvertible {

    public enum Scheme: String, Sendable, Hashable, CaseIterable {
        case sip
        case sips
    }

    /// Параметры храним списком, а не словарём: порядок важен, потому что
    /// URI из входящего запроса иногда приходится возвращать байт-в-байт
    /// (например Refer-To в NOTIFY при переводе).
    public struct Parameter: Hashable, Sendable {
        public var name: String
        public var value: String?

        public init(name: String, value: String? = nil) {
            self.name = name
            self.value = value
        }
    }

    public var scheme: Scheme
    public var user: String?
    public var host: String
    public var port: UInt16?
    public var parameters: [Parameter]

    public init(
        scheme: Scheme = .sip,
        user: String? = nil,
        host: String,
        port: UInt16? = nil,
        parameters: [Parameter] = []
    ) {
        self.scheme = scheme
        self.user = user
        self.host = host
        self.port = port
        self.parameters = parameters
    }

    // MARK: - Разбор

    public init?(_ text: some StringProtocol) {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))

        guard let schemeEnd = rest.firstIndex(of: ":"),
              let scheme = Scheme(rawValue: rest[..<schemeEnd].lowercased())
        else { return nil }
        self.scheme = scheme
        rest = rest[rest.index(after: schemeEnd)...]

        // Header-часть отбрасываем, но её наличие не должно ронять разбор URI.
        if let headersStart = rest.firstIndex(of: "?") {
            rest = rest[..<headersStart]
        }

        // userinfo@ — берём последнюю '@', потому что она может встречаться
        // в экранированном виде внутри user-части.
        if let at = rest.lastIndex(of: "@") {
            let userinfo = rest[..<at]
            guard !userinfo.isEmpty else { return nil }
            // Пароль после ':' игнорируем.
            let user = userinfo.prefix(while: { $0 != ":" })
            guard !user.isEmpty else { return nil }
            self.user = String(user)
            rest = rest[rest.index(after: at)...]
        } else {
            self.user = nil
        }

        if let paramsStart = rest.firstIndex(of: ";") {
            let rawParameters = rest[rest.index(after: paramsStart)...]
            rest = rest[..<paramsStart]
            self.parameters = rawParameters
                .split(separator: ";", omittingEmptySubsequences: true)
                .map { raw in
                    if let eq = raw.firstIndex(of: "=") {
                        Parameter(name: String(raw[..<eq]), value: String(raw[raw.index(after: eq)...]))
                    } else {
                        Parameter(name: String(raw))
                    }
                }
        } else {
            self.parameters = []
        }

        guard !rest.isEmpty else { return nil }

        if rest.first == "[" {
            // IPv6-литерал: `[2001:db8::1]:5061`. Двоеточий внутри много,
            // поэтому его надо снять до разбора порта.
            guard let close = rest.firstIndex(of: "]") else { return nil }
            self.host = String(rest[rest.index(after: rest.startIndex)..<close])
            let tail = rest[rest.index(after: close)...]
            if tail.isEmpty {
                self.port = nil
            } else if tail.first == ":" {
                guard let port = UInt16(tail.dropFirst()) else { return nil }
                self.port = port
            } else {
                return nil
            }
        } else if let portSeparator = rest.lastIndex(of: ":") {
            guard let port = UInt16(rest[rest.index(after: portSeparator)...]) else { return nil }
            self.host = String(rest[..<portSeparator])
            self.port = port
        } else {
            self.host = String(rest)
            self.port = nil
        }

        guard !host.isEmpty else { return nil }
    }

    // MARK: - Доступ к параметрам

    /// Имена параметров по RFC регистронезависимы.
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
                parameters.append(Parameter(name: name, value: newValue))
            }
        }
    }

    public func hasParameter(_ name: String) -> Bool {
        parameters.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Транспорт из параметра `transport`, если он указан явно.
    public var transport: SIPTransport? {
        self[parameter: "transport"].flatMap { SIPTransport(name: $0) }
    }

    /// Порт, на который реально надо отправлять, с учётом схемы и транспорта.
    public func resolvedPort(defaultTransport: SIPTransport) -> UInt16 {
        if let port { return port }
        if scheme == .sips { return SIPTransport.tls.defaultPort }
        return (transport ?? defaultTransport).defaultPort
    }

    // MARK: - Сериализация

    public var description: String {
        var result = "\(scheme.rawValue):"
        if let user {
            result += "\(user)@"
        }
        // Хост с двоеточиями — это IPv6, его надо вернуть в скобках.
        result += host.contains(":") ? "[\(host)]" : host
        if let port {
            result += ":\(port)"
        }
        for parameter in parameters {
            result += ";\(parameter.name)"
            if let value = parameter.value {
                result += "=\(value)"
            }
        }
        return result
    }
}
