import Testing
@testable import Compat

/// Слой совместимости проверяется тестами по той же причине, по которой ими
/// проверяется всё остальное: на Catalina его поведение увидит только оператор,
/// а разница между «таймер T1 = 500 мс» и «таймер T1 = 0» — это разница между
/// работающей регистрацией и молчащим телефоном.
struct IntervalTests {

    @Test func фабрикиДаютНаносекунды() {
        #expect(Interval.seconds(1).nanoseconds == 1_000_000_000)
        #expect(Interval.milliseconds(500).nanoseconds == 500_000_000)
        #expect(Interval.microseconds(20).nanoseconds == 20_000)
        #expect(Interval.nanoseconds(7).nanoseconds == 7)
        #expect(Interval.zero.nanoseconds == 0)
    }

    @Test func дробныеСекундыОкругляются() {
        #expect(Interval.seconds(1.5) == .milliseconds(1500))
        #expect(Interval.milliseconds(0.5).nanoseconds == 500_000)
    }

    /// Ровные миллисекунды, а не 210.00004 — ради отчёта защиты.
    @Test func целыеМиллисекундыОтбрасываютОстаток() {
        #expect(Interval.nanoseconds(210_999_999).wholeMilliseconds == 210)
        #expect(Interval.seconds(32).wholeMilliseconds == 32_000)
    }

    /// Умножение и `min` — арифметика таймеров ретрансмиссии SIP: интервал
    /// удваивается до потолка T2, а таймер F равен 64·T1.
    @Test func арифметикаТаймеровРетрансмиссии() {
        let t1 = Interval.milliseconds(500)
        let t2 = Interval.seconds(4)

        #expect(t1 * 64 == .seconds(32))

        var interval = t1
        var steps = 0
        while interval < t2 {
            interval = min(interval * 2, t2)
            steps += 1
        }
        #expect(steps == 3)
        #expect(interval == t2)
    }

    /// Разность моментов бывает отрицательной: «нажал раньше, чем окно стало
    /// активным» — это факт, а не ноль.
    @Test func разностьМоментовСохраняетЗнак() {
        let start = MonotonicClock.now
        let earlier = start - .milliseconds(200)

        #expect((earlier - start).nanoseconds == -200_000_000)
        #expect((earlier - start).wholeMilliseconds == -200)
        #expect(earlier < start)
        #expect(start + .milliseconds(200) - .milliseconds(200) == start)
    }

    @Test func часыИдутВперёд() async throws {
        let start = MonotonicClock.now
        try await Task.sleep(.milliseconds(30))
        let elapsed = MonotonicClock.now - start

        #expect(elapsed >= .milliseconds(25))
        #expect(elapsed < .seconds(5))
    }

    /// Отрицательный и нулевой интервал не должны ни падать при переводе в
    /// `UInt64`, ни висеть.
    @Test func паузаНаНеположительныйИнтервалВозвращаетсяСразу() async throws {
        let start = MonotonicClock.now
        try await Task.sleep(.zero)
        try await Task.sleep(.milliseconds(-100))

        #expect(MonotonicClock.now - start < .seconds(1))
    }
}

struct UnfairLockTests {

    @Test func состояниеМеняетсяПодЗамком() {
        let counter = UnfairLock(initialState: 0)
        counter.withLock { $0 = 5 }
        counter.withLock { $0 += 1 }

        #expect(counter.withLock { $0 } == 6)
    }

    @Test func замокСериализуетПараллельныеИзменения() async {
        let counter = UnfairLock(initialState: 0)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<10_000 {
                        counter.withLock { $0 += 1 }
                    }
                }
            }
        }

        #expect(counter.withLock { $0 } == 80_000)
    }

    @Test func ошибкаИзТелаПробрасываетсяИОтпускаетЗамок() {
        struct Boom: Error {}
        let lock = UnfairLock(initialState: 1)

        #expect(throws: Boom.self) {
            try lock.withLock { (_: inout Int) -> Void in throw Boom() }
        }
        #expect(lock.withLock { $0 } == 1)
    }
}
