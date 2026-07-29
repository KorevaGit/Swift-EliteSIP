import Compat
import CoreGraphics

/// Защита одного входящего вызова: от появления окна до решения оператора.
///
/// Время не берётся изнутри, а приходит с каждым событием. Из-за этого весь
/// разбор — чистая функция от последовательности событий, и «нажал через 210 мс
/// без движения курсора» проверяется тестом, а не секундомером и мышью.
public struct CallGuardSession: Sendable {

    public let policy: CallGuardPolicy
    public let challenge: CallGuardChallenge

    /// Когда появилось окно. От этого момента считается всё остальное.
    public let presentedAt: MonotonicClock.Instant

    private(set) public var report: CallGuardReport

    /// Последняя известная позиция курсора. Первое событие пути не даёт: одна
    /// точка — это ещё не движение.
    private var lastCursorPoint: CGPoint?

    public init(
        policy: CallGuardPolicy,
        presentedAt: MonotonicClock.Instant,
        using generator: inout some RandomNumberGenerator
    ) {
        let policy = policy.normalized
        self.policy = policy
        self.presentedAt = presentedAt
        self.challenge = policy.isEnabled
            ? CallGuardChallenge(policy: policy, using: &generator)
            : .unguarded
        self.report = CallGuardReport(
            wasGuardEnabled: policy.isEnabled,
            activationDelayMilliseconds: challenge.activationDelay.wholeMilliseconds
        )
    }

    /// Момент, начиная с которого нажатие принимается.
    public var activatesAt: MonotonicClock.Instant {
        presentedAt + challenge.activationDelay
    }

    public func isActive(at now: MonotonicClock.Instant) -> Bool {
        now >= activatesAt
    }

    // MARK: - Курсор

    /// Отмечает перемещение курсора внутри окна.
    ///
    /// Считается именно путь, а не факт наличия координаты: `CGEvent.post`
    /// ставит курсор в точку одним событием, и путь у такого «движения» равен
    /// нулю. Честная рука за то же время проходит десятки точек.
    public mutating func noteCursor(at point: CGPoint) {
        defer { lastCursorPoint = point }
        guard let previous = lastCursorPoint else { return }

        let dx = point.x - previous.x
        let dy = point.y - previous.y
        let step = (dx * dx + dy * dy).squareRoot()
        guard step > 0 else { return }

        report.cursorTravel += step
        report.cursorSamples += 1
    }

    /// Достаточно ли курсор двигался.
    public var hasEnoughCursorMovement: Bool {
        guard policy.isEnabled, policy.requiresCursorMovement else { return true }
        return report.cursorTravel >= policy.requiredCursorTravel
            && report.cursorSamples >= policy.requiredCursorSamples
    }

    // MARK: - Решение

    /// Разбирает попытку принять вызов.
    ///
    /// Порядок проверок не случаен и идёт от самого дешёвого обхода к самому
    /// дорогому: сначала то, что ломает скрипт «жать сразу», потом поиск по
    /// шаблону, потом отсутствие живой руки. Так в телеметрии видно, на каком
    /// именно слое остановился нарушитель.
    public mutating func evaluate(attempt: CallGuardAttempt) -> CallGuardVerdict {
        guard policy.isEnabled else {
            accept(attempt)
            return .accepted
        }

        if attempt.at < activatesAt {
            return reject(.tooEarly)
        }

        if challenge.hasChoice, attempt.target != challenge.answer {
            return reject(.wrongTarget)
        }

        if policy.rejectsSyntheticEvents, attempt.isSynthetic {
            return reject(.synthetic)
        }

        // Клавиатура от движения курсора освобождена: оператор, работающий с
        // клавиатуры, мышь не трогает вовсе, и требовать от него ещё и
        // потянуться к ней — значит наказывать за правильную привычку.
        if attempt.source == .mouse, !hasEnoughCursorMovement {
            return reject(.noCursorMovement)
        }

        // Синтетическое нажатие, которое мы решили не отклонять, всё равно
        // должно оказаться в отчёте: иначе слой обнаружения из документа
        // останется без данных, ради которых он и задуман.
        if attempt.isSynthetic {
            report.rejections[.synthetic, default: 0] += 1
        }

        accept(attempt)
        return .accepted
    }

    private mutating func accept(_ attempt: CallGuardAttempt) {
        report.confirmedBy = attempt.source
        report.reactionMilliseconds = (attempt.at - presentedAt).wholeMilliseconds
    }

    private mutating func reject(_ reason: CallGuardRejection) -> CallGuardVerdict {
        report.rejections[reason, default: 0] += 1
        return .rejected(reason)
    }
}
