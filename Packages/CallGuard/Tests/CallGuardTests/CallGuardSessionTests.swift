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
            target: target ?? session.challenge.answer,
            isSynthetic: isSynthetic,
            at: start + .milliseconds(milliseconds)
        )
    }

    // MARK: - Задание

    @Test("По умолчанию цифрового подтверждения нет — есть только случайность")
    func digitChallengeIsOptional() {
        let session = session()
        // Основная мера — случайная позиция окна: она ничего не стоит оператору.
        // Выбор цифры стоит внимания на каждом вызове, поэтому включается
        // отдельно и осознанно.
        #expect(session.challenge.hasChoice == false)
        #expect(session.report.wasGuardEnabled)
    }

    @Test("Кнопка активна сразу: мгновенный клик живой руки принимается")
    func acceptsImmediateClick() {
        var session = session()
        moveCursorLikeHuman(&session)

        // Ноль миллисекунд от появления окна. Локальной задержки активации нет
        // намеренно: она стоила оператору внимания на каждом вызове, а кликеру —
        // одной строки ожидания. Ровное время реакции ловит статистика EliteDash.
        let verdict = session.evaluate(attempt: mouseAttempt(on: session, after: 0))

        #expect(verdict == .accepted)
        #expect(session.report.reactionMilliseconds == 0)
        #expect(session.report.looksAutomated == false)
    }

    @Test("Задание собирается из непересекающихся целей")
    func buildsChallenge() {
        for seed in UInt64(0)..<32 {
            var generator = SequenceGenerator([seed, seed &* 3 &+ 1, seed &+ 7])
            let session = CallGuardSession(policy: withDigits, presentedAt: start, using: &generator)

            #expect(session.challenge.targets.count == 3)
            #expect(Set(session.challenge.targets).count == 3, "две одинаковые цифры сделали бы задание неразрешимым")
            #expect(session.challenge.targets.contains(session.challenge.answer))
        }
    }

    @Test("Выключенная защита не задаёт выбора")
    func disabledPolicyProducesNoChallenge() {
        let session = session(policy: .disabled)
        #expect(session.challenge.hasChoice == false)
        #expect(session.report.wasGuardEnabled == false)
    }

    @Test("Сломанная политика не выключает защиту молча")
    func normalizesBrokenPolicy() {
        var broken = CallGuardPolicy()
        broken.targetCount = 0
        broken.requiredCursorTravel = -50
        broken.minimumTravel = -1

        let normalized = broken.normalized
        #expect(normalized.targetCount == 1)
        #expect(normalized.requiredCursorTravel == 0)
        #expect(normalized.minimumTravel == 0)
    }

    @Test("Старый файл настроек не возвращает задержку активации")
    func ignoresRetiredDelayKeys() throws {
        // Файл, записанный до удаления задержки. Ключи должны быть молча
        // проигнорированы: подхватить их значило бы вернуть поведение, от
        // которого отказались, — и вернуть его тихо, одним старым файлом.
        let old = Data("""
        {
          "isEnabled": true,
          "minimumActivationDelayMilliseconds": 900,
          "maximumActivationDelayMilliseconds": 1500,
          "targetCount": 1
        }
        """.utf8)

        let policy = try JSONDecoder().decode(CallGuardPolicy.self, from: old)
        #expect(policy.isEnabled)

        var generator = SequenceGenerator([5])
        var session = CallGuardSession(policy: policy, presentedAt: start, using: &generator)
        moveCursorLikeHuman(&session)
        #expect(session.evaluate(attempt: mouseAttempt(on: session, after: 0)) == .accepted)

        // И обратно: удалённые ключи не должны появиться в новом файле.
        let encoded = try JSONEncoder().encode(policy)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(text.contains("ActivationDelay") == false)
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
        let attempt = CallGuardAttempt(target: "1", isSynthetic: true, at: start)

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

        // Два нажатия без движения курсора, одно мимо цели, и только потом
        // честная попытка живой руки.
        _ = session.evaluate(attempt: mouseAttempt(on: session, after: 10))
        _ = session.evaluate(attempt: mouseAttempt(on: session, after: 20))
        _ = session.evaluate(attempt: mouseAttempt(on: session, after: 2000, target: wrong))
        moveCursorLikeHuman(&session)
        _ = session.evaluate(attempt: mouseAttempt(on: session, after: 2100))

        #expect(session.report.rejections[.noCursorMovement] == 2)
        #expect(session.report.rejections[.wrongTarget] == 1)
        #expect(session.report.rejectedAttempts == 3)
        #expect(session.report.reactionMilliseconds == 2100)
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
