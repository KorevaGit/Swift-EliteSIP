import Compat
import Foundation

/// Очередь доставки с двумя полосами: приоритетной и обычной.
///
/// Замена `AsyncStream` с `.bufferingNewest(n)` там, где вытеснение означает
/// потерю сигнализации. У общего буфера журнал и управление делят одно место:
/// сотня строк лога за секунду выталкивала `incomingCall` или `registration`,
/// и звонок, принятый агентом, до приложения не доезжал вовсе.
///
/// - Приоритетная полоса (управление) не вытесняется никогда. Её объём ограничен самой
///   природой событий (смена регистрации, три линии, одно закрытие канала),
///   поэтому предел у неё необязательный — на случай, когда поток задаёт сеть.
/// - Обычная полоса (журнал, новые запросы) ограничена, и при переполнении отклоняется
///   **новое**, а не старое: уже принятое не пропадает молча. Отклонённые
///   считаются, и потребитель узнаёт о пропуске элементом `dropNotice`.
/// - Приоритетное отдаётся раньше обычного, порядок внутри полосы сохраняется.
///
/// Потребитель один, как у `AsyncStream`. Отмена задачи, читающей очередь,
/// завершает чтение.
public final class SIPEventQueue<Element: Sendable>: AsyncSequence, @unchecked Sendable {

    public enum Lane: Sendable {
        case priority
        case regular
        /// Обычная полоса и её порядок, но сверх её предела — в запасе
        /// `priorityCapacity`. Для того, что закрывает уже принятое (ACK,
        /// CANCEL, BYE): отказывать ему при перегрузке нельзя, а обгонять свой
        /// INVITE — тем более.
        case essential
    }

    /// Чем закончилась попытка положить элемент.
    public enum YieldResult: Sendable, Equatable {
        case enqueued
        /// Полоса заполнена, элемент не принят.
        case rejected
        /// Очередь уже закрыта.
        case finished
    }

    private struct State: Sendable {
        var priority = Ring<Element>()
        var regular = Ring<Element>()
        var pendingDrops = 0
        var totalDrops = 0
        var finished = false
        var waiter: CheckedContinuation<Element?, Never>?
    }

    private let regularCapacity: Int
    private let priorityCapacity: Int?
    private let dropNotice: (@Sendable (Int) -> Element)?
    private let state = UnfairLock(initialState: State())

    /// - Parameters:
    ///   - regularCapacity: предел обычной полосы.
    ///   - priorityCapacity: предел приоритетной; `nil` — без предела.
    ///   - dropNotice: элемент, которым потребителю сообщают о пропуске N
    ///     элементов обычной полосы. Отдаётся перед следующим из неё.
    public init(
        regularCapacity: Int,
        priorityCapacity: Int? = nil,
        dropNotice: (@Sendable (Int) -> Element)? = nil
    ) {
        precondition(regularCapacity > 0)
        self.regularCapacity = regularCapacity
        self.priorityCapacity = priorityCapacity
        self.dropNotice = dropNotice
    }

    /// Сколько элементов обычной полосы отклонено за всё время.
    public var droppedCount: Int { state.withLock { $0.totalDrops } }

    /// Сколько элементов ждёт чтения в полосе.
    public func pendingCount(_ lane: Lane) -> Int {
        state.withLock { lane == .priority ? $0.priority.count : $0.regular.count }
    }

    @discardableResult
    public func yield(_ element: Element, lane: Lane) -> YieldResult {
        let (result, waiter): (YieldResult, CheckedContinuation<Element?, Never>?) = state.withLock { s in
            guard !s.finished else { return (.finished, nil) }
            switch lane {
            case .priority:
                if let priorityCapacity, s.priority.count >= priorityCapacity { return (.rejected, nil) }
                s.priority.append(element)
            case .essential:
                let limit = regularCapacity + (priorityCapacity ?? Int.max - regularCapacity)
                if s.regular.count >= limit { return (.rejected, nil) }
                s.regular.append(element)
            case .regular:
                guard s.regular.count < regularCapacity else {
                    s.pendingDrops += 1
                    s.totalDrops += 1
                    return (.rejected, nil)
                }
                s.regular.append(element)
            }
            guard let waiter = s.waiter else { return (.enqueued, nil) }
            s.waiter = nil
            return (.enqueued, waiter)
        }
        if let waiter { waiter.resume(returning: poll()) }
        return result
    }

    /// Закрывает очередь. Уже положенное дочитывается, потом чтение кончается.
    public func finish() {
        let waiter: CheckedContinuation<Element?, Never>? = state.withLock { s in
            s.finished = true
            defer { s.waiter = nil }
            return s.priority.isEmpty && s.regular.isEmpty ? s.waiter : nil
        }
        waiter?.resume(returning: nil)
    }

    /// Следующий элемент без ожидания; `nil` — пусто.
    private func poll() -> Element? { state.withLock { take(from: &$0) } }

    private func take(from s: inout State) -> Element? {
        if let element = s.priority.popFirst() { return element }
        if s.pendingDrops > 0, let dropNotice, !s.regular.isEmpty || s.finished {
            let count = s.pendingDrops
            s.pendingDrops = 0
            return dropNotice(count)
        }
        return s.regular.popFirst()
    }

    fileprivate func next() async -> Element? {
        if let element = poll() { return element }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Element?, Never>) in
                let immediate: (ready: Bool, element: Element?) = state.withLock { s in
                    if let element = take(from: &s) { return (true, element) }
                    if s.finished || Task.isCancelled { return (true, nil) }
                    s.waiter = continuation
                    return (false, nil)
                }
                if immediate.ready { continuation.resume(returning: immediate.element) }
            }
        } onCancel: {
            let waiter: CheckedContinuation<Element?, Never>? = state.withLock { s in
                s.finished = true
                defer { s.waiter = nil }
                return s.waiter
            }
            waiter?.resume(returning: nil)
        }
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate let queue: SIPEventQueue<Element>
        public mutating func next() async -> Element? { await queue.next() }
    }

    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(queue: self) }
}

/// Кольцевой буфер: `removeFirst` у массива линеен, а очередь на флуде длинная.
private struct Ring<Element: Sendable>: Sendable {
    private var storage: [Element?] = []
    private var head = 0
    private(set) var count = 0

    var isEmpty: Bool { count == 0 }

    mutating func append(_ element: Element) {
        if count == storage.count {
            var grown = [Element?](repeating: nil, count: max(8, storage.count * 2))
            for index in 0..<count { grown[index] = storage[(head + index) % storage.count] }
            storage = grown
            head = 0
        }
        storage[(head + count) % storage.count] = element
        count += 1
    }

    mutating func popFirst() -> Element? {
        guard count > 0 else { return nil }
        let element = storage[head]
        storage[head] = nil
        head = (head + 1) % storage.count
        count -= 1
        return element
    }
}
