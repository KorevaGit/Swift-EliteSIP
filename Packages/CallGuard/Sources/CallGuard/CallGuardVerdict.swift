import CoreGraphics

/// Попытка принять вызов.
public struct CallGuardAttempt: Sendable, Hashable {

    public enum Source: String, Sendable, Hashable, Codable {
        case mouse
        case keyboard

        public var description: String {
            switch self {
            case .mouse: "мышь"
            case .keyboard: "клавиатура"
            }
        }
    }

    public let source: Source

    /// По какой цели нажали. Для клавиатуры — нажатая цифра.
    public let target: Character

    /// Признак программного происхождения события.
    ///
    /// Берётся из `CGEventSourceStateID` и подделывается, поэтому сам по себе
    /// ничего не доказывает. Ценность у него не как у барьера, а как у
    /// показателя: у честного оператора он не встречается никогда.
    public let isSynthetic: Bool

    public let at: ContinuousClock.Instant

    public init(
        source: Source,
        target: Character,
        isSynthetic: Bool = false,
        at: ContinuousClock.Instant
    ) {
        self.source = source
        self.target = target
        self.isSynthetic = isSynthetic
        self.at = at
    }
}

/// Почему попытка не принята.
public enum CallGuardRejection: String, Sendable, Hashable, Codable {
    /// Нажали раньше, чем кнопки стали активны.
    case tooEarly
    /// Нажали не ту цель.
    case wrongTarget
    /// Курсор не двигался: приехал в точку и нажал.
    case noCursorMovement
    /// Событие с признаком программного происхождения.
    case synthetic

    /// Что об этом сказать оператору.
    ///
    /// Формулировки намеренно не объясняют, чего именно не хватило: подсказка
    /// «пройдите курсором 40 точек» — это готовая инструкция для того, кто
    /// подбирает обход.
    public var operatorMessage: String {
        switch self {
        case .tooEarly: "Ещё рано"
        case .wrongTarget: "Не та кнопка"
        case .noCursorMovement: "Подведите курсор к окну"
        case .synthetic: "Нажатие не принято"
        }
    }

    /// Что об этом написать в журнал.
    public var logMessage: String {
        switch self {
        case .tooEarly: "нажатие раньше активации"
        case .wrongTarget: "нажата не та цель"
        case .noCursorMovement: "нажатие без движения курсора"
        case .synthetic: "нажатие с признаком синтетического события"
        }
    }

    /// Стоит ли считать это признаком автоматизации, а не промахом человека.
    ///
    /// Не та кнопка — обычная человеческая ошибка. Остальные три без участия
    /// программы не получаются.
    public var suggestsAutomation: Bool {
        self != .wrongTarget
    }
}

public enum CallGuardVerdict: Sendable, Hashable {
    case accepted
    case rejected(CallGuardRejection)

    public var isAccepted: Bool {
        if case .accepted = self { true } else { false }
    }

    public var rejection: CallGuardRejection? {
        if case .rejected(let reason) = self { reason } else { nil }
    }
}

/// Что защита увидела за один входящий вызов.
///
/// Это и есть слой 3 из документа в зачаточном виде: на клиенте по одному
/// звонку решить ничего нельзя, а на нескольких сотнях время реакции 210 ± 5 мс
/// при нулевом пути курсора видно сразу. В M8 уезжает в EliteDash.
public struct CallGuardReport: Codable, Sendable, Hashable {

    public var wasGuardEnabled: Bool
    /// Выпавшая задержка активации, мс.
    public var activationDelayMilliseconds: Int
    /// Сколько прошло от появления окна до принятого нажатия, мс.
    public var reactionMilliseconds: Int?
    /// Длина пути курсора внутри окна, в точках.
    public var cursorTravel: Double
    /// Сколько отдельных перемещений курсора зафиксировано.
    public var cursorSamples: Int
    /// Чем подтверждён приём.
    public var confirmedBy: CallGuardAttempt.Source?
    /// Отклонённые попытки по причинам.
    public var rejections: [CallGuardRejection: Int]

    public init(
        wasGuardEnabled: Bool = true,
        activationDelayMilliseconds: Int = 0,
        reactionMilliseconds: Int? = nil,
        cursorTravel: Double = 0,
        cursorSamples: Int = 0,
        confirmedBy: CallGuardAttempt.Source? = nil,
        rejections: [CallGuardRejection: Int] = [:]
    ) {
        self.wasGuardEnabled = wasGuardEnabled
        self.activationDelayMilliseconds = activationDelayMilliseconds
        self.reactionMilliseconds = reactionMilliseconds
        self.cursorTravel = cursorTravel
        self.cursorSamples = cursorSamples
        self.confirmedBy = confirmedBy
        self.rejections = rejections
    }

    /// Сколько раз защита сработала.
    public var rejectedAttempts: Int { rejections.values.reduce(0, +) }

    /// Есть ли в этом звонке хоть что-то, похожее на автоматизацию.
    public var looksAutomated: Bool {
        rejections.contains { $0.key.suggestsAutomation && $0.value > 0 }
    }

    /// Строка для журнала. Короткая: в панели диагностики места мало, а
    /// подробности всё равно уедут в EliteDash целиком.
    public var summary: String {
        guard wasGuardEnabled else { return "защита выключена" }

        var parts = ["задержка \(activationDelayMilliseconds) мс"]
        if let reactionMilliseconds {
            parts.append("реакция \(reactionMilliseconds) мс")
        }
        parts.append(String(format: "курсор %.0f pt за %d движ.", cursorTravel, cursorSamples))
        if let confirmedBy {
            parts.append("подтверждено: \(confirmedBy.description)")
        }
        if rejectedAttempts > 0 {
            let detail = rejections
                .filter { $0.value > 0 }
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.logMessage) ×\($0.value)" }
                .joined(separator: ", ")
            parts.append("отклонено \(rejectedAttempts) (\(detail))")
        }
        return parts.joined(separator: ", ")
    }
}
