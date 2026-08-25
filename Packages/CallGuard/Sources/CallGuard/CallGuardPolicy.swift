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
    /// **Выводится из режима машины, а не приезжает полем.** Заведено в M7c как
    /// «место под вариант 1» и до августа 2026 всегда было false; смысл оно
    /// получило с панелью EliteSIP (M9): машина под предустановкой показывает
    /// управляемые ползунки, но не даёт их трогать.
    ///
    /// Полем из файла предустановок оно прийти не может и не должно — это был
    /// бы второй источник одного факта. Ставит его наложение управляемых полей,
    /// один раз на все поля сразу.
    public var isServerManaged: Bool

    // MARK: - Слой 1: случайность

    public var isRandomPositionEnabled: Bool

    /// Правит ли расстояния этого слоя человек.
    ///
    /// **Зачем понадобился отдельный признак.** Ползунок в настройках меняется
    /// от одного движения колёсика над ним — и меняется молча: в отличие от
    /// тумблера, у ползунка нет двух состояний, о которых можно сказать «стало
    /// не так, как было». Администратор, прокручивающий страницу «Входящих»,
    /// уводил смещение с проверенных 150 точек, узнавал об этом никогда, а
    /// платил за это оператор — окно вставало не там, где защита рассчитывала.
    ///
    /// Поэтому расстояния по умолчанию не редактируются вовсе, а показываются:
    /// `false` — «как задумано», и `normalized` возвращает сюда заводские
    /// значения, чем бы ни было записано в файле. Ручной режим включается
    /// отдельным осознанным действием, и с этого момента числа принадлежат
    /// человеку.
    public var tunesRandomnessByHand: Bool

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

    /// Правит ли расстояния этого слоя человек. Довод тот же, что у
    /// `tunesRandomnessByHand`, и цена ошибки здесь выше: заниженный путь
    /// курсора не ломает ничего на глаз, а защиту снимает.
    public var tunesLivenessByHand: Bool

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
        tunesRandomnessByHand: Bool = false,
        minimumTravel: Double = 150,
        screenMargin: Double = 24,
        targetCount: Int = 1,
        requiresCursorMovement: Bool = true,
        tunesLivenessByHand: Bool = false,
        requiredCursorTravel: Double = 40,
        requiredCursorSamples: Int = 3,
        rejectsSyntheticEvents: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.isServerManaged = isServerManaged
        self.isRandomPositionEnabled = isRandomPositionEnabled
        self.tunesRandomnessByHand = tunesRandomnessByHand
        self.minimumTravel = minimumTravel
        self.screenMargin = screenMargin
        self.targetCount = targetCount
        self.requiresCursorMovement = requiresCursorMovement
        self.tunesLivenessByHand = tunesLivenessByHand
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
        tunesRandomnessByHand = try value(.tunesRandomnessByHand, fallback.tunesRandomnessByHand)
        minimumTravel = try value(.minimumTravel, fallback.minimumTravel)
        screenMargin = try value(.screenMargin, fallback.screenMargin)
        targetCount = try value(.targetCount, fallback.targetCount)
        requiresCursorMovement = try value(.requiresCursorMovement, fallback.requiresCursorMovement)
        tunesLivenessByHand = try value(.tunesLivenessByHand, fallback.tunesLivenessByHand)
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
        let factory = CallGuardPolicy()
        var copy = self
        copy.targetCount = min(max(1, targetCount), CallGuardChallenge.maximumTargets)

        // Автоматический слой возвращает заводские расстояния, а не подрезает
        // записанные. Разница видна ровно в том случае, ради которого признак и
        // заведён: файл настроек, в котором смещение однажды сдвинули, на
        // «Авто» больше не действует — иначе «Авто» означало бы «то, что
        // осталось от прошлой правки», а не «как задумано».
        if tunesRandomnessByHand {
            copy.minimumTravel = max(0, minimumTravel)
            copy.screenMargin = max(0, screenMargin)
        } else {
            copy.minimumTravel = factory.minimumTravel
            copy.screenMargin = factory.screenMargin
        }

        if tunesLivenessByHand {
            copy.requiredCursorTravel = max(0, requiredCursorTravel)
            copy.requiredCursorSamples = max(0, requiredCursorSamples)
        } else {
            copy.requiredCursorTravel = factory.requiredCursorTravel
            copy.requiredCursorSamples = factory.requiredCursorSamples
        }
        return copy
    }

    /// Защита, выключенная целиком. Окно ведёт себя как обычное: одна кнопка
    /// в середине экрана, курсор ничего не должен.
    /// `tunesRandomnessByHand`/`tunesLivenessByHand` здесь **включены**, и это
    /// не копипаста: на «Авто» `normalized` вернул бы заводские сорок точек
    /// пути курсора — то есть выключенная защита требовала бы движения мыши.
    public static let disabled = CallGuardPolicy(
        isEnabled: false,
        isRandomPositionEnabled: false,
        tunesRandomnessByHand: true,
        minimumTravel: 0,
        screenMargin: 0,
        targetCount: 1,
        requiresCursorMovement: false,
        tunesLivenessByHand: true,
        requiredCursorTravel: 0,
        requiredCursorSamples: 0,
        rejectsSyntheticEvents: false
    )
}
