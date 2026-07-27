/// Методы SIP, которые реально нужны EliteSIP.
///
/// Список намеренно короткий: то, чего нет в требованиях (PUBLISH, MESSAGE для
/// чата, SUBSCRIBE для BLF), не заводим, пока не появится задача.
public enum SIPMethod: String, Sendable, Hashable, CaseIterable {
    case invite = "INVITE"
    case ack = "ACK"
    case bye = "BYE"
    case cancel = "CANCEL"
    case register = "REGISTER"
    case options = "OPTIONS"
    /// Перевод звонка (M5).
    case refer = "REFER"
    /// Приходит от Asterisk с результатом REFER, а также как keep-alive-ответ.
    case notify = "NOTIFY"
    /// Альтернативный способ отправки DTMF, если rfc2833 на сервере выключен.
    case info = "INFO"

    /// Регистронезависимый разбор: в Via и CSeq метод всегда в верхнем регистре,
    /// но полагаться на это в парсере нельзя.
    public init?(name: some StringProtocol) {
        self.init(rawValue: name.uppercased())
    }

    /// Создаёт ли метод диалог при успешном ответе.
    public var createsDialog: Bool {
        self == .invite
    }

    /// Требует ли метод ACK на финальный ответ.
    public var requiresACK: Bool {
        self == .invite
    }
}
