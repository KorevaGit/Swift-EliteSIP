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
        callerNumber.isEmpty ? "неизвестный номер" : callerNumber
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
    case emptyTarget
    /// Звонка, которым просят управлять, уже нет: обычно его отменили, пока
    /// оператор тянулся к кнопке.
    case noIncomingCall

    public var description: String {
        switch self {
        case .notRegistered: "нет регистрации на сервере"
        case .alreadyInCall: "звонок уже идёт"
        case .emptyTarget: "не задан номер"
        case .noIncomingCall: "входящего звонка больше нет"
        }
    }
}

/// Человеческое объяснение кода отказа.
///
/// Существует потому, что «сервер ответил 486» ничего не говорит оператору, а
/// «занято» говорит всё.
func describeCallFailure(status: Int, reason: String) -> String {
    switch status {
    case 486, 600: "занято"
    case 408: "не отвечает"
    case 480: "недоступен"
    case 404: "такого номера нет"
    case 403: "звонок запрещён"
    case 487: "звонок отменён"
    case 603: "отклонён"
    default: "отказ \(status) \(reason)"
    }
}
