import AppKit
import SwiftUI

/// Предлагаемый набор токенов панели.
///
/// Это будущее содержимое `Theme` в приложении: сейчас размеры и начертания там
/// заданы поштучно под каждый экран, из-за чего рядом в одном окне оказываются
/// четыре разных радиуса и три разных веса подписи. Здесь они сведены в шкалы —
/// шаг отступа, два радиуса, семь начертаний.
enum Tokens {

    /// Шаг сетки. Всё, что отступает, отступает одним из этих значений.
    enum Space {
        static let hair: CGFloat = 2
        static let tight: CGFloat = 6
        static let base: CGFloat = 8
        static let wide: CGFloat = 12
    }

    /// Вертикальные промежутки между ярусами панели.
    ///
    /// Заданы поимённо, а не общим шагом: расстояния здесь неравные по смыслу.
    /// Поле набора и УМП — соседи одного действия, поэтому между ними почти
    /// ничего; УМП и макросы — разные классы, и разделяет их только воздух,
    /// без линии; до кнопки завершения промежуток минимальный, чтобы низ не
    /// висел в пустоте.
    enum Gap {
        /// Поле набора → УМП.
        static let headerToControls: CGFloat = 5

        /// УМП → макросы.
        static let controlsToMacros: CGFloat = 15

        /// Строка состояния → поле ввода.
        static let statusToHeader: CGFloat = 5

        /// Макросы → кнопка завершения.
        static let macrosToAction: CGFloat = 15

        /// Полоса заголовка → строка состояния.
        ///
        /// Меньше остальных: список профилей относится к заголовку — это тот же
        /// вопрос «что это за окно», только с ответом «и под каким номером».
        /// Между ними воздуха ровно столько, чтобы точки светофора не касались
        /// капсулы списка.
        static let titleToStatus: CGFloat = 4
    }

    enum Radius {
        /// Само окно панели и крупные поверхности внутри.
        static let surface: CGFloat = 12
        /// Всё нажимаемое.
        static let control: CGFloat = 8
        /// Капсула списка профилей. Скруглена сильнее всего остального
        /// намеренно: так она читается как переключатель состояния, а не как
        /// ещё одна кнопка панели.
        static let pill: CGFloat = 11
    }

    enum Metrics {
        /// Ширина панели. 270 — то, что стоит в приложении: прототип обсуждает
        /// правку головы, и менять под неё ещё и ширину значит сравнивать два
        /// разных окна.
        static let panelWidth: CGFloat = 270

        /// Две высоты панели. Внутри каждой высота жёсткая: окно не дышит от
        /// того, что появилась вторая линия или полоса сбоя.
        ///
        /// Полная подобрана так, чтобы девять макросов получили высоту клавиши
        /// не меньше 44 точек, а компактная — чтобы вместить только шапку и
        /// неподвижный низ.
        static let panelHeightCompact: CGFloat = 150

        /// Высота шапки — одна на все состояния.
        ///
        /// Задана по самому высокому содержимому (номер, имя, таймер с
        /// состоянием), и в покое поле набора занимает ровно столько же. Иначе
        /// при ответе на вызов шапка вырастала бы на 16 точек и сдвигала вниз
        /// всё, что под ней, — а компактный вид, где шапка одна, оставался бы
        /// неподвижным. Разное поведение одного и того же элемента в двух видах
        /// панели и есть то, что читается как «прыгает».
        /// Шапка во всю ширину панели, но низкая.
        ///
        /// Поле набора весило в окне больше всего, хотя набор — не главное
        /// действие: почти все звонки входящие. Вес снят высотой, а не шириной:
        /// в разговоре сюда влезают две строки — имя крупно, а под ним номер,
        /// таймер и состояние одной мелкой строкой.
        static let headerHeight: CGFloat = 48

        /// Неподвижная нижняя зона: кнопка звонка и история.
        static let actionHeight: CGFloat = 44
        /// Ширина «Истории» в нижней полосе. Задана явно, чтобы кнопка звонка
        /// занимала всё оставшееся место и не меняла ширину от длины подписи.
        static let historyWidth: CGFloat = 64

        /// Кнопки разговора: удержание, микрофон, перевод. Ниже клавиш макросов
        /// и с подписью в строку, а не столбиком, — так ряд управления читается
        /// как другой класс элементов, а не как первый ряд сетки.
        static let controlHeight: CGFloat = 30
        /// Ниже этого клавиша макроса не сжимается. Верхнего предела нет: сетка
        /// забирает всю свободную вертикаль, иначе между ней и кнопкой
        /// завершения оставался бы провал, который нечем занять.
        static let macroMinHeight: CGFloat = 54
        /// Три в ряд: подпись задаёт оператор, и предсказать её ширину нельзя,
        /// а три коротких кнопки в 280 точек влезают всегда.
        static let macroColumns = 3

        /// Строка состояния наверху: список профилей, беда, настройки.
        ///
        /// 22, а не прежние 20: в строке теперь стоит капсула с точкой и
        /// шевроном, и на 20 точках она прижимается к тексту вплотную.
        static let statusBarHeight: CGFloat = 22

        /// Полоса заголовка: светофор и название.
        ///
        /// 28 — системная высота полосы у окна с обычным заголовком. Своя
        /// величина здесь была бы ошибкой: в приложении полосу рисует не
        /// вёрстка, а само окно, и подогнать под неё придётся всё остальное.
        static let titleBarHeight: CGFloat = 28

        /// Светофор: три точки по 12 с шагом 8, первая в 20 точках от края.
        /// Числа системные, повторены здесь только ради макета — в приложении
        /// кнопки рисует окно.
        static let trafficLightDiameter: CGFloat = 12
        static let trafficLightSpacing: CGFloat = 8
        static let trafficLightInset: CGFloat = 20

        /// Капсула списка профилей: точка, номер, шеврон.
        static let profilePickerHeight: CGFloat = 22
        /// Диаметр точки состояния в капсуле. 8, а не прежние 6: точка
        /// осталась единственным, чем показано обычное состояние, и на 6
        /// точках цвет читается хуже, чем должен.
        static let statusDotDiameter: CGFloat = 8
    }

    /// Начертания заданы размером, а не именованным стилем: панель фиксированной
    /// ширины и висит поверх чужого интерфейса, а Dynamic Type на крупной
    /// настройке растянул бы её в половину экрана.
    enum Text {
        /// Номер в поле набора: пока номер набирают, он и есть главное.
        static let number = Font.system(size: 18, weight: .light, design: .rounded)
        /// Имя собеседника в разговоре — крупно. В разговоре оператор работает
        /// с человеком, а не с цифрами: имя читается, номер только сверяется.
        static let name = Font.system(size: 17, weight: .medium)
        /// Номер собеседника под именем — мелко и вторым планом.
        static let callerNumber = Font.system(size: 11, design: .rounded)
        /// Таймер разговора.
        static let timer = Font.system(size: 11, weight: .medium, design: .rounded)
        /// Подписи второго плана.
        static let caption = Font.system(size: 11)
        /// Мелкий текст строки состояния и подписей УМП.
        ///
        /// 11, а не 10: на 10 пунктах «на линии» в светлой теме переставало
        /// читаться совсем — светло-серое по светлому.
        static let strip = Font.system(size: 11)
        /// Номер, под которым зарегистрирован менеджер.
        ///
        /// 12, а не 11: он переехал в кнопку списка и стал целью для мыши, а не
        /// подписью. 13 системного заголовка при этом не берём — номер не
        /// должен спорить с названием окна строкой выше.
        static let statusNumber = Font.system(size: 12, weight: .semibold)
        /// Название приложения в полосе заголовка. Системная величина заголовка
        /// окна: полосу в приложении рисует окно, и наш кегль обязан совпасть с
        /// его собственным.
        static let title = Font.system(size: 13, weight: .semibold)
        /// Собеседник в поле линии, когда линий две: имя то же, что и в шапке,
        /// но строка вдвое ниже, и начертание приходится ужать.
        static let lineTitle = Font.system(size: 12, weight: .medium)
        /// Подпись макроса — крупно, это главная цель для мыши в разговоре.
        static let macro = Font.system(size: 15, weight: .medium)
        /// Подпись кнопки управления и кнопки звонка.
        static let control = Font.system(size: 13, weight: .medium)
    }

    enum Palette {
        static let answer = Color.green
        static let decline = Color.red
        static let warning = Color.orange
        static let failure = Color.red

        /// Три уровня текста, заданные цветом, а не прозрачностью от `.primary`.
        ///
        /// Системные `.secondary` и `.tertiary` живут с прозрачностью около
        /// половины и рассчитаны на непрозрачный фон окна. На подкрашенном
        /// материале они теряют ещё часть контраста и в светлой теме перестают
        /// читаться первыми.
        ///
        /// В светлой теме основной текст чёрный, и это решение о контрасте, а
        /// не о вкусе: прозрачная панель сама по себе светлее не становится, а
        /// вот фон под ней бывает любым, и запас по контрасту тратится именно
        /// на это. Чёрный даёт около 9.7:1 в худшем случае — вдвое выше нормы,
        /// и текст остаётся читаемым поверх чего угодно.
        ///
        /// Взято сплошным чёрным, а не системным `labelColor` (чёрный на 85 %):
        /// прозрачность поверх прозрачной поверхности перемножается, и
        /// предсказать итог на произвольном фоне нельзя. Здесь цвет один и тот
        /// же всегда.
        ///
        /// В тёмной теме менять было нечего: белый на тёмном таким эффектом не
        /// обладает, и уровни там по-прежнему белый с прозрачностью.
        static func textPrimary(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color.white.opacity(0.92) : Color.black
        }

        /// Второй уровень поставлен ровно на норму — 4.5:1 в худшем случае.
        /// Ниже опускать нельзя: этим цветом набраны таймер и номер
        /// собеседника, а их читают, а не скользят взглядом.
        static func textSecondary(_ scheme: ColorScheme) -> Color {
            scheme == .dark
                ? Color.white.opacity(0.70)
                : Color(red: 0.24, green: 0.26, blue: 0.30)
        }

        /// Третий уровень — подписи, которые читают редко, и точки-разделители.
        /// Ниже нормы контраста он опускаться не должен всё равно: «редко» не
        /// значит «никогда».
        static func textTertiary(_ scheme: ColorScheme) -> Color {
            scheme == .dark
                ? Color.white.opacity(0.50)
                : Color(red: 0.34, green: 0.37, blue: 0.42)
        }
    }
}

extension View {

    /// Основная поверхность панели: материал плюс собственная подкраска.
    ///
    /// Три ступени, как и будет в приложении: Liquid Glass на macOS 26,
    /// `Material` на 12+, `NSVisualEffectView` на Catalina. Ступени не
    /// взаимозаменяемы по виду, и проверять компоновку надо на той, которую
    /// увидит машина оператора, — отсюда переключатель в стенде.
    ///
    /// Подкраска нужна на всех трёх и настраивается: чем её меньше, тем окно
    /// прозрачнее и тем хуже читается мелкий текст поверх пёстрой CRM. Это и
    /// есть та величина, которую в макете подбирают глазами, а потом
    /// закрепляют числом.
    func protoSurface(
        _ radius: CGFloat = Tokens.Radius.surface,
        glass: Tokens.Glass = .material,
        tint: Double = 0.72
    ) -> some View {
        modifier(PanelSurface(cornerRadius: radius, glass: glass, tint: tint))
    }

    /// Поверхность нажимаемого элемента: слабый слой поверх фона панели.
    func protoControlSurface(_ radius: CGFloat = Tokens.Radius.control) -> some View {
        modifier(ControlSurface(cornerRadius: radius))
    }

    func protoHover(radius: CGFloat = Tokens.Radius.control, isEnabled: Bool = true) -> some View {
        modifier(HoverHighlight(cornerRadius: radius, isEnabled: isEnabled))
    }
}

extension Tokens {

    /// Чем сделана поверхность панели.
    ///
    /// Ступень выбирается версией системы, а не вкусом: `glass` есть только на
    /// macOS 26, `material` — с 12, `visualEffect` работает везде начиная с
    /// Catalina. В стенде переключается руками, чтобы одну и ту же компоновку
    /// можно было посмотреть глазами оператора на каждой из трёх машин.
    enum Glass: String, CaseIterable, Identifiable {
        case glass = "Liquid Glass"
        case material = "Материал"
        case visualEffect = "Catalina"

        var id: String { rawValue }
    }
}

private struct PanelSurface: ViewModifier {

    let cornerRadius: CGFloat
    let glass: Tokens.Glass
    let tint: Double

    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.background {
            base
                .overlay {
                    // Подкраска задаёт поверхности собственную светлоту: без
                    // неё материал поверх пёстрой CRM даёт мутно-серый,
                    // одинаково грязный в обеих темах, и мелкий текст по такому
                    // фону не спасают ни кегль, ни цвет. Ноль означает «совсем
                    // без подкраски» и оставляет ровно то, что даёт система.
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(scheme == .dark
                              ? Color.black.opacity(tint * 0.76)
                              : Color.white.opacity(tint))
                }
        }
    }

    @ViewBuilder
    private var base: some View {
        switch glass {
        case .glass:
            if #available(macOS 26.0, *) {
                // `.clear` вместо `.regular`: regular сам подмешивает столько
                // непрозрачности, что просвечивания почти не остаётся, а окно
                // ради него и затевалось.
                Color.clear.glassEffect(.clear, in: .rect(cornerRadius: cornerRadius))
            } else {
                RoundedRectangle(cornerRadius: cornerRadius).fill(.ultraThinMaterial)
            }
        case .material:
            RoundedRectangle(cornerRadius: cornerRadius).fill(.ultraThinMaterial)
        case .visualEffect:
            // То же, что панель получает на Catalina: системный материал через
            // AppKit. `.behindWindow` — ради него всё и делается: `.withinWindow`
            // размывает содержимое своего же окна и на просвет не работает.
            BehindWindowMaterial(cornerRadius: cornerRadius)
        }
    }
}

/// `NSVisualEffectView` с размытием того, что за окном.
///
/// Отдельным типом, а не `Material`: у SwiftUI-материала режим смешивания не
/// настраивается, и просвечивание окна насквозь через него не получить.
struct BehindWindowMaterial: NSViewRepresentable {

    var material: NSVisualEffectView.Material = .hudWindow
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.layer?.cornerRadius = cornerRadius
    }
}

/// Слой контрола поверх подкрашенной панели.
///
/// Несимметричен по темам намеренно: на тёмном фоне светлая плашка заметна при
/// 0.09, на светлом тёмная — только начиная с 0.06, иначе клавиша сливается с
/// панелью.
private struct ControlSurface: ViewModifier {

    let cornerRadius: CGFloat

    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(scheme == .dark
                      ? Color.white.opacity(0.09)
                      : Color.black.opacity(0.06))
        )
    }
}

/// Подсветка при наведении. Кнопкам со стилем `.plain` она нужна всем: сам
/// стиль рисует только содержимое и на курсор не реагирует никак.
private struct HoverHighlight: ViewModifier {

    let cornerRadius: CGFloat
    let isEnabled: Bool

    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    // Цвет от `.primary`: в тёмной теме подсвечивает, в светлой
                    // притемняет. То есть верно в обеих.
                    .fill(Color.primary.opacity(isHovered && isEnabled ? 0.12 : 0))
                    .allowsHitTesting(false)
            }
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}
