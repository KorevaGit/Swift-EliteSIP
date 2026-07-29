import Foundation

/// Учётная запись SIP.
///
/// Пароля здесь нет и не будет: он живёт в Keychain и передаётся отдельно, в
/// `DigestAuthentication.Credentials`. Так его нельзя случайно записать в файл
/// настроек или в лог вместе со всей структурой.
public struct SIPAccount: Sendable, Hashable, Codable {

    /// Внутренний номер — он же user-part в address-of-record.
    public var username: String

    /// Логин для аутентификации, если он отличается от номера.
    public var authUsername: String?

    public var displayName: String

    /// Домен для From, To и Request-URI регистрации.
    public var domain: String

    /// Куда фактически подключаться, если это не `domain`.
    public var serverHost: String?
    public var serverPort: UInt16?

    public var transport: SIPTransport

    /// Запрашиваемый срок регистрации в секундах.
    public var registrationExpires: Int

    public init(
        username: String,
        authUsername: String? = nil,
        displayName: String = "",
        domain: String,
        serverHost: String? = nil,
        serverPort: UInt16? = nil,
        transport: SIPTransport = .tls,
        registrationExpires: Int = 300
    ) {
        self.username = username
        self.authUsername = authUsername
        self.displayName = displayName
        self.domain = domain
        self.serverHost = serverHost
        self.serverPort = serverPort
        self.transport = transport
        self.registrationExpires = registrationExpires
    }

    public var signalingEndpoint: SIPEndpoint {
        SIPEndpoint(
            host: serverHost?.isEmpty == false ? serverHost! : domain,
            port: serverPort ?? transport.defaultPort
        )
    }

    /// Request-URI для REGISTER.
    ///
    /// Схема всегда `sip:`, даже на TLS. `sips:` формально строже, но chan_sip
    /// на него реагирует непредсказуемо, а защиту здесь обеспечивает сам
    /// транспорт, а не буква в URI.
    public var registrarURI: SIPURI {
        SIPURI(host: domain)
    }

    /// Address-of-record: то, что стоит в From и To регистрации.
    public var addressOfRecord: SIPURI {
        SIPURI(user: username, host: domain)
    }

    public var effectiveAuthUsername: String {
        authUsername?.isEmpty == false ? authUsername! : username
    }

    /// Имя, которое уходит в `From`.
    ///
    /// Пустое поле означает не «имени нет», а «имя равно номеру»: по
    /// согласованному плану номер аккаунта служит и user-part, и отображаемым
    /// именем, и локальной меткой профиля. Без этой подстановки `From` уходил
    /// бы вовсе без display-name, и на плече агента вместо номера оператора
    /// сервер видел бы пустоту.
    public var effectiveDisplayName: String {
        displayName.isEmpty ? username : displayName
    }

    public var isUsable: Bool {
        !username.isEmpty && !domain.isEmpty
    }
}

public enum SIPRegistrationState: Sendable, Equatable {
    case idle
    case registering
    case registered(expiresAt: Date, contact: String)
    case unregistering
    case failed(reason: String, retryAt: Date?)

    public var isRegistered: Bool {
        if case .registered = self { true } else { false }
    }
}

public enum SIPLogLevel: String, Sendable, Hashable, Codable, Comparable, CaseIterable {
    case debug
    case info
    case warning
    case error

    private var rank: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .warning: 2
        case .error: 3
        }
    }

    public static func < (lhs: SIPLogLevel, rhs: SIPLogLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}
