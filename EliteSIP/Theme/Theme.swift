import SwiftUI

/// Единственное место, где заданы размеры, радиусы и цвета.
///
/// Причина, по которой это отдельный слой, а не литералы по месту: приложение
/// живёт на macOS 14–26, и Liquid Glass есть только на 26. Разница должна быть
/// изолирована здесь, чтобы во вьюхах не было ни одного `#available`.
enum Theme {

    /// Вертикальные промежутки между ярусами панели.
    ///
    /// Заданы поимённо, а не общим шагом: расстояния здесь неравные по смыслу.
    /// Поле набора и ряд управления — соседи одного действия, поэтому между ними
    /// почти ничего; управление и макросы — разные классы, и разделяет их только
    /// воздух, без линии.
    enum Gap {
        /// Строка состояния → поле ввода.
        static let statusToHeader: CGFloat = 5
        /// Поле ввода → ряд управления.
        static let headerToControls: CGFloat = 5
        /// Ряд управления → макросы.
        static let controlsToMacros: CGFloat = 15
        /// Макросы → кнопка завершения.
        static let macrosToAction: CGFloat = 15
    }

    enum Metrics {
        /// Панель узкая и фиксированной ширины — это софтфон, а не окно почты.
        ///
        /// Габариты сознательно поджаты: окно висит поверх CRM весь рабочий
        /// день, и каждая лишняя точка ширины отъедает место у того, с чем
        /// оператор реально работает. Дайлпада, ради которого держались 280,
        /// больше нет; 270 — компромисс: подписи макросов в три колонки
        /// перестают ужиматься до нечитаемого, а окно всё равно уже прежнего.
        static let panelWidth: CGFloat = 270

        /// Высота, с которой окно панели создаётся.
        ///
        /// Компактного вида больше нет: без макросов панель и так компактна, а
        /// два размера требовали переключателя, который занимал место ради
        /// состояния, в которое почти не переходят.
        ///
        /// Настоящую высоту панель считает сама из числа макросов и того,
        /// свёрнута ли она, и ставит окну через `PanelHeight`. Здесь нужно
        /// какое-то значение до первого прохода раскладки — иначе окно
        /// мигнёт размером содержимого `NSHostingController`.
        static let panelInitialHeight: CGFloat = 250

        /// Строка состояния наверху: светофор окна, номер, состояние клиента,
        /// настройки и переключатель размера.
        ///
        /// Высота равна полосе заголовка macOS: строка идёт по одной линии с
        /// кнопками окна, а не под ними. Двух рядов управления окном друг над
        /// другом быть не должно — светофор в собственной полосе как раз это и
        /// создавал.
        static let statusBarHeight: CGFloat = 28

        /// Поправка строки состояния по вертикали.
        ///
        /// Кнопки окна центрируются не по середине полосы заголовка, а на 2
        /// точки ниже — это измерено на живом окне, а не выведено из HIG.
        /// Без поправки номер и шестерёнка стоят выше светофора, и ряд
        /// читается как две строки вместо одной.
        static let statusBarTopInset: CGFloat = 2

        /// Сторона квадрата подсветки под курсором у кнопок строки состояния.
        ///
        /// Меньше высоты строки: подсветка во всю высоту упиралась в край окна
        /// сверху и выглядела полосой, а не кнопкой.
        static let statusIconHitSize: CGFloat = 22

        /// Отступ строки состояния слева — место под светофор.
        ///
        /// Кнопки окна ставит AppKit по своим координатам от края окна, а не от
        /// края содержимого, поэтому отступ считается от края окна (70) минус
        /// поле панели (12).
        static let trafficLightsInset: CGFloat = 68

        /// Высота шапки — одна на все состояния панели.
        ///
        ///
        /// Поле набора в покое и карточка собеседника в разговоре занимают
        /// ровно столько же: иначе при ответе на вызов шапка вырастала бы и
        /// сдвигала вниз всё, что под ней. При двух линиях этот же слот делится
        /// на два поля по 22 точки.
        static let headerHeight: CGFloat = 52

        /// Неподвижная нижняя зона: кнопка звонка и история.
        static let actionHeight: CGFloat = 46
        /// Ширина «Истории». Задана явно, чтобы кнопка звонка занимала всё
        /// оставшееся место и не меняла ширину от длины подписи.
        static let historyWidth: CGFloat = 64

        /// Ряд управления: удержание, микрофон, перевод. Ниже клавиш макросов и
        /// с подписью в строку, а не столбиком, — так ряд читается как другой
        /// класс элементов, а не как первый ряд сетки.
        static let controlHeight: CGFloat = 32

        /// Ниже этого клавиша макроса не сжимается. Верхнего предела нет: сетка
        /// забирает всю свободную вертикаль, иначе между ней и кнопкой
        /// завершения оставался бы провал, который нечем занять.
        static let macroMinHeight: CGFloat = 58
        /// Три в ряд: подпись макроса задаёт оператор, предсказать её ширину
        /// нельзя, но три коротких кнопки в 250 точек влезают всегда.
        static let macroColumns = 3

        /// Ширина окна входящего. Высота не задаётся — окно подгоняется под
        /// содержимое.
        ///
        /// Фиксированная высота здесь уже стоила бага: в макете два состояния,
        /// 186 и 244 точки, но зафиксировать их значит получить пустую полосу
        /// между именем звонящего и кнопками всякий раз, когда содержимого
        /// меньше расчётного — например когда сервер не прислал имя.
        static let incomingCallPanelWidth: CGFloat = 320

        static let contentPadding: CGFloat = 12
        static let sectionSpacing: CGFloat = 8
        static let elementSpacing: CGFloat = 6
    }

    enum Radius {
        /// Радиусы после редизайна: 12 и 8 вместо прежних 16 и 10.
        ///
        /// Панель стала уже и ниже, и прежние скругления на клавише в 54 точки
        /// читались как капсула. Значения те же, что в макете.
        static let surface: CGFloat = 12
        static let control: CGFloat = 8
    }

    /// Начертания из макета.
    ///
    /// Заданы размером, а не именованным стилем (`.caption`, `.body`): окно
    /// входящего фиксированной ширины и висит поверх чужого интерфейса, а
    /// Dynamic Type на крупной настройке растянул бы его в половину экрана.
    /// Для остальных экранов по-прежнему используются системные стили.
    enum Text {
        /// Подпись «Входящий вызов».
        static let incomingCaption = Font.system(size: 11)
        /// Номер звонящего.
        static let incomingNumber = Font.system(size: 24, weight: .medium, design: .rounded)
        /// Имя звонящего и указание под ним.
        static let incomingDetail = Font.system(size: 13)
        /// Цифра, которую надо нажать, — в тексте указания.
        static let incomingTarget = Font.system(size: 15)
        /// Цифра на кнопке-цели и на клавише набора.
        static let controlKey = Font.system(size: 20, design: .rounded)
        /// Надпись на кнопке.
        static let controlLabel = Font.system(size: 13, weight: .medium)
        /// Состояние регистрации в бейдже панели.
        static let panelStatus = Font.system(size: 13)
        /// Вторая строка бейджа — срок регистрации или время повтора.
        static let panelDetail = Font.system(size: 10)

        /// Номер в поле набора: пока номер набирают, он и есть главное.
        static let dialedNumber = Font.system(size: 18, weight: .light, design: .rounded)
        /// Имя собеседника в разговоре — крупно. Оператор работает с человеком,
        /// а не с цифрами: имя читается, номер только сверяется.
        static let callerName = Font.system(size: 17, weight: .medium)
        /// Номер собеседника под именем — мелко и вторым планом.
        static let callerNumber = Font.system(size: 11, design: .rounded)
        /// Длительность разговора.
        static let callTimer = Font.system(size: 11, weight: .medium, design: .rounded)
        /// Номер, под которым зарегистрирован менеджер.
        static let statusNumber = Font.system(size: 11, weight: .semibold)
        /// Мелкий текст строки состояния и подписей управления.
        ///
        /// 11, а не 10: на 10 пунктах состояние клиента в светлой теме
        /// переставало читаться совсем — светло-серое по светлому.
        static let statusDetail = Font.system(size: 11)
        /// Собеседник в поле линии, когда линий две.
        static let lineTitle = Font.system(size: 12, weight: .medium)
        /// Подпись макроса — крупно, это главная цель для мыши в разговоре.
        static let macro = Font.system(size: 15, weight: .medium)
    }

    enum Palette {
        static let answer = Color.green
        static let decline = Color.red
        static let registered = Color.green
        static let connecting = Color.orange
        static let offline = Color.secondary
        static let failure = Color.red

        /// Уровни текста заданы прозрачностью от `.primary`, а не системными
        /// `.secondary` и `.tertiary`.
        ///
        /// Системные уровни рассчитаны на непрозрачный фон окна. На материале
        /// они теряют ещё часть контраста, и в светлой теме первым исчезает
        /// мелкий текст состояния. Здесь уровни заданы явно и одинаково
        /// работают в обеих темах. Иерархический `.tertiary` вдобавок появился
        /// только в macOS 12, а `Color.tertiary` не существует вовсе.
        static let textSecondary = Color.primary.opacity(0.70)
        static let tertiary = Color.primary.opacity(0.50)
    }
}

/// Наложение поверх содержимого, а не замена фона: под ним может быть и
/// материал, и сплошная заливка, и подсветка должна работать одинаково.
private struct HoverHighlight: ViewModifier {

    let cornerRadius: CGFloat
    let isEnabled: Bool

    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .compatOverlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.primary.opacity(isHovered && isEnabled ? 0.12 : 0))
                    // Наложение обязано быть прозрачным для мыши, иначе оно же
                    // и съест нажатие, ради которого рисовалось.
                    .allowsHitTesting(false)
            }
            .onHover { isHovered = $0 }
            .compatAnimation(.easeOut(duration: 0.12), value: isHovered)
    }
}

extension View {

    /// Основная поверхность: стекло на macOS 26, материал ниже.
    ///
    /// Три ступени, а не две: `Material` из SwiftUI появился только в macOS 12,
    /// поэтому на Catalina и Big Sur тот же системный эффект берётся напрямую у
    /// AppKit. Плоской заливки нет ни на одной ступени.
    @ViewBuilder
    func themedSurface(cornerRadius: CGFloat = Theme.Radius.surface) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else if #available(macOS 12.0, *) {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            self.background(
                CompatMaterial(material: .hudWindow, cornerRadius: cornerRadius)
            )
        }
    }

    /// Фон окна панели — системный, и по цвету, и по стилю.
    ///
    /// Своя подкраска здесь была ошибкой: она делала панель почти чёрной в
    /// тёмной теме, то есть темнее любого окна macOS рядом. Системный фон окна
    /// даёт ту же светлоту, что у остальных окон, следует за темой сам и
    /// работает от Catalina до Tahoe.
    func themedPanelSurface(cornerRadius: CGFloat = Theme.Radius.surface) -> some View {
        compatBackground {
            CompatMaterial(material: .windowBackground, cornerRadius: cornerRadius)
        }
    }

    /// Подсветка при наведении курсора.
    ///
    /// Нужна всем кнопкам со стилем `.plain`: он рисует только содержимое и
    /// никакой реакции на курсор не даёт. Для окна входящего это не косметика —
    /// оператор должен видеть, что попал в цель, до того как нажмёт, иначе
    /// промах по цифре выглядит как неработающая кнопка.
    ///
    /// Цвет берётся от `.primary`: в тёмной теме это белый и подсвечивает, в
    /// светлой — чёрный и притемняет. То есть верно в обеих.
    func hoverHighlight(
        cornerRadius: CGFloat = Theme.Radius.control,
        isEnabled: Bool = true
    ) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius, isEnabled: isEnabled))
    }

    /// Поверхность управляющего элемента — слабый слой поверх фона панели.
    ///
    /// Несимметрична по темам намеренно: на тёмном фоне светлая плашка заметна
    /// при 0.09, на светлом тёмная — только начиная с 0.06. Симметричное
    /// значение в одной из тем всегда сливалось с панелью.
    func themedControlSurface(cornerRadius: CGFloat = Theme.Radius.control) -> some View {
        modifier(ControlSurface(cornerRadius: cornerRadius))
    }
}

private struct ControlSurface: ViewModifier {

    let cornerRadius: CGFloat

    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.compatBackground {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(scheme == .dark
                      ? Color.white.opacity(0.09)
                      : Color.black.opacity(0.06))
        }
    }
}
