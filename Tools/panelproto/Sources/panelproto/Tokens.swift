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
    }

    enum Radius {
        /// Само окно панели и крупные поверхности внутри.
        static let surface: CGFloat = 12
        /// Всё нажимаемое.
        static let control: CGFloat = 8
    }

    enum Metrics {
        /// Панель уже прежней: 250 вместо 280.
        ///
        /// Дайлпада, ради которого держались 280, больше нет, а подпись макроса
        /// в три колонки укладывается и здесь — при 250 на клавишу приходится
        /// 71 точка. Каждая снятая точка ширины возвращается CRM, поверх
        /// которой панель висит весь рабочий день.
        static let panelWidth: CGFloat = 250

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

        /// Строка состояния наверху: номер, состояние клиента, настройки и
        /// переключатель размера.
        static let statusBarHeight: CGFloat = 20
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
        static let statusNumber = Font.system(size: 11, weight: .semibold)
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
        /// Уровни текста заданы прозрачностью от `.primary`, а не системными
        /// `.secondary` и `.tertiary`.
        ///
        /// Системные уровни на macOS живут с прозрачностью около половины и
        /// рассчитаны на непрозрачный фон окна. На подкрашенном материале они
        /// теряют ещё часть контраста и в светлой теме перестают читаться
        /// первыми — что и было видно на «на линии». Здесь уровни заданы явно и
        /// одинаково работают в обеих темах.
        static let textSecondary = Color.primary.opacity(0.70)
        static let tertiary = Color.primary.opacity(0.50)
    }
}

extension View {

    /// Основная поверхность панели: материал плюс собственная подкраска.
    ///
    /// Один материал без подкраски не годится. Он пропускает то, что под окном,
    /// и поверх пёстрой CRM даёт мутно-серый — одинаково грязный в обеих темах.
    /// Серый текст по такому фону не спасают ни кегль, ни прозрачность, потому
    /// что контраст съеден самим фоном. Подкраска задаёт поверхности
    /// собственную светлоту: в светлой теме почти белую, в тёмной почти чёрную,
    /// — а материал остаётся ради живого просвечивания по краям.
    ///
    /// В приложении здесь три ступени: стекло на macOS 26, материал на 12+,
    /// `NSVisualEffectView` на Catalina. Подкраска нужна на всех трёх.
    func protoSurface(_ radius: CGFloat = Tokens.Radius.surface) -> some View {
        modifier(PanelSurface(cornerRadius: radius))
    }

    /// Поверхность нажимаемого элемента: слабый слой поверх фона панели.
    func protoControlSurface(_ radius: CGFloat = Tokens.Radius.control) -> some View {
        modifier(ControlSurface(cornerRadius: radius))
    }

    func protoHover(radius: CGFloat = Tokens.Radius.control, isEnabled: Bool = true) -> some View {
        modifier(HoverHighlight(cornerRadius: radius, isEnabled: isEnabled))
    }
}

private struct PanelSurface: ViewModifier {

    let cornerRadius: CGFloat

    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(scheme == .dark
                              ? Color.black.opacity(0.55)
                              : Color.white.opacity(0.72))
                }
        }
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
