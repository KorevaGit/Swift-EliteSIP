import Foundation
import Testing
@testable import MediaCore

@Suite("Политика пересборки тракта")
struct AudioRestartPolicyTests {

    @Test("Первая неудача — не приговор")
    func firstFailureRetries() {
        // Это и есть суть правки: раньше единственная неудачная пересборка
        // означала конец разговора, и перевод AirPods на телефон и обратно
        // ронял звонок, который через секунду починился бы сам.
        var policy = AudioRestartPolicy()
        #expect(policy.recordFailure(at: 0) == .retry(after: 0.3, attempt: 1))
        #expect(policy.isRecovering)
    }

    @Test("Отсрочка растёт, но упирается в потолок")
    func delayBacksOffToCeiling() {
        // Растёт затем, чтобы не жечь попытки, пока устройство ещё в переходе.
        // Упирается затем, чтобы после возвращения устройства не ждать лишнего.
        var policy = AudioRestartPolicy(firstDelay: 0.3, maximumDelay: 2, budget: 100)
        var delays: [TimeInterval] = []
        var now = 0.0
        for _ in 0..<6 {
            guard case .retry(let after, _) = policy.recordFailure(at: now) else {
                Issue.record("политика сдалась раньше времени")
                return
            }
            delays.append(after)
            now += after
        }
        #expect(delays == [0.3, 0.6, 1.2, 2, 2, 2])
    }

    @Test("Номер попытки растёт — оператору есть что показать")
    func attemptsAreCounted() {
        var policy = AudioRestartPolicy()
        var attempts: [Int] = []
        var now = 0.0
        while case .retry(let after, let attempt) = policy.recordFailure(at: now) {
            attempts.append(attempt)
            now += after
        }
        // Нумерация сплошная и с единицы: «попытка 3» в журнале должна значить
        // ровно третью, иначе по журналу нельзя понять, сколько всего было.
        #expect(attempts == Array(1...attempts.count))
    }

    @Test("Запас терпения кончается, и тогда разговор пора закрывать")
    func budgetIsExhausted() {
        // Отступиться тоже надо: если устройства действительно больше нет,
        // молчащий разговор хуже завершённого.
        var policy = AudioRestartPolicy(firstDelay: 0.3, maximumDelay: 2, budget: 10)
        var now = 0.0
        var decision = policy.recordFailure(at: now)
        var rounds = 0
        while case .retry(let after, _) = decision, rounds < 100 {
            now += after
            decision = policy.recordFailure(at: now)
            rounds += 1
        }
        #expect(rounds < 100, "политика не сходится — попытки не кончаются")
        guard case .giveUp(let attempts, let elapsed) = decision else {
            Issue.record("ожидался отказ")
            return
        }
        #expect(attempts > 1, "сдаваться с первой попытки — прежнее поведение")
        #expect(elapsed <= 10)
    }

    @Test("Последняя попытка не назначается за пределы запаса")
    func lastRetryFitsInsideBudget() {
        // Проверка порядка: если сначала выдать отсрочку, а запас сверить
        // потом, оператор досидит до конца запаса и ещё две секунды сверх — уже
        // зная, что всё равно отказ.
        var policy = AudioRestartPolicy(firstDelay: 1, maximumDelay: 1, budget: 3)
        var now = 0.0
        var scheduled: [TimeInterval] = []
        while case .retry(let after, _) = policy.recordFailure(at: now) {
            now += after
            scheduled.append(now)
        }
        #expect(scheduled.allSatisfy { $0 <= 3 }, "попытка назначена за пределом запаса: \(scheduled)")
    }

    @Test("Успех обнуляет серию")
    func successResetsTheRun() {
        // Иначе вторая смена устройства за разговор начиналась бы с
        // исчерпанным запасом, и вторая пара наушников роняла бы звонок сразу.
        var policy = AudioRestartPolicy()
        _ = policy.recordFailure(at: 0)
        _ = policy.recordFailure(at: 0.3)
        policy.recordSuccess()

        #expect(!policy.isRecovering)
        #expect(policy.attemptCount == 0)
        #expect(policy.recordFailure(at: 60) == .retry(after: 0.3, attempt: 1))
    }

    @Test("Запас считается от первой неудачи, а не от каждой")
    func budgetRunsFromTheFirstFailure() {
        var policy = AudioRestartPolicy(firstDelay: 0.3, maximumDelay: 0.3, budget: 5)
        _ = policy.recordFailure(at: 100)
        // Прошло больше запаса — дальше тянуть нечего, сколько бы попыток ни
        // осталось.
        guard case .giveUp(_, let elapsed) = policy.recordFailure(at: 106) else {
            Issue.record("запас обязан кончиться по времени, а не по числу попыток")
            return
        }
        #expect(elapsed == 6)
    }

    @Test("Часы, идущие назад, не ломают счёт")
    func clockGoingBackwardsIsSurvivable() {
        // Часы монотонные, но защита стоит: отрицательное «прошло» превратило
        // бы запас в бесконечный, и разговор навсегда остался бы в состоянии
        // «восстанавливаю звук».
        var policy = AudioRestartPolicy(firstDelay: 0.3, maximumDelay: 0.3, budget: 1)
        _ = policy.recordFailure(at: 100)
        let decision = policy.recordFailure(at: 90)
        #expect(decision == .retry(after: 0.3, attempt: 2))
    }
}
