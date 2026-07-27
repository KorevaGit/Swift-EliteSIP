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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            configure?(window)
        }
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
