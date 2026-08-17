import AppKit
import SwiftUI

/// Слой совместимости интерфейса.
///
/// Пакет `Compat` закрывает то, чего нет в стандартной библиотеке; здесь — то,
/// чего нет в SwiftUI на Catalina и Big Sur. Собрано в одном файле намеренно:
/// россыпь `if #available` по вьюхам превращает вёрстку в нечитаемую, а список
/// того, чем мы платим за нижнюю планку, перестаёт существовать как список.
///
/// Правило одно: на новых системах поведение обязано остаться ровно прежним.
/// Ветка совместимости — это ухудшение вида, а не изменение логики.
extension View {

    /// `animation(_:value:)` появился в macOS 12.
    ///
    /// До него была неявная анимация без привязки к значению: она анимирует
    /// любое изменение вью, а не только нужное. Для подсветки под курсором
    /// разница незаметна, поэтому старый вариант годится как запасной.
    @ViewBuilder
    func compatAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        if #available(macOS 12.0, *) {
            self.animation(animation, value: value)
        } else {
            self.animation(animation)
        }
    }

    /// `task` появился в macOS 12. Замена — та же задача из `onAppear`.
    ///
    /// Отличие, о котором надо помнить: `task` отменяет задачу, когда вью
    /// исчезает, а `onAppear` — нет. Поэтому запасной вариант держит задачу
    /// сам и снимает её в `onDisappear`.
    func compatTask(_ action: @escaping @Sendable () async -> Void) -> some View {
        modifier(CompatTask(action: action))
    }

    /// `help` появился в macOS 11. На Catalina всплывающей подсказки не будет.
    @ViewBuilder
    func compatHelp(_ text: LocalizedStringKey) -> some View {
        if #available(macOS 11.0, *) {
            self.help(text)
        } else {
            self
        }
    }

    /// Подсказка, собранная в рантайме, — переводить нечего.
    @ViewBuilder
    func compatHelp(verbatim text: some StringProtocol) -> some View {
        if #available(macOS 11.0, *) {
            self.help(Text(text))
        } else {
            self
        }
    }

    /// `accessibilityLabel` появился в macOS 11.
    ///
    /// Подпись берётся ключом, а не строкой: голос VoiceOver — такая же
    /// подпись приложения, как надпись на кнопке, и остаться непереведённой
    /// она не имеет права. Тем более что чаще всего это единственный текст
    /// у кнопки, на которой нарисована одна иконка.
    @ViewBuilder
    func compatAccessibilityLabel(_ label: LocalizedStringKey) -> some View {
        if #available(macOS 11.0, *) {
            self.accessibilityLabel(Text(label))
        } else {
            self
        }
    }

    /// Подпись, собранная в рантайме, — переводить нечего.
    @ViewBuilder
    func compatAccessibilityLabel(verbatim label: some StringProtocol) -> some View {
        if #available(macOS 11.0, *) {
            self.accessibilityLabel(Text(label))
        } else {
            self
        }
    }

    /// `accessibilityHidden` появился в macOS 11.
    @ViewBuilder
    func compatAccessibilityHidden(_ hidden: Bool) -> some View {
        if #available(macOS 11.0, *) {
            self.accessibilityHidden(hidden)
        } else {
            self
        }
    }

    /// `keyboardShortcut` появился в macOS 11.
    ///
    /// Для окна входящего это не потеря: ярлыки SwiftUI в нём и так не
    /// срабатывают — оно намеренно не становится ключевым, и цифры ловит
    /// монитор событий в `IncomingCallPanel`.
    @ViewBuilder
    func compatKeyboardShortcut(_ key: Character, modifiers: EventModifiers = .command) -> some View {
        if #available(macOS 11.0, *) {
            self.keyboardShortcut(KeyEquivalent(key), modifiers: modifiers)
        } else {
            self
        }
    }

    /// `overlay(alignment:content:)` с замыкателем появился в macOS 12;
    /// вариант с готовой вью есть с 10.15.
    func compatOverlay<Overlay: View>(
        alignment: Alignment = .center,
        @ViewBuilder _ content: () -> Overlay
    ) -> some View {
        overlay(content(), alignment: alignment)
    }

    /// То же для фона: замыкатель — macOS 12, готовая вью — 10.15.
    func compatBackground<Background: View>(
        alignment: Alignment = .center,
        @ViewBuilder _ content: () -> Background
    ) -> some View {
        background(content(), alignment: alignment)
    }

    /// Содержимое во всю высоту окна, включая полосу заголовка.
    ///
    /// Панель рисует собственную строку состояния на одной линии со светофором,
    /// а SwiftUI по умолчанию отводит под полосу заголовка безопасную зону и
    /// опускает содержимое под неё. `ignoresSafeArea` — macOS 11, ниже тот же
    /// смысл даёт `edgesIgnoringSafeArea`.
    /// - Parameter edges: какие края отдать. По умолчанию все — так этим
    ///   пользуются фоны окон.
    @ViewBuilder
    func compatIgnoreSafeArea(_ edges: Edge.Set = .all) -> some View {
        if #available(macOS 11.0, *) {
            self.ignoresSafeArea(edges: edges)
        } else {
            self.edgesIgnoringSafeArea(edges)
        }
    }

    /// Отступ сверху, под который прокрутка всё равно уезжает.
    ///
    /// Не `padding`: у прокрутки отступ обязан быть безопасной зоной, а не
    /// полем. Поле сдвигает всё содержимое вниз вместе с прокруткой, и под
    /// светофор уже ничего не уходит — граница списка просто встаёт ниже.
    /// Безопасная зона отодвигает только первый экран, а дальше содержимое идёт
    /// под неё, как в системных окнах.
    ///
    /// Двух зон подряд здесь не бывает, и это держится не на версии, а на
    /// оформлении: системную зону снимает `safeAreaRegions`, доступный с
    /// macOS 13.3, и снимается она только в стеклянном варианте — а он и есть
    /// macOS 26. В обычном варианте окно не заходит под полосу заголовка, там
    /// системной зоны нет вовсе, и своя ложится на пустое место.
    ///
    /// `safeAreaInset` появился в macOS 12. Ниже остаётся поле: под полосу там
    /// всё равно ничего не уезжает, и разница между зоной и полем пропадает.
    @ViewBuilder
    func compatOwnTopInset(_ height: CGFloat) -> some View {
        if #available(macOS 12.0, *) {
            self.safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: height)
            }
        } else {
            self.padding(.top, height)
        }
    }

    /// Убирает собственный фон у прокручиваемого содержимого.
    ///
    /// `scrollContentBackground` появился в macOS 13. Ниже своего фона у списка
    /// не отнять — там он и есть системный вид, а не наша добавка.
    @ViewBuilder
    func compatHiddenScrollBackground() -> some View {
        if #available(macOS 13.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }

    /// Тумблер вместо галочки.
    ///
    /// Вне `Form` macOS рисует `Toggle` галочкой, а в окне настроек ожидается
    /// тумблер. Настройки менеджера собраны без `Form` — сгруппированная форма
    /// ставит непрозрачные плашки и прячет материал окна, — поэтому стиль
    /// приходится называть явно. Сокращение `.switch` появилось в macOS 12, сам
    /// стиль есть с 10.15.
    func compatSwitchToggle() -> some View {
        toggleStyle(SwitchToggleStyle())
    }

    /// `background(_:in:)` — заливка формой — тоже macOS 12.
    func compatBackground(_ color: Color, cornerRadius: CGFloat) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius).fill(color))
    }

    /// `keyboardShortcut(.cancelAction)`: сам `KeyboardShortcut` — macOS 11.
    @ViewBuilder
    func compatCancelShortcut() -> some View {
        if #available(macOS 11.0, *) {
            self.keyboardShortcut(.cancelAction)
        } else {
            self
        }
    }

    /// `.borderedProminent` появился в macOS 12. Ниже остаётся системный стиль
    /// кнопки по умолчанию: он же и был акцентным до появления `.bordered`.
    @ViewBuilder
    func compatProminentButtonStyle() -> some View {
        if #available(macOS 12.0, *) {
            self.buttonStyle(.borderedProminent)
        } else {
            self.buttonStyle(DefaultButtonStyle())
        }
    }

    /// То же самое по условию — для выбора из нескольких кнопок, где акцент
    /// достаётся выбранной. На macOS ниже 12 разницы в стиле нет вовсе,
    /// поэтому выбранное состояние обязано быть видно и без неё.
    @ViewBuilder
    func compatProminentButtonStyle(_ isProminent: Bool) -> some View {
        if isProminent {
            self.compatProminentButtonStyle()
        } else {
            self.buttonStyle(DefaultButtonStyle())
        }
    }
}

extension View {

    /// `formStyle(.grouped)` появился в macOS 13. Ниже форма рисуется стилем по
    /// умолчанию: группировка пропадает, поля остаются.
    @ViewBuilder
    func compatGroupedForm() -> some View {
        if #available(macOS 13.0, *) {
            self.formStyle(.grouped)
        } else {
            self
        }
    }

    /// `monospacedDigit()` появился в macOS 12. Ниже тот же эффект даёт
    /// моноширинное начертание: цифры перестают прыгать при пересчёте.
    @ViewBuilder
    func compatMonospacedDigit() -> some View {
        if #available(macOS 12.0, *) {
            self.monospacedDigit()
        } else {
            self.font(.system(.body, design: .monospaced))
        }
    }

    /// `textSelection` появился в macOS 12. На Catalina строку журнала
    /// выделить мышью нельзя — целиком журнал копируется кнопкой.
    @ViewBuilder
    func compatTextSelection() -> some View {
        if #available(macOS 12.0, *) {
            self.textSelection(.enabled)
        } else {
            self
        }
    }
}

/// Строка «подпись — значение».
///
/// `LabeledContent` появился в macOS 13. Замена — тот же ряд руками: подпись
/// слева, значение справа, распорка между ними.
struct CompatLabeledContent<Content: View>: View {

    let title: Text
    @ViewBuilder let content: () -> Content

    init(title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.title = Text(title)
        self.content = content
    }

    init(title: Text, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        HStack {
            title
            Spacer(minLength: 12)
            content()
        }
    }
}

extension CompatLabeledContent where Content == Text {

    /// Значение справа не переводится: это всегда посчитанная величина —
    /// адрес, счётчик, длительность, — а не подпись приложения.
    init(_ title: LocalizedStringKey, value: some StringProtocol) {
        self.init(title: title) { Text(value) }
    }
}

extension URL {

    /// `path(percentEncoded:)` появился в macOS 13; `path` есть всегда.
    var compatPath: String {
        if #available(macOS 13.0, *) {
            return path(percentEncoded: false)
        } else {
            return path
        }
    }
}

/// Время без даты.
///
/// `Date.formatted(date:time:)` появился в macOS 12. `DateFormatter` есть
/// всегда, и создаётся он здесь один раз: его инициализация дороже самого
/// форматирования, а строка журнала собирается на каждую запись.
enum TimeText {

    /// «13:05» — для бейджа регистрации, где важен час, а не секунда.
    static let short: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    /// «13:05:42» — для журнала, где порядок событий важнее краткости.
    static let withSeconds: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

/// Целое число в поле ввода.
///
/// `TextField(_:value:format:)` — macOS 12; вариант с `Formatter` есть с 10.15.
enum IntegerFormatter {

    static let shared: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        return formatter
    }()
}

/// Крутящийся индикатор.
///
/// `ProgressView` — macOS 11, а `NSProgressIndicator` есть всегда. Взят он, а
/// не ветка по версии: индикатор крошечный, отличить их на глаз нельзя, и одна
/// реализация на все версии — это на одну развилку меньше.
struct CompatSpinner: NSViewRepresentable {

    var controlSize: NSControl.ControlSize = .small

    func makeNSView(context: Context) -> NSProgressIndicator {
        let view = NSProgressIndicator()
        view.style = .spinning
        view.controlSize = controlSize
        view.isIndeterminate = true
        view.startAnimation(nil)
        return view
    }

    func updateNSView(_ nsView: NSProgressIndicator, context: Context) {
        nsView.controlSize = controlSize
    }
}

/// Поле ввода, у которого Enter что-то делает.
///
/// `onSubmit` появился в macOS 12; до него та же роль была у параметра
/// `onCommit` самого `TextField`. Разница не косметическая: без Enter перевод
/// звонка требует мыши в момент, когда оператор уже держит руки на клавиатуре.
struct CompatTextField: View {

    let title: LocalizedStringKey
    @Binding var text: String
    var onSubmit: () -> Void = {}

    var body: some View {
        if #available(macOS 12.0, *) {
            TextField(title, text: $text).onSubmit(onSubmit)
        } else {
            TextField(title, text: $text, onCommit: onSubmit)
        }
    }
}

extension View {

    /// `foregroundStyle` появился в macOS 12, а перегрузка с `ShapeStyle`,
    /// которой пользуется вёрстка, — в 14. `foregroundColor` есть с 10.15.
    ///
    /// Принимает `Color`, а не `ShapeStyle`: иерархические `.secondary` и
    /// `.tertiary` в проекте применяются только к тексту, а там они и есть
    /// цвета. Градиентов и материалов в переднем плане нигде нет.
    @ViewBuilder
    func compatForeground(_ color: Color) -> some View {
        if #available(macOS 12.0, *) {
            self.foregroundStyle(color)
        } else {
            self.foregroundColor(color)
        }
    }
}

/// Иконка из комплекта проекта.
///
/// Не `Image(systemName:)`: SF Symbols появились в macOS 11, а срез x86_64
/// обязан работать на Catalina, где их нет вовсе — это не шим, а отсутствующий
/// ресурс. Комплект лежит в `Assets.xcassets/Symbols` и рисуется одинаково на
/// всех версиях: иначе вид приложения расходился бы между Catalina и Tahoe, и
/// проверять пришлось бы оба.
///
/// Имена совпадают с именами SF Symbols намеренно. Благодаря этому заменить
/// комплект на свой — это положить другие файлы в каталог, а не править вёрстку.
/// Исходники иконок — во фрейме «Иконки · комплект для Catalina» того же
/// макета, что и остальной дизайн.
///
/// Размер задаётся явно, а не наследуется от шрифта, как у SF Symbols:
/// растровому ресурсу наследовать не от чего.
struct CompatSymbol: View {

    let name: String
    var size: CGFloat = 13

    var body: some View {
        Image(name)
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}

/// Шеврон вниз — формой, а не картинкой из комплекта.
///
/// В `Assets.xcassets/Symbols` его нет, и это не упущение: комплект рисуется
/// руками ради Catalina, а шеврон — три отрезка, которые проще задать, чем
/// нарисовать. Заодно он остаётся резким на любом размере и берёт цвет от
/// окружения, как и остальные иконки.
struct ChevronDown: View {

    /// Ширина «галки». Высота — половина: пропорция взята у системного
    /// шеврона, при других она читается как стрелка или как галочка.
    var width: CGFloat = 7
    var lineWidth: CGFloat = 1.5

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: width / 2, y: width / 2))
            path.addLine(to: CGPoint(x: width, y: 0))
        }
        .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        .frame(width: width, height: width / 2)
    }
}

/// Круг, залитый наполовину — знак оформления.
///
/// Формой, а не картинкой из комплекта, по тому же доводу, что у `ChevronDown`:
/// комплект рисуется руками ради Catalina, а половина круга — это круг и
/// полукруг, которые проще задать, чем нарисовать в четырёх размерах. Заодно он
/// остаётся резким на любом кегле и берёт цвет от окружения.
///
/// Взят именно этот знак, а не `eye.slash` из комплекта: перечёркнутый глаз
/// читается как «скрыто», а экран спрашивает, **как приложение выглядит**.
/// Половина круга — то же, чем macOS подписывает выбор темы у себя.
struct AppearanceGlyph: View {

    var size: CGFloat = 32
    var lineWidth: CGFloat = 1.5

    var body: some View {
        ZStack {
            Circle()
                .stroke(lineWidth: lineWidth)
            // Левая половина залита: у системного знака темы залита та же.
            Circle()
                .trim(from: 0.5, to: 1)
                .fill()
        }
        .frame(width: size, height: size)
    }
}

/// Замена `Label(_:systemImage:)`, которого нет до macOS 11.
struct CompatLabel: View {

    let title: Text
    let symbol: String
    var size: CGFloat = 13
    var spacing: CGFloat = 6

    init(title: LocalizedStringKey, symbol: String, size: CGFloat = 13, spacing: CGFloat = 6) {
        self.init(title: Text(title), symbol: symbol, size: size, spacing: spacing)
    }

    /// Подпись, собранная в рантайме, — переводить нечего.
    init(verbatim title: some StringProtocol, symbol: String, size: CGFloat = 13, spacing: CGFloat = 6) {
        self.init(title: Text(title), symbol: symbol, size: size, spacing: spacing)
    }

    init(title: Text, symbol: String, size: CGFloat = 13, spacing: CGFloat = 6) {
        self.title = title
        self.symbol = symbol
        self.size = size
        self.spacing = spacing
    }

    var body: some View {
        HStack(spacing: spacing) {
            CompatSymbol(name: symbol, size: size)
            title
        }
    }
}

private struct CompatTask: ViewModifier {

    let action: @Sendable () async -> Void

    @State private var task: Task<Void, Never>?

    func body(content: Content) -> some View {
        if #available(macOS 12.0, *) {
            content.task { await action() }
        } else {
            content
                .onAppear { task = Task { await action() } }
                .onDisappear { task?.cancel(); task = nil }
        }
    }
}

/// Материал под содержимым.
///
/// `Material` из SwiftUI появился в macOS 12, но сам эффект есть с 10.10 —
/// `NSVisualEffectView`. Поэтому на Catalina панель не становится плоской: она
/// получает тот же системный материал, только через AppKit.
struct CompatMaterial: NSViewRepresentable {

    var material: NSVisualEffectView.Material = .contentBackground

    /// Что размывать: содержимое своего окна или то, что за ним.
    ///
    /// Умолчание осталось прежним, потому что на нём стоят внутренние
    /// поверхности. Для фона самого окна нужен `.behindWindow` — иначе
    /// прозрачности не будет вовсе, сколько ни настраивай подкраску: размывать
    /// материалу будет нечего, кроме собственного окна.
    var blending: NSVisualEffectView.BlendingMode = .withinWindow
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
        nsView.layer?.cornerRadius = cornerRadius
    }
}

/// Заставляет прокрутку не отбирать ширину у содержимого.
///
/// Системные полосы прокрутки бывают двух видов, и вид выбирает человек в
/// настройках системы. «Всегда» — полоса занимает своё место в раскладке, и
/// содержимое сужается ровно на её ширину, как только прокрутка появилась.
/// Живое окно показало, чем это оборачивается: раздел с прокруткой («АТС») и
/// раздел без неё («Аккаунт») получали разный отступ справа, и переключение
/// между ними дёргало правый край.
///
/// Здесь полоса переводится в наложение: она рисуется поверх содержимого и
/// ширины не отнимает. Это не спор с настройкой человека, а требование к окну,
/// раскладку которого мы обещали проверять замером: два разных правых поля
/// в одном окне замерить нельзя.
///
/// Свой `NSScrollView` ищется вверх по иерархии, потому что создаёт его SwiftUI
/// и наружу не отдаёт. Поиск отложен до следующего цикла: в момент вызова
/// `makeNSView` вью ещё не вставлена в дерево.
struct ScrollOverlayScrollers: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { apply(from: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(from: nsView) }
    }

    private func apply(from view: NSView) {
        var candidate: NSView? = view
        while let current = candidate {
            if let scroll = current as? NSScrollView {
                scroll.scrollerStyle = .overlay
                scroll.autohidesScrollers = true
                return
            }
            candidate = current.superview
        }
    }
}
