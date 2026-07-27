/// Генераторы одноразовых идентификаторов SIP.
///
/// Все токены обязаны быть непредсказуемыми: call-id и tag на публичном
/// интерфейсе — это часть защиты от подмешивания чужих сообщений в диалог.
/// Поэтому берём системный ГПСЧ, а не счётчик.
public enum SIPToken {

    /// RFC 3261 §8.1.1.7: branch на новой транзакции обязан начинаться с этой
    /// строки — по ней сервер отличает клиента, соблюдающего RFC 3261, от
    /// древних реализаций RFC 2543.
    public static let branchMagicCookie = "z9hG4bK"

    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    /// Случайная строка из букв и цифр — безопасна во всех позициях,
    /// где SIP ждёт token, и не требует экранирования.
    public static func random(length: Int) -> String {
        precondition(length > 0, "длина токена должна быть положительной")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in
            alphabet[Int(generator.next(upperBound: UInt64(alphabet.count)))]
        })
    }

    /// Значение для `Via: ...;branch=`.
    public static func branch() -> String {
        branchMagicCookie + random(length: 16)
    }

    /// Значение для заголовка `Call-ID`.
    ///
    /// Хост-часть опциональна: RFC её разрешает, но она раскрывает внутреннее
    /// имя машины, поэтому по умолчанию не добавляем.
    public static func callID(host: String? = nil) -> String {
        if let host, !host.isEmpty {
            "\(random(length: 24))@\(host)"
        } else {
            random(length: 32)
        }
    }

    /// Значение для параметра `tag=` в From/To.
    public static func tag() -> String {
        random(length: 12)
    }
}
