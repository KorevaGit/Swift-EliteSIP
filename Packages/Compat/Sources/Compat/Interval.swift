import Darwin

/// Промежуток времени. Замена `Duration`, которого нет до macOS 13.
///
/// Хранится целыми наносекундами в `Int64`, а не парой «секунды + аттосекунды»,
/// как `Duration`. Аттосекунды в проекте не нужны ни разу: самый мелкий
/// интересующий нас интервал — 20 мс пакета RTP, а самый крупный — 32 секунды
/// таймера D. `Int64` наносекунд покрывает ±292 года, и деление на миллисекунды
/// в нём точное, без плавающей запятой.
///
/// Знак разрешён: разность двух моментов может быть отрицательной, и прятать это
/// значило бы молча превращать «нажал раньше, чем окно появилось» в ноль.
public struct Interval: Sendable, Hashable, Comparable {

    public let nanoseconds: Int64

    public init(nanoseconds: Int64) {
        self.nanoseconds = nanoseconds
    }

    public static let zero = Interval(nanoseconds: 0)

    public static func seconds(_ value: Int) -> Interval {
        Interval(nanoseconds: Int64(value) * 1_000_000_000)
    }

    public static func seconds(_ value: Double) -> Interval {
        Interval(nanoseconds: Int64((value * 1_000_000_000).rounded()))
    }

    public static func milliseconds(_ value: Int) -> Interval {
        Interval(nanoseconds: Int64(value) * 1_000_000)
    }

    public static func milliseconds(_ value: Double) -> Interval {
        Interval(nanoseconds: Int64((value * 1_000_000).rounded()))
    }

    public static func microseconds(_ value: Int) -> Interval {
        Interval(nanoseconds: Int64(value) * 1000)
    }

    public static func nanoseconds(_ value: Int) -> Interval {
        Interval(nanoseconds: Int64(value))
    }

    /// Целые миллисекунды.
    ///
    /// Отдельно от `seconds`, потому что в отчёте защиты нужны ровные числа:
    /// «реакция 210 мс» читается, «210.00004» — нет.
    public var wholeMilliseconds: Int {
        Int(nanoseconds / 1_000_000)
    }

    /// Секунды с дробной частью. Для API, которые принимают только `TimeInterval`.
    public var seconds: Double {
        Double(nanoseconds) / 1_000_000_000
    }

    public static func < (lhs: Interval, rhs: Interval) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }

    public static func + (lhs: Interval, rhs: Interval) -> Interval {
        Interval(nanoseconds: lhs.nanoseconds + rhs.nanoseconds)
    }

    public static func - (lhs: Interval, rhs: Interval) -> Interval {
        Interval(nanoseconds: lhs.nanoseconds - rhs.nanoseconds)
    }

    public static func * (lhs: Interval, rhs: Int) -> Interval {
        Interval(nanoseconds: lhs.nanoseconds * Int64(rhs))
    }

    public static func * (lhs: Int, rhs: Interval) -> Interval {
        rhs * lhs
    }

    public static prefix func - (value: Interval) -> Interval {
        Interval(nanoseconds: -value.nanoseconds)
    }
}

/// Монотонные часы. Замена `ContinuousClock`, которого нет до macOS 13.
///
/// `CLOCK_MONOTONIC_RAW` выбран потому же, почему стандартная библиотека берёт
/// его для `ContinuousClock`: он не зависит от настенного времени и продолжает
/// идти, пока Mac спит. Второе важно ровно там, где крышку закрывают посреди
/// разговора: `CLOCK_UPTIME_RAW` в этот момент замирает, и таймер транзакции
/// после пробуждения досчитывал бы старый интервал заново.
public enum MonotonicClock {

    public struct Instant: Sendable, Hashable, Comparable {

        /// Показание часов. Публичного смысла не имеет — только разности.
        public let rawNanoseconds: UInt64

        public init(rawNanoseconds: UInt64) {
            self.rawNanoseconds = rawNanoseconds
        }

        /// Сейчас. Как у `ContinuousClock.Instant`, чтобы на месте вызова
        /// хватало `.now` и тип не приходилось называть.
        public static var now: Instant { MonotonicClock.now }

        public static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.rawNanoseconds < rhs.rawNanoseconds
        }

        public static func + (lhs: Instant, rhs: Interval) -> Instant {
            Instant(rawNanoseconds: UInt64(bitPattern: Int64(bitPattern: lhs.rawNanoseconds) &+ rhs.nanoseconds))
        }

        public static func - (lhs: Instant, rhs: Interval) -> Instant {
            lhs + (-rhs)
        }

        /// Сколько прошло от `rhs` до `lhs`. Отрицательное, если наоборот.
        public static func - (lhs: Instant, rhs: Instant) -> Interval {
            Interval(nanoseconds: Int64(bitPattern: lhs.rawNanoseconds) &- Int64(bitPattern: rhs.rawNanoseconds))
        }
    }

    public static var now: Instant {
        Instant(rawNanoseconds: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW))
    }
}

public extension Task where Success == Never, Failure == Never {

    /// Пауза на `Interval`.
    ///
    /// Без метки аргумента намеренно: `Task.sleep(for:)` из стандартной
    /// библиотеки принимает `Duration`, и одноимённая перегрузка сделала бы
    /// `.milliseconds(100)` в каждом вызове неоднозначным.
    static func sleep(_ interval: Interval) async throws {
        guard interval > .zero else { return }
        try await Task.sleep(nanoseconds: UInt64(interval.nanoseconds))
    }
}
