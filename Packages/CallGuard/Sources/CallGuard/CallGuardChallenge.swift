import Foundation

/// Что окно должно показать, чтобы приём вызова требовал человека.
///
/// Собирается один раз на звонок и больше не меняется: перерисовка целей под
/// уже потянувшейся рукой оператора — это не защита, а издевательство.
public struct CallGuardChallenge: Sendable, Hashable {

    /// Больше девяти целей не бывает: ряд из десятка одинаковых кнопок
    /// перестаёт читаться, а ноль среди цифр виден хуже остальных.
    public static let maximumTargets = 9

    /// Цифры на кнопках, слева направо.
    public let targets: [Character]

    /// Та единственная, которая действительно принимает вызов.
    public let answer: Character

    public init(targets: [Character], answer: Character) {
        self.targets = targets
        self.answer = answer
    }

    /// Собирает задание по политике.
    ///
    /// Генератор снаружи — иначе поведение защиты нельзя проверить тестом, а
    /// непроверяемая защита ничем не отличается от её отсутствия.
    public init(policy: CallGuardPolicy, using generator: inout some RandomNumberGenerator) {
        let policy = policy.normalized

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
            answer: chosen[Int.random(in: 0..<chosen.count, using: &generator)]
        )
    }

    /// Задание без задания: одна цель. Так выглядит окно с выключенной защитой.
    public static let unguarded = CallGuardChallenge(targets: ["1"], answer: "1")

    /// Есть ли из чего выбирать. Одна цель — это не выбор, и говорить
    /// оператору «нажмите 4» в таком случае незачем.
    public var hasChoice: Bool { targets.count > 1 }
}
