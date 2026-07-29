import Compat
import CoreGraphics
import Foundation
import Testing
@testable import CallGuard

/// Генератор с заданной последовательностью — чтобы «случайное» задание было
/// известно заранее и проверялось точно, а не «примерно».
struct SequenceGenerator: RandomNumberGenerator {
    private var values: [UInt64]
    private var index = 0

    init(_ values: [UInt64]) {
        self.values = values
    }

    mutating func next() -> UInt64 {
        defer { index += 1 }
        return values[index % values.count]
    }
}

@Suite("Защита от автокликеров")
struct CallGuardSessionTests {

    private let start = MonotonicClock.now

    /// Политика с включённым цифровым подтверждением: по умолчанию оно
    /// выключено, а проверять выбор цели надо именно на нём.
    private var withDigits: CallGuardPolicy {
        var policy = CallGuardPolicy()
        policy.targetCount = 3
        return policy
    }

    private func session(
        policy: CallGuardPolicy = CallGuardPolicy(),
        seed: [UInt64] = [7, 11, 13, 17, 19, 23]
    ) -> CallGuardSession {
        var generator = SequenceGenerator(seed)
        return CallGuardSession(policy: policy, presentedAt: start, using: &generator)
    }

    /// Курсор, прошедший по окну как рука, а не как телепорт.
    private func moveCursorLikeHuman(_ session: inout CallGuardSession, steps: Int = 10) {
        for step in 0...steps {
            session.noteCursor(at: CGPoint(x: Double(step) * 12, y: Double(step) * 5))
        }
    }

    private func mouseAttempt(
        on session: CallGuardSession,
        after milliseconds: Int,
        target: Character? = nil,
        isSynthetic: Bool = false
    ) -> CallGuardAttempt {
        CallGuardAttempt(
            source: .mouse,
            target: target ?? session.challenge.answer,
            isSynthetic: isSynthetic,
            at: start + .milliseconds(milliseconds)
        )
    }

    // MARK: - Задание

    @Test("По умолчанию цифрового подтверждения нет — есть только случайность")
    func digitChallengeIsOptional() {
        let session = session()
        // Основная мера — случайная позиция и задержка: они ничего не стоят
        // оператору. Выбор цифры стоит внимания на каждом вызове, поэтому
        // включается отдельно.
        #expect(session.challenge.hasChoice == false)
        #expect(session.challenge.activationDelay > .zero)
        #expect(session.report.wasGuardEnabled)
    }

    @Test("Без цифрового подтверждения приём работает обычной кнопкой")
    func acceptsWithoutDigitChallenge() {
        var session = session()
        moveCursorLikeHuman(&session)

        let delay = session.challenge.activationDelay.wholeMilliseconds
        #expect(session.evaluate(attempt: mouseAttempt(on: session, after: delay + 100)) == .accepted)
    }

    @Test("Задание собирается из непересекающихся целей и попадает в диапазон задержки")
    func buildsChallenge() {
        for seed in UInt64(0)..<32 {
            var generator = SequenceGenerator([seed, seed &* 3 &+ 1, seed &+ 7])
            let session = CallGuardSession(policy: withDigits, presentedAt: start, using: &generator)

            #expect(session.challenge.targets.count == 3)
            #expect(Set(session.challenge.targets).count == 3, "две одинаковые цифры сделали бы задание неразрешимым")
            #expect(session.challenge.targets.contains(session.challenge.answer))

            let delay = session.challenge.activationDelay.wholeMilliseconds
            #expect(delay >= 300 && delay <= 1500)
        }
    }

    @Test("Выключенная защита не задаёт ни задержки, ни выбора")
    func disabledPolicyProducesNoChallenge() {
        let session = session(policy: .disabled)
        #expect(session.challenge.activationDelay == .zero)
        #expect(session.challenge.hasChoice == false)
        #expect(session.report.wasGuardEnabled == false)
    }

    @Test("Перевёрнутый диапазон задержки не выключает защиту молча")
    func normalizesBrokenPolicy() {
        var broken = CallGuardPolicy()
        broken.minimumActivationDelayMilliseconds = 900
        broken.maximumActivationDelayMilliseconds = 100
        broken.targetCount = 0

        let normalized = broken.normalized
        #expect(normalized.maximumActivationDelayMilliseconds >= normalized.minimumActivationDelayMilliseconds)
        #expect(normalized.targetCount == 1)

        var generator = SequenceGenerator([5])
        let session = CallGuardSession(policy: broken, presentedAt: start, using: &generator)
        #expect(session.challenge.activationDelay == .milliseconds(900))
    }

    // MARK: - Слой 1: случайность

    @Test("Клик раньше активации не принимается и попадает в отчёт")
    func rejectsEarlyClick() {
        var session = session()
        moveCursorLikeHuman(&session)

        let delay = session.challenge.activationDelay.wholeMilliseconds
        let verdict = session.evaluate(attempt: mouseAttempt(on: session, after: delay - 1))

        #expect(verdict == .rejected(.tooEarly))
        #expect(session.report.rejections[.tooEarly] == 1)
        #expect(session.report.confirmedBy == nil)
        #expect(session.report.looksAutomated)
    }

    @Test("После активации тот же клик принимается")
    func acceptsAfterActivation() {
        var session = session()
        moveCursorLikeHuman(&session)

        let delay = session.challenge.activationDelay.wholeMilliseconds
        let verdict = session.evaluate(attempt: mouseAttempt(on: session, after: delay + 200))

        #expect(verdict == .accepted)
        #expect(session.report.confirmedBy == .mouse)
        #expect(session.report.reactionMilliseconds == delay + 200)
        #expect(session.report.looksAutomated == false)
    }

    @Test("Нажатие не на ту цель отклоняется, но роботом не считается")
    func rejectsWrongTarget() {
        var session = session(policy: withDigits)
        moveCursorLikeHuman(&session)

        let wrong = session.challenge.targets.first { $0 != session.challenge.answer }
        let verdict = session.evaluate(attempt: mouseAttempt(on: session, after: 2000, target: wrong))

        #expect(verdict == .rejected(.wrongTarget))
        // Промахнуться мимо кнопки — обычное человеческое дело, и поднимать по
        // этому поводу тревогу в EliteDash значит утопить её в ложных сигналах.
        #expect(session.report.looksAutomated == false)
    }

    // MARK: - Слой 2: признаки живого человека

    @Test("Клик без движения курсора не принимается")
    func rejectsClickWithoutCursorMovement() {
        var session = session()
        // Ровно то, что делает CGEvent.post: курсор оказывается в точке одним
        // событием, пути нет.
        session.noteCursor(at: CGPoint(x: 400, y: 300))

        let verdict = session.evaluate(attempt: mouseAttempt(on: session, after: 2000))
        #expect(verdict == .rejected(.noCursorMovement))
        #expect(session.report.cursorTravel == 0)
        #expect(session.report.looksAutomated)
    }

    @Test("Прыжок курсора в две точки не считается движением")
    func rejectsTeleportingCursor() {
        var session = session()
        session.noteCursor(at: CGPoint(x: 0, y: 0))
        session.noteCursor(at: CGPoint(x: 500, y: 500))

        // Пути много, а движений — одно: длинный прыжок дешевле подделать, чем
        // десяток мелких шагов, поэтому одного порога по длине мало.
        #expect(session.report.cursorTravel > 40)
        #expect(session.report.cursorSamples == 1)
        #expect(session.evaluate(attempt: mouseAttempt(on: session, after: 2000)) == .rejected(.noCursorMovement))
    }

    @Test("Клавиатуре движение курсора не требуется")
    func keyboardNeedsNoCursor() {
        var session = session()
        let attempt = CallGuardAttempt(
            source: .keyboard,
            target: session.challenge.answer,
            at: start + .milliseconds(2000)
        )

        #expect(session.evaluate(attempt: attempt) == .accepted)
        #expect(session.report.confirmedBy == .keyboard)
    }

    @Test("Синтетическое нажатие по умолчанию проходит, но остаётся в отчёте")
    func recordsSyntheticWithoutRejecting() {
        var session = session()
        moveCursorLikeHuman(&session)

        let verdict = session.evaluate(attempt: mouseAttempt(on: session, after: 2000, isSynthetic: true))

        // Признак подделывается, поэтому он не барьер. Но у честного оператора
        // он не встречается никогда — значит место ему в телеметрии.
        #expect(verdict == .accepted)
        #expect(session.report.rejections[.synthetic] == 1)
        #expect(session.report.looksAutomated)
    }

    @Test("Со включённым отсевом синтетическое нажатие не проходит")
    func rejectsSyntheticWhenAsked() {
        var policy = CallGuardPolicy()
        policy.rejectsSyntheticEvents = true
        var session = session(policy: policy)
        moveCursorLikeHuman(&session)

        let verdict = session.evaluate(attempt: mouseAttempt(on: session, after: 2000, isSynthetic: true))
        #expect(verdict == .rejected(.synthetic))
    }

    @Test("Выключенная защита принимает даже мгновенный синтетический клик")
    func disabledGuardAcceptsEverything() {
        var session = session(policy: .disabled)
        let attempt = CallGuardAttempt(source: .mouse, target: "1", isSynthetic: true, at: start)

        #expect(session.evaluate(attempt: attempt) == .accepted)
        // Отчёт при этом честно говорит, что защиты не было: в M8 по нему
        // видно, что звонок принят без проверок.
        #expect(session.report.wasGuardEnabled == false)
        #expect(session.report.summary == "защита выключена")
    }

    // MARK: - Отчёт

    @Test("Отчёт накапливает все отклонённые попытки")
    func reportCountsAttempts() {
        var session = session(policy: withDigits)
        let wrong = session.challenge.targets.first { $0 != session.challenge.answer }

        _ = session.evaluate(attempt: mouseAttempt(on: session, after: 10))
        _ = session.evaluate(attempt: mouseAttempt(on: session, after: 20))
        _ = session.evaluate(attempt: mouseAttempt(on: session, after: 2000, target: wrong))
        moveCursorLikeHuman(&session)
        _ = session.evaluate(attempt: mouseAttempt(on: session, after: 2100))

        #expect(session.report.rejections[.tooEarly] == 2)
        #expect(session.report.rejections[.wrongTarget] == 1)
        #expect(session.report.rejectedAttempts == 3)
        #expect(session.report.confirmedBy == .mouse)
        #expect(session.report.summary.contains("реакция 2100 мс"))
    }

    @Test("Отчёт переживает кодирование")
    func reportRoundTrips() throws {
        var session = session()
        moveCursorLikeHuman(&session)
        _ = session.evaluate(attempt: mouseAttempt(on: session, after: 10))
        _ = session.evaluate(attempt: mouseAttempt(on: session, after: 2000))

        let data = try JSONEncoder().encode(session.report)
        let restored = try JSONDecoder().decode(CallGuardReport.self, from: data)
        #expect(restored == session.report)
    }
}
