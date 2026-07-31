/// Транспорт для сигнализации.
///
/// В бою используется `.udp`: сверка 31 июля 2026 показала, что на боевом
/// Asterisk TLS выключен целиком (`TLS SIP Bindaddress: Disabled`), а у пира
/// рабочего места `Encryption: No`. Раньше здесь было написано обратное — что
/// в бою только `.tls`, — и это оказалось предположением, а не фактом.
/// Защита сейчас держится на сети (офис, L2TP VPN для удалённых), а не на
/// транспорте SIP; открытый риск отслеживается в M2b.
///
/// `.tls` остаётся поддерживаемым профилем клиента и целью M2b, а не мёртвым
/// кодом: включить его на сервере — это правка конфигурации, а не разработка.
public enum SIPTransport: String, Sendable, Hashable, Codable, CaseIterable {
    case udp
    case tcp
    case tls

    /// Порт по умолчанию по RFC 3261 §19.1.2.
    public var defaultPort: UInt16 {
        switch self {
        case .udp, .tcp: 5060
        case .tls: 5061
        }
    }

    public var isSecure: Bool {
        self == .tls
    }

    /// Значение для `Via: SIP/2.0/<protocol>` и для параметра `transport=`.
    public var protocolName: String {
        rawValue.uppercased()
    }

    /// Работает ли транспорт поверх потока, а не датаграмм.
    /// От этого зависят таймеры транзакций: на надёжном транспорте retransmit
    /// не нужен, и Timer A/E не запускаются.
    public var isReliable: Bool {
        switch self {
        case .udp: false
        case .tcp, .tls: true
        }
    }

    public init?(name: some StringProtocol) {
        self.init(rawValue: name.lowercased())
    }
}
