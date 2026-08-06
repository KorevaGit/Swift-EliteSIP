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
