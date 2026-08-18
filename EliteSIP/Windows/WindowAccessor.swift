import AppKit
import SwiftUI

/// Доступ к `NSWindow`, в котором живёт SwiftUI-вьюха.
///
/// Реализовано через переопределение `viewDidMoveToWindow`, а не через
/// `DispatchQueue.main.async` из `makeNSView`: при строгой проверке
/// конкурентности Swift 6 асинхронный хоп потребовал бы протаскивать через
/// границу изоляции несендабельные `NSView` и замыкание. Здесь всё происходит
/// синхронно на главном потоке, и вопрос не возникает.
final class WindowConfiguringView: NSView {

    var configure: ((NSWindow) -> Void)?

    /// `viewDidMoveToWindow` вызывается не один раз, а настройка окна должна
    /// применяться однократно: иначе она будет отменять любое действие
    /// пользователя, например перетаскивание.
    private var didConfigure = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !didConfigure, let window else { return }
        didConfigure = true
        configure?(window)
    }
}

struct WindowAccessor: NSViewRepresentable {

    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowConfiguringView {
        let view = WindowConfiguringView()
        view.configure = configure
        return view
    }

    func updateNSView(_ nsView: WindowConfiguringView, context: Context) {
        nsView.configure = configure
    }
}

/// Название окна, которое меняется по ходу работы.
///
/// Отдельно от `WindowAccessor`, потому что тот настраивает окно однократно.
/// Нужен ровно одному окну — истории: она жёстко ограничена активным профилем,
/// и профиль назван в заголовке. Сменил оператор профиль — заголовок обязан
/// смениться вместе со списком, иначе окно подписано чужим именем.
final class WindowTitleView: NSView {

    private var applied: String?
    private var pending: String?

    func apply(title: String) {
        pending = title
        guard let window, applied != title else { return }
        applied = title
        window.title = title
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let pending else { return }
        applied = nil
        apply(title: pending)
    }
}

struct WindowTitle: NSViewRepresentable {

    let title: String

    func makeNSView(context: Context) -> WindowTitleView {
        let view = WindowTitleView()
        view.apply(title: title)
        return view
    }

    func updateNSView(_ nsView: WindowTitleView, context: Context) {
        nsView.apply(title: title)
    }
}

/// Держит окно поверх других — но только пока это оправдано.
///
/// Отдельно от `WindowAccessor`, потому что тот настраивает окно однократно, а
/// уровень меняется по ходу работы: поверх чужих окон панель нужна в
/// разговоре, когда до кнопки «Завершить» надо дотянуться не глядя. В покое
/// она такое же окно, как любое другое, и висеть над чужой работой ей незачем
/// — это раздражает ровно тех, ради кого всё делается.
final class WindowLevelView: NSView {

    private var applied: NSWindow.Level?
    private var pending: NSWindow.Level?

    func apply(level: NSWindow.Level) {
        pending = level
        guard let window, applied != level else { return }
        applied = level
        window.level = level
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let pending else { return }
        applied = nil
        apply(level: pending)
    }
}

struct WindowLevel: NSViewRepresentable {

    let level: NSWindow.Level

    func makeNSView(context: Context) -> WindowLevelView {
        let view = WindowLevelView()
        view.apply(level: level)
        return view
    }

    func updateNSView(_ nsView: WindowLevelView, context: Context) {
        nsView.apply(level: level)
    }
}

/// Сообщает вёрстке высоту полосы заголовка.
///
/// Спрашиваем у окна, а не держим числом в `Theme`: величина системная и по
/// версиям разная — замер живого окна на macOS 26 дал 32 точки против 28 на
/// прежних. Своя константа означала бы, что панель ошибается в высоте ровно на
/// разницу, а вместе с ней уезжает и всё, что под полосой.
///
/// При `.fullSizeContentView` содержимое занимает окно целиком, поэтому высота
/// полосы — это разница между рамкой и той её частью, которую система считает
/// свободной под содержимое.
final class TitleBarInsetView: NSView {

    var report: ((CGFloat) -> Void)?

    private var reported: CGFloat?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        let inset = window.frame.height - window.contentLayoutRect.height
        // Ноль означает, что окно ещё не разложено; отрицательного не бывает.
        // Ни то ни другое сообщать вёрстке нельзя — она задаст себе высоту по
        // мусорному числу и второй раз спросить будет некому.
        guard inset > 0, reported != inset else { return }
        reported = inset
        report?(inset)
    }
}

struct TitleBarInsetReader: NSViewRepresentable {

    let report: (CGFloat) -> Void

    func makeNSView(context: Context) -> TitleBarInsetView {
        let view = TitleBarInsetView()
        view.report = report
        return view
    }

    func updateNSView(_ nsView: TitleBarInsetView, context: Context) {
        nsView.report = report
    }
}

/// Сообщает вёрстке, насколько сайдбар отступает от краёв окна сверху и снизу.
///
/// На macOS 26 сайдбар — не колонка во всю высоту, а плавающая вставка со
/// скруглёнными углами и полями вокруг. Содержимое рядом с ней таких полей не
/// получает и начинается у самого края окна: на глаз правая половина оказывается
/// и выше, и ниже левой. Выравнивать надо по вставке, а не по окну.
///
/// Величину полей спрашиваем у самой вставки, а не держим числом: своё число
/// означало бы, что на системе с другими полями — а до Tahoe их нет вовсе —
/// содержимое разъедется ровно на разницу. Замер повторяется на каждой
/// раскладке, а не однажды: поля переживают изменение размера окна.
///
/// Спрашиваем у половины сплита, а не у того, что нарисовано: сама вставка —
/// приватная вью нового оформления, и искать её по имени класса значило бы
/// сломаться на первом же обновлении системы. Зато вью сайдбара она кладёт
/// внутрь себя, и его рамка — замер `{{8, 8}, {160, 394}}` в окне высотой 410 —
/// и есть искомая вставка, полученная публичным `splitViewItems`.
final class SidebarInsetView: NSView {

    var report: ((CGFloat, CGFloat) -> Void)?

    private var reported: (top: CGFloat, bottom: CGFloat)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        measure()
    }

    override func layout() {
        super.layout()
        measure()
    }

    private func measure() {
        guard
            let window,
            let root = window.contentView,
            let split = window.contentViewController as? NSSplitViewController,
            let sidebar = split.splitViewItems.first?.viewController.view
        else { return }

        let frame = sidebar.convert(sidebar.bounds, to: root)
        let top = root.bounds.maxY - frame.maxY
        let bottom = frame.minY - root.bounds.minY

        // Отрицательного не бывает, а нули означают раскладку до Tahoe: там
        // сайдбар занимает свою половину целиком, вставки нет и выравнивать
        // нечего.
        guard top >= 0, bottom >= 0 else { return }
        guard reported?.top != top || reported?.bottom != bottom else { return }
        reported = (top, bottom)
        report?(top, bottom)
    }

}

struct SidebarInsetReader: NSViewRepresentable {

    let report: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> SidebarInsetView {
        let view = SidebarInsetView()
        view.report = report
        return view
    }

    func updateNSView(_ nsView: SidebarInsetView, context: Context) {
        nsView.report = report
    }
}

/// Сообщает вёрстке собственную высоту при каждой раскладке.
///
/// `GeometryReader` с `onChange` для этого не годится: `onChange` есть только с
/// macOS 11, а нижняя планка выпуска — 10.15. Замер вью работает на всём
/// диапазоне и делается там же, где система раскладывает окно.
final class HeightReaderView: NSView {

    var report: ((CGFloat) -> Void)?

    private var reported: CGFloat?

    override func layout() {
        super.layout()
        let height = bounds.height
        // Ноль — это ещё не разложенное вью, а не нулевая высота.
        guard height > 0, reported != height else { return }
        reported = height
        report?(height)
    }
}

struct HeightReader: NSViewRepresentable {

    let report: (CGFloat) -> Void

    func makeNSView(context: Context) -> HeightReaderView {
        let view = HeightReaderView()
        view.report = report
        return view
    }

    func updateNSView(_ nsView: HeightReaderView, context: Context) {
        nsView.report = report
    }
}

/// Задаёт окну высоту и переносит её при изменении, сохраняя верхний левый угол.
///
/// Отдельно от `WindowAccessor`, потому что тот настраивает окно однократно, а
/// высота панели меняется: она зависит от числа макросов у сотрудника и от того,
/// свёрнута ли панель. Растёт панель вниз — верхний край остаётся там, куда его
/// поставил оператор, и окно не уползает по экрану при каждом переключении.
final class PanelHeightView: NSView {

    private var applied: CGFloat?
    private var pending: CGFloat?

    /// Высота задаётся рамке окна.
    ///
    /// При `.fullSizeContentView` содержимое и рамка — одно и то же, поэтому
    /// разделять их не на чем. Высоту полосы заголовка вёрстка при этом всё
    /// равно знает: её сообщает `TitleBarInsetReader`, и она входит в
    /// присланное сюда число.
    func apply(height: CGFloat) {
        pending = height
        guard let window, applied != height else { return }
        applied = height

        // Верхний левый угол держим на месте: окно растёт вниз. Иначе панель
        // прыгала бы вверх при каждом добавленном ряде макросов.
        let topLeft = CGPoint(x: window.frame.minX, y: window.frame.maxY)
        window.setFrame(
            CGRect(
                x: topLeft.x,
                y: topLeft.y - height,
                width: Theme.Metrics.panelWidth,
                height: height
            ),
            display: true
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let pending else { return }
        applied = nil
        apply(height: pending)
    }
}

struct PanelHeight: NSViewRepresentable {

    let height: CGFloat

    func makeNSView(context: Context) -> PanelHeightView {
        let view = PanelHeightView()
        view.apply(height: height)
        return view
    }

    func updateNSView(_ nsView: PanelHeightView, context: Context) {
        nsView.apply(height: height)
    }
}

/// Волосок под полосой заголовка — только в оформлении без стекла.
///
/// `titlebarSeparatorStyle = .line` эту черту обещает и не рисует: полоса
/// заголовка у окон приложения прозрачная (иначе на стыке с содержимым остаётся
/// светлый волосок), а у прозрачной полосы система разделитель не рисует вовсе.
/// Живое окно 17 августа 2026: верх окна расплывался, светофор висел над
/// содержимым без границы.
///
/// Рисуется своим цветом, а не `Divider`: тот на тёмном фоне почти неразличим —
/// проверено тем же снимком. Толщина в одну точку, цвет — третичный из палитры:
/// это граница, а не элемент, и заявлять о себе громче системной черты ей нечем.
///
/// Под стеклом волоска быть не должно: там содержимое уходит **под** полосу
/// заголовка, и линия резала бы его пополам.
struct TitlebarHairline: View {

    let isGlass: Bool

    var body: some View {
        if isGlass {
            Color.clear.frame(height: 0)
        } else {
            Theme.Palette.textTertiary
                .frame(height: 1)
                .frame(maxWidth: .infinity)
        }
    }
}
