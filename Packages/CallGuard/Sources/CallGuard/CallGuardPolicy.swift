import Foundation

/// Настройки защиты приёма вызова.
///
/// Codable потому, что то же самое лежит в файле настроек и в M8 приедет из
/// EliteDash. Значения по умолчанию соответствуют разобранным в
/// `docs/anti-autoclicker.md` мерам; менять их можно, но каждое послабление
/// стоит одного пункта модели угроз.
public struct CallGuardPolicy: Codable, Sendable, Hashable {

    /// Общий выключатель.
    ///
    /// Выключить защиту можно, скрыть факт выключения — нет: он пишется в
    /// журнал, а в M8 уедет в EliteDash. Пока это единственный работающий
    /// вариант из трёх разобранных в документе.
    public var isEnabled: Bool

    /// Управляется ли значение сервером.
    ///
    /// Место под вариант 1 из документа: значение приезжает из EliteDash и
    /// локально только читается. Пока всегда false, но интерфейс уже умеет
    /// показывать переключатель неактивным.
    public var isServerManaged: Bool

    // MARK: - Слой 1: случайность

    public var isRandomPositionEnabled: Bool
    /// Минимальное смещение окна от прошлой позиции, в точках.
    public var minimumTravel: Double
    /// Отступ от краёв рабочей области, в точках.
    public var screenMargin: Double

    // Случайной задержки активации здесь больше нет, и это решение, а не
    // потеря. В первой реализации кнопки активировались через 300–1500 мс,
    // но цену платил оператор на каждом вызове, а кликер эту задержку просто
    // пережидает. Подозрительно ровное время реакции ловится статистикой
    // EliteDash, для чего в отчёте и лежит `reactionMilliseconds`. Ключи из
    // старого файла настроек молча игнорируются: `CodingKeys` их больше не
    // знает, а значит вернуть задержку файлом нельзя.

    /// Сколько кнопок-целей показывать. Единица означает обычную кнопку
    /// «Ответить» без выбора.
    ///
    /// По умолчанию именно единица. Основная мера — случайная позиция окна: она
    /// ломает кликер по координатам и при этом ничего не стоит оператору.
    /// Цифровое подтверждение стоит внимания на каждом вызове, поэтому
    /// включается отдельно и осознанно — против кликера по шаблону изображения,
    /// когда такой появится.
    public var targetCount: Int

    // MARK: - Слой 2: признаки живого человека

    /// Требовать движения курсора перед приёмом вызова.
    public var requiresCursorMovement: Bool
    /// Сколько точек курсор должен пройти. Телепорт в точку даёт ноль.
    public var requiredCursorTravel: Double
    /// Сколько отдельных перемещений должно случиться. Одно — это прыжок.
    public var requiredCursorSamples: Int

    /// Отклонять нажатия с признаком программного происхождения.
    ///
    /// Признак подделывается, поэтому по умолчанию он не барьер, а сигнал в
    /// телеметрию: включённое отклонение ловит простые кликеры, но честного
    /// оператора со средствами доступности может задеть.
    public var rejectsSyntheticEvents: Bool

    public init(
        isEnabled: Bool = true,
        isServerManaged: Bool = false,
        isRandomPositionEnabled: Bool = true,
        minimumTravel: Double = 150,
        screenMargin: Double = 24,
        targetCount: Int = 1,
        requiresCursorMovement: Bool = true,
        requiredCursorTravel: Double = 40,
        requiredCursorSamples: Int = 3,
        rejectsSyntheticEvents: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.isServerManaged = isServerManaged
        self.isRandomPositionEnabled = isRandomPositionEnabled
        self.minimumTravel = minimumTravel
        self.screenMargin = screenMargin
        self.targetCount = targetCount
        self.requiresCursorMovement = requiresCursorMovement
        self.requiredCursorTravel = requiredCursorTravel
        self.requiredCursorSamples = requiredCursorSamples
        self.rejectsSyntheticEvents = rejectsSyntheticEvents
    }

    /// Разбор терпим к отсутствующим полям: файл настроек переживает выпуски,
    /// в которых появились новые ограничения.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = CallGuardPolicy()

        func value<T: Decodable>(_ key: CodingKeys, _ default: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? `default`
        }

        isEnabled = try value(.isEnabled, fallback.isEnabled)
        isServerManaged = try value(.isServerManaged, fallback.isServerManaged)
        isRandomPositionEnabled = try value(.isRandomPositionEnabled, fallback.isRandomPositionEnabled)
        minimumTravel = try value(.minimumTravel, fallback.minimumTravel)
        screenMargin = try value(.screenMargin, fallback.screenMargin)
        targetCount = try value(.targetCount, fallback.targetCount)
        requiresCursorMovement = try value(.requiresCursorMovement, fallback.requiresCursorMovement)
        requiredCursorTravel = try value(.requiredCursorTravel, fallback.requiredCursorTravel)
        requiredCursorSamples = try value(.requiredCursorSamples, fallback.requiredCursorSamples)
        rejectsSyntheticEvents = try value(.rejectsSyntheticEvents, fallback.rejectsSyntheticEvents)
    }

    /// Приведение к работоспособному виду.
    ///
    /// Нужно, потому что настройки редактируются снаружи: ноль целей или
    /// отрицательный путь курсора выключили бы защиту молча, а молчаливо
    /// выключенная защита хуже честно выключенной.
    public var normalized: CallGuardPolicy {
        var copy = self
        copy.targetCount = min(max(1, targetCount), CallGuardChallenge.maximumTargets)
        copy.requiredCursorTravel = max(0, requiredCursorTravel)
        copy.requiredCursorSamples = max(0, requiredCursorSamples)
        copy.minimumTravel = max(0, minimumTravel)
        copy.screenMargin = max(0, screenMargin)
        return copy
    }

    /// Защита, выключенная целиком. Окно ведёт себя как обычное: одна кнопка
    /// в середине экрана, курсор ничего не должен.
    public static let disabled = CallGuardPolicy(
        isEnabled: false,
        isRandomPositionEnabled: false,
        targetCount: 1,
        requiresCursorMovement: false,
        requiredCursorTravel: 0,
        requiredCursorSamples: 0,
        rejectsSyntheticEvents: false
    )
}
