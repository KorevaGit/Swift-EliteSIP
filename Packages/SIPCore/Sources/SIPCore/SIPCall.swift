import Foundation

/// Состояние исходящего звонка.
public enum SIPCallState: Sendable, Equatable {
    case dialing
    /// Пришёл 180 или 183: на той стороне звонит.
    case ringing
    case answered
    case ending
    case ended(reason: String)

    public var isActive: Bool {
        switch self {
        case .dialing, .ringing, .answered, .ending: true
        case .ended: false
        }
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

    public var description: String {
        switch self {
        case .notRegistered: "нет регистрации на сервере"
        case .alreadyInCall: "звонок уже идёт"
        case .emptyTarget: "не задан номер"
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
