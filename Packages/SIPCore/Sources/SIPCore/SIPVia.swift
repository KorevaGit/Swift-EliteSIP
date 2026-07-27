import Foundation

/// Заголовок Via: `SIP/2.0/UDP 10.0.0.5:5060;branch=z9hG4bK…;rport;received=…`.
///
/// Для нас он важнее, чем кажется: параметры `received` и `rport`, которые
/// Asterisk дописывает в верхний Via ответа, — единственный способ узнать, каким
/// адресом и портом нас видно снаружи NAT. Без этого Contact в регистрации
/// указывает на локальный адрес, и входящие звонки просто не доходят.
public struct SIPVia: Sendable, Hashable, CustomStringConvertible {

    public static let protocolPrefix = "SIP/2.0"

    public var transport: SIPTransport
    public var host: String
    public var port: UInt16?
    public var parameters: [SIPURI.Parameter]

    public init(
        transport: SIPTransport,
        host: String,
        port: UInt16? = nil,
        parameters: [SIPURI.Parameter] = []
    ) {
        self.transport = transport
        self.host = host
        self.port = port
        self.parameters = parameters
    }

    public init?(_ text: some StringProtocol) {
        let body = Substring(String(text)).trimmedSIP

        // sent-protocol и sent-by разделены пробелом (или несколькими).
        guard let space = body.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }

        let sentProtocol = body[..<space]
        let protocolParts = sentProtocol.split(separator: "/")
        guard protocolParts.count == 3,
              protocolParts[0].uppercased() == "SIP",
              protocolParts[1] == "2.0",
              let transport = SIPTransport(name: protocolParts[2])
        else { return nil }
        self.transport = transport

        var sentBy = body[body.index(after: space)...].trimmedSIP
        if let semicolon = sentBy.firstIndex(of: ";") {
            parameters = SIPLexer.parseParameters(sentBy[semicolon...])
            sentBy = sentBy[..<semicolon].trimmedSIP
        } else {
            parameters = []
        }

        guard !sentBy.isEmpty else { return nil }

        if sentBy.first == "[" {
            guard let close = sentBy.firstIndex(of: "]") else { return nil }
            host = String(sentBy[sentBy.index(after: sentBy.startIndex)..<close])
            let tail = sentBy[sentBy.index(after: close)...]
            if tail.isEmpty {
                port = nil
            } else if tail.first == ":" {
                guard let value = UInt16(tail.dropFirst()) else { return nil }
                port = value
            } else {
                return nil
            }
        } else if let colon = sentBy.lastIndex(of: ":") {
            guard let value = UInt16(sentBy[sentBy.index(after: colon)...]) else { return nil }
            host = String(sentBy[..<colon])
            port = value
        } else {
            host = String(sentBy)
            port = nil
        }

        guard !host.isEmpty else { return nil }
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

    public func hasParameter(_ name: String) -> Bool {
        parameters.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public var branch: String? {
        get { self[parameter: "branch"] }
        set { self[parameter: "branch"] = newValue }
    }

    /// Адрес, с которого сервер реально увидел запрос.
    public var received: String? { self[parameter: "received"] }

    /// Порт, с которого сервер реально увидел запрос.
    ///
    /// В запросе `rport` присутствует без значения — это просьба сервер его
    /// заполнить. В ответе значение появляется. Поэтому «параметр есть» и
    /// «параметр со значением» здесь разные вещи.
    public var rport: UInt16? {
        self[parameter: "rport"].flatMap { UInt16($0) }
    }

    /// Просит сервер дописать received/rport (RFC 3581).
    public mutating func requestRport() {
        guard !hasParameter("rport") else { return }
        parameters.append(SIPURI.Parameter(name: "rport"))
    }

    /// Адрес и порт, на которые надо отправлять ответы и куда сервер будет
    /// присылать входящие: то, что видно снаружи, если сервер это сообщил.
    public var observedAddress: (host: String, port: UInt16?)? {
        guard let received else { return nil }
        return (received, rport ?? port)
    }

    // MARK: - Сериализация

    public var description: String {
        var result = "\(Self.protocolPrefix)/\(transport.protocolName) "
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
