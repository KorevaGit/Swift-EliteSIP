/// Транспорт для сигнализации.
///
/// В бою используется только `.tls` — клиент ходит через внешний домен по
/// открытому интернету, где отдавать digest-креды в открытый UDP нельзя.
/// `.udp` существует ради лаборатории: незашифрованный трафик читается в
/// Wireshark, и на этапах M1–M2 это экономит часы отладки.
public enum SIPTransport: String, Sendable, Hashable, CaseIterable {
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
