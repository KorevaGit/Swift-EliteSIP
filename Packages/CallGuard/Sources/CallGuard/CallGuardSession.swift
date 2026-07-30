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
        self.report = CallGuardReport(wasGuardEnabled: policy.isEnabled)
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
    /// дорогому: сначала поиск по шаблону изображения, потом отсутствие живой
    /// руки. Так в телеметрии видно, на каком именно слое остановился
    /// нарушитель.
    ///
    /// Проверки «нажали слишком рано» здесь больше нет: кнопка активна с первого
    /// кадра, а ровное время реакции — работа статистики в EliteDash, для которой
    /// в отчёте лежит `reactionMilliseconds`. Локальная задержка стоила
    /// оператору внимания на каждом вызове, а кликеру — одной строки ожидания.
    public mutating func evaluate(attempt: CallGuardAttempt) -> CallGuardVerdict {
        guard policy.isEnabled else {
            accept(attempt)
            return .accepted
        }

        if challenge.hasChoice, attempt.target != challenge.answer {
            return reject(.wrongTarget)
        }

        if policy.rejectsSyntheticEvents, attempt.isSynthetic {
            return reject(.synthetic)
        }

        // Единственный путь приёма — мышь, поэтому движение курсора требуется
        // всегда. Клавиатурного пути нет намеренно: он не оставлял защите ни
        // одного признака живого человека — ни пути курсора, ни его отсутствия.
        if !hasEnoughCursorMovement {
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
        report.reactionMilliseconds = (attempt.at - presentedAt).wholeMilliseconds
    }

    private mutating func reject(_ reason: CallGuardRejection) -> CallGuardVerdict {
        report.rejections[reason, default: 0] += 1
        return .rejected(reason)
    }
}
