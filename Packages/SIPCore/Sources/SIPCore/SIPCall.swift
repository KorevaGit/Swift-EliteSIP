import Foundation

/// Состояние звонка в любую сторону.
public enum SIPCallState: Sendable, Equatable {
    case dialing
    /// Пришёл 180 или 183: на той стороне звонит.
    case ringing
    /// Нам звонят: INVITE принят, мы ответили 180, решение за оператором.
    case incoming
    case answered
    case ending
    case ended(reason: String)

    public var isActive: Bool {
        switch self {
        case .dialing, .ringing, .incoming, .answered, .ending: true
        case .ended: false
        }
    }
}

/// Входящий звонок в том виде, в каком о нём можно судить до ответа.
///
/// Событий у него столько же, сколько у исходящего, и приезжают они тем же
/// потоком: отменённый до ответа вызов — это `.ended`, и окно надо убрать
/// ровно так же, как при обычном завершении.
public struct SIPIncomingCall: Sendable {

    public let callID: String

    /// Номер звонящего из From. При раздаче лидов это номер очереди, а не
    /// клиента: клиентский в SIP не приходит вовсе (см. README про CDR).
    public let callerNumber: String

    /// Отображаемое имя из From, если сервер его прислал.
    public let callerName: String?

    /// Номер, на который звонили. Отличается от нашего, когда вызов пришёл
    /// через очередь или переадресацию.
    public let calledNumber: String

    /// Предложение SDP. Разбирает его тот, кто владеет медиа.
    public let offer: Data
    public let offerContentType: String?

    /// События этого звонка: отмена до ответа, завершение, ошибки.
    public let events: AsyncStream<SIPCallEvent>

    public init(
        callID: String,
        callerNumber: String,
        callerName: String?,
        calledNumber: String,
        offer: Data,
        offerContentType: String?,
        events: AsyncStream<SIPCallEvent>
    ) {
        self.callID = callID
        self.callerNumber = callerNumber
        self.callerName = callerName
        self.calledNumber = calledNumber
        self.offer = offer
        self.offerContentType = offerContentType
        self.events = events
    }

    /// Что показать в окне крупным шрифтом.
    public var displayNumber: String {
        callerNumber.isEmpty
            ? NSLocalizedString("неизвестный номер", bundle: .module, comment: "входящий без номера")
            : callerNumber
    }
}

/// Исходящий звонок: линия и её события.
///
/// Call-ID отдаётся сразу, ещё до первого INVITE, потому что именно им линия
/// адресуется дальше — на удержание, перевод и завершение. Ждать его из потока
/// событий значило бы иметь окно, в котором звонок уже идёт, а сказать про него
/// нечего.
public struct SIPOutgoingCall: Sendable {
    public let callID: String
    public let events: AsyncStream<SIPCallEvent>

    public init(callID: String, events: AsyncStream<SIPCallEvent>) {
        self.callID = callID
        self.events = events
    }
}

/// События звонка для того, кто им управляет.
///
/// Тело SDP передаётся байтами: слой сигнализации не разбирает медиа и не
/// зависит от кодеков. Согласование делает вызывающий — так пакеты не начинают
/// зависеть друг от друга, а SIPCore остаётся тестируемым без аудио.
public enum SIPCallEvent: Sendable {
    case state(SIPCallState)
    /// Собеседник ответил. Тело — SDP-ответ, его нужно разобрать и запустить медиа.
    case answered(body: Data, contentType: String?)
    case failed(status: Int, reason: String)
    case ended(reason: String)
}

public enum SIPCallError: Error, Sendable, Equatable, CustomStringConvertible {
    case notRegistered
    case alreadyInCall
    /// Все линии заняты: разговор, консультация и третий участник.
    case tooManyLines(maximum: Int)
    case emptyTarget
    /// Звонка, которым просят управлять, уже нет: обычно его отменили, пока
    /// оператор тянулся к кнопке.
    case noIncomingCall

    public var description: String {
        switch self {
        case .notRegistered: NSLocalizedString("нет регистрации на сервере", bundle: .module, comment: "почему звонок не начался")
        case .alreadyInCall: NSLocalizedString("звонок уже идёт", bundle: .module, comment: "почему звонок не начался")
        case .tooManyLines(let maximum):
            String.localizedStringWithFormat(
                NSLocalizedString("заняты все линии (%lld)", bundle: .module, comment: "почему звонок не начался"),
                maximum
            )
        case .emptyTarget: NSLocalizedString("не задан номер", bundle: .module, comment: "почему звонок не начался")
        case .noIncomingCall: NSLocalizedString("входящего звонка больше нет", bundle: .module, comment: "почему звонок не начался")
        }
    }
}

/// Что могло пойти не так при пересогласовании медиа внутри разговора.
///
/// Отдельно от `SIPCallError` потому, что смысл у этих ошибок другой: звонок
/// после них продолжается. RFC 3261 §14.1 требует именно этого — отказ на
/// повторный INVITE оставляет разговор на прежних параметрах, а не завершает
/// его. Для оператора это значит «удержание не сработало», а не «связь упала».
public enum SIPRenegotiationError: Error, Sendable, Equatable, CustomStringConvertible {
    case noActiveCall
    /// Наш повторный INVITE уже в пути.
    case alreadyRenegotiating
    /// 491: собеседник прислал встречное предложение раньше нашего.
    case requestPending
    case rejected(status: Int, reason: String)
    case timeout
    case transportFailed(String)

    public var description: String {
        switch self {
        case .noActiveCall: NSLocalizedString("разговора нет", bundle: .module, comment: "почему пересогласование не пошло")
        case .alreadyRenegotiating:
            NSLocalizedString("пересогласование уже идёт", bundle: .module, comment: "почему пересогласование не пошло")
        case .requestPending:
            NSLocalizedString("собеседник пересогласовывает первым (491)", bundle: .module, comment: "почему пересогласование не пошло")
        case .rejected(let status, let reason):
            String(
                format: NSLocalizedString("отказ %1$lld %2$@", bundle: .module, comment: "почему пересогласование не пошло"),
                status,
                reason
            )
        case .timeout: NSLocalizedString("сервер не ответил", bundle: .module, comment: "почему пересогласование не пошло")
        case .transportFailed(let reason):
            String(format: NSLocalizedString("сеть: %@", bundle: .module, comment: "почему пересогласование не пошло"), reason)
        }
    }
}

/// Как отвечать на чужой повторный INVITE.
///
/// На вход — Call-ID линии и предложение SDP байтами, на выход — наш ответ или
/// nil, если принять предложение нечем (тогда уйдёт 488). Замыкание, а не
/// событие в потоке, ровно по одной причине: ответить надо в рамках той же
/// транзакции, и «отправить событие и надеяться, что кто-то ответит» здесь не
/// работает. Разбор SDP при этом остаётся снаружи — SIPCore про медиа не знает
/// ничего.
///
/// Call-ID обязателен: у оператора до трёх линий, и пересогласовать сервер
/// может ту, которая стоит на удержании.
public typealias SIPMediaRenegotiator = @Sendable (String, Data) async -> Data?

/// Человеческое объяснение кода отказа.
///
/// Существует потому, что «сервер ответил 486» ничего не говорит оператору, а
/// «занято» говорит всё.
func describeCallFailure(status: Int, reason: String) -> String {
    switch status {
    case 486, 600: NSLocalizedString("занято", bundle: .module, comment: "чем кончился звонок")
    case 408: NSLocalizedString("не отвечает", bundle: .module, comment: "чем кончился звонок")
    case 480: NSLocalizedString("недоступен", bundle: .module, comment: "чем кончился звонок")
    case 404: NSLocalizedString("такого номера нет", bundle: .module, comment: "чем кончился звонок")
    case 403: NSLocalizedString("звонок запрещён", bundle: .module, comment: "чем кончился звонок")
    case 487: NSLocalizedString("звонок отменён", bundle: .module, comment: "чем кончился звонок")
    case 603: NSLocalizedString("отклонён", bundle: .module, comment: "чем кончился звонок")
    default:
        String(
            format: NSLocalizedString("отказ %1$lld %2$@", bundle: .module, comment: "чем кончился звонок"),
            status,
            reason
        )
    }
}
