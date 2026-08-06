import Foundation

/// Кто держит общий аудиотракт.
///
/// Вынесено из `VoiceAudioBus` по той же причине, что и `AudioRestartPolicy`:
/// это решение, а не действие, а всё, что живёт внутри работы с CoreAudio,
/// проверяется только руками и на живом железе. Здесь нет ни движка, ни
/// устройства — только ключи, поэтому ошибку видно тестом.
///
/// Ошибка, ради которой тип написан, одна и всегда одинаковая: **снятая линия
/// останавливает тракт, который уже забрала другая, живая.** Пока движок
/// создавался на каждый звонок, такое было невозможно по построению — каждая
/// линия глушила свой собственный. С общим трактом это первое, что сделает
/// любой запоздавший путь: отложенный `deinit`, повторный отбой, обработчик,
/// доехавший после переключения линий. Поэтому отпускание требует предъявить
/// тот же ключ, с которым тракт брали, а чужой ключ — тихий отказ, а не
/// ошибка: приходить с ним нормально, а вот заглушить чужой разговор нельзя.
public struct AudioOwnership: Sendable, Equatable {

    /// Чем кончилась попытка забрать тракт.
    public enum Outcome: Sendable, Equatable {
        /// Тракт был свободен.
        case granted
        /// Тракт отобран у прежнего владельца — он про это не узнает, и узнать
        /// ему неоткуда: сообщать некому, объект мог уже умереть.
        case replaced
        /// Тракт и так наш. Повторный захват — не ошибка: линию можно вернуть
        /// в разговор дважды подряд, если оператор быстро щёлкает.
        case alreadyOwned
    }

    private var holder: ObjectIdentifier?

    public init() {}

    /// Держит ли кто-нибудь тракт.
    public var isBusy: Bool { holder != nil }

    /// Наш ли звук сейчас.
    public func isOwner(_ token: ObjectIdentifier) -> Bool { holder == token }

    /// Забирает тракт.
    @discardableResult
    public mutating func take(_ token: ObjectIdentifier) -> Outcome {
        defer { holder = token }
        switch holder {
        case token: return .alreadyOwned
        case .some: return .replaced
        case .none: return .granted
        }
    }

    /// Отпускает тракт, если он за этим владельцем.
    ///
    /// Возврат `false` означает «не ваш» — и это единственный ответ, который
    /// защищает живой разговор от чужой остановки.
    @discardableResult
    public mutating func release(_ token: ObjectIdentifier) -> Bool {
        guard holder == token else { return false }
        holder = nil
        return true
    }
}
