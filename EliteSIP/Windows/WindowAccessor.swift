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

/// Задаёт окну высоту и переносит её при изменении, сохраняя верхний левый угол.
///
/// Отдельно от `WindowAccessor`, потому что тот настраивает окно однократно, а
/// высота панели меняется: она зависит от числа макросов у сотрудника и от того,
/// свёрнута ли панель. Растёт панель вниз — верхний край остаётся там, куда его
/// поставил оператор, и окно не уползает по экрану при каждом переключении.
final class PanelHeightView: NSView {

    private var applied: CGFloat?
    private var pending: CGFloat?

    func apply(height: CGFloat) {
        pending = height
        guard let window, applied != height else { return }
        applied = height

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
