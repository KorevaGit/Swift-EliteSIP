import Compat
import Foundation

/// Что окно должно показать, чтобы приём вызова требовал человека.
///
/// Собирается один раз на звонок и больше не меняется: перерисовка целей под
/// уже потянувшейся рукой оператора — это не защита, а издевательство.
public struct CallGuardChallenge: Sendable, Hashable {

    /// Больше девяти целей не бывает: цифра должна нажиматься одной клавишей,
    /// а ноль в ряду цифр читается хуже остальных.
    public static let maximumTargets = 9

    /// Цифры на кнопках, слева направо.
    public let targets: [Character]

    /// Та единственная, которая действительно принимает вызов.
    public let answer: Character

    /// Через сколько после появления окна кнопки станут активны.
    public let activationDelay: Interval

    public init(targets: [Character], answer: Character, activationDelay: Interval) {
        self.targets = targets
        self.answer = answer
        self.activationDelay = activationDelay
    }

    /// Собирает задание по политике.
    ///
    /// Генератор снаружи — иначе поведение защиты нельзя проверить тестом, а
    /// непроверяемая защита ничем не отличается от её отсутствия.
    public init(policy: CallGuardPolicy, using generator: inout some RandomNumberGenerator) {
        let policy = policy.normalized

        let delayRange = policy.minimumActivationDelayMilliseconds...policy.maximumActivationDelayMilliseconds
        let milliseconds = delayRange.lowerBound == delayRange.upperBound
            ? delayRange.lowerBound
            : Int.random(in: delayRange, using: &generator)

        // Цифры выбираются без повторов: две одинаковые цели сделали бы
        // задание неразрешимым, а виноватым выглядел бы оператор.
        var pool = Array("123456789")
        var chosen: [Character] = []
        for _ in 0..<policy.targetCount {
            guard !pool.isEmpty else { break }
            chosen.append(pool.remove(at: Int.random(in: 0..<pool.count, using: &generator)))
        }

        self.init(
            targets: chosen,
            answer: chosen[Int.random(in: 0..<chosen.count, using: &generator)],
            activationDelay: .milliseconds(milliseconds)
        )
    }

    /// Задание без задания: одна цель, активная сразу. Так выглядит окно с
    /// выключенной защитой.
    public static let unguarded = CallGuardChallenge(
        targets: ["1"],
        answer: "1",
        activationDelay: .zero
    )

    /// Есть ли из чего выбирать. Одна цель — это не выбор, и говорить
    /// оператору «нажмите 4» в таком случае незачем.
    public var hasChoice: Bool { targets.count > 1 }
}
