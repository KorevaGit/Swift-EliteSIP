import Darwin

/// Замок вокруг состояния. Замена `OSAllocatedUnfairLock`, которого нет до
/// macOS 13.
///
/// `os_unfair_lock`, а не очередь и не `NSLock`: под этим замком живут кольцевые
/// буферы аудиотракта, к которым обращается поток реального времени CoreAudio.
/// Критическая секция там несколько микросекунд, а любое ожидание в рендере
/// слышно как щелчок.
///
/// Класс, а не структура: `os_unfair_lock` нельзя копировать и нельзя двигать в
/// памяти, а структура со стороны Swift копируется молча. Само состояние тоже
/// лежит в выделенной памяти, а не в свойстве класса, — так к нему не
/// применяется динамическая проверка исключительного доступа, которой в потоке
/// реального времени быть не должно.
///
/// `State: Sendable` — то же требование, что у `OSAllocatedUnfairLock.withLock`.
/// Замыкание не помечено `@Sendable` намеренно: оно исполняется синхронно и не
/// переживает вызов, а требование от него `@Sendable` заставило бы переписывать
/// места, где под замком читается свойство `self`.
public final class UnfairLock<State: Sendable>: @unchecked Sendable {

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let state: UnsafeMutablePointer<State>

    public init(initialState: State) {
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        state = UnsafeMutablePointer<State>.allocate(capacity: 1)
        state.initialize(to: initialState)
    }

    deinit {
        state.deinitialize(count: 1)
        state.deallocate()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    public func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return try body(&state.pointee)
    }
}
