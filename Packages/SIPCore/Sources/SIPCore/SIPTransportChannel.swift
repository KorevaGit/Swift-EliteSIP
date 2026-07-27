import Foundation

public struct SIPEndpoint: Sendable, Hashable, CustomStringConvertible {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public var description: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

public enum SIPTransportEvent: Sendable {
    /// Канал готов, известен локальный адрес. Он нужен для Via и Contact.
    case ready(local: SIPEndpoint)
    /// Одно целое сообщение. Транспорт сам решает задачу нарезки: на UDP это
    /// датаграмма, на TLS — работа фреймера. Выше уровнем разницы не видно.
    case received(Data)
    case failed(reason: String)
    case cancelled
}

/// Канал доставки SIP-сообщений.
///
/// Протокол существует ради двух вещей: подменить сеть в тестах и заменить
/// реализацию транспорта, не трогая ни транзакции, ни регистрацию.
public protocol SIPTransportChannel: Sendable {
    var transport: SIPTransport { get }
    var remote: SIPEndpoint { get }
    var events: AsyncStream<SIPTransportEvent> { get }

    func start() async
    func send(_ data: Data) async throws
    func stop() async
}

/// Как проверять сертификат сервера на TLS.
public enum SIPTLSTrust: Sendable, Hashable {
    /// Обычная системная проверка. Единственный правильный режим для боя.
    case system
    /// Доверять сертификату с указанным отпечатком SHA-256 (DER сертификата).
    /// Нужен для самоподписанного сертификата лаборатории.
    case pinnedCertificateSHA256(Set<Data>)
    /// Принимать любой сертификат.
    ///
    /// Это отключение защиты от MITM: перехватчик сможет прочитать пароль
    /// от SIP и разговор целиком. Допустимо только против localhost в
    /// лаборатории, поэтому режим назван так, чтобы его нельзя было включить
    /// случайно, и в интерфейсе он живёт под отдельным предупреждением.
    case acceptAnyCertificateInsecurely
}
