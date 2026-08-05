import AppKit
import SwiftUI

/// Точка, из которой раскрывается `NSMenu`.
///
/// Меню в AppKit раскрывается относительно вида, а у вёрстки SwiftUI вида нет.
/// Поэтому под кнопку подкладывается пустой `NSView`: он ничего не рисует и
/// нужен ровно затем, чтобы меню знало, подо что вставать.
///
/// Почему вообще `NSMenu`, а не `Menu` из SwiftUI: тот появился в macOS 11, а
/// срез x86_64 обязан работать на Catalina. Второй довод обнаружился на
/// прототипе — `Menu` со своим стилем перерисовывает подпись по-своему и
/// выбрасывает из неё и точку состояния, и капсулу.
@MainActor
final class MenuAnchor {

    fileprivate weak var view: NSView?

    /// Раскрывает меню под кнопкой, а не под курсором.
    ///
    /// Под курсором меню встаёт там, где человек нажал, — и список профилей
    /// прыгал бы по панели вслед за промахом. Под кнопкой он всегда на одном
    /// месте, как у системного всплывающего списка.
    func popUp(menu: NSMenu) {
        guard let view else { return }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: view.bounds.height + 4),
            in: view
        )
    }
}

struct MenuAnchorView: NSViewRepresentable {

    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

extension NSMenuItem {

    /// Действие пункта замыканием вместо пары «цель и селектор».
    ///
    /// `nil` выключает пункт: у `NSMenuItem` без действия нет и активности.
    var onSelect: (() -> Void)? {
        get { (representedObject as? Handler)?.body }
        set {
            guard let newValue else {
                representedObject = nil
                target = nil
                action = nil
                isEnabled = false
                return
            }
            let handler = Handler(body: newValue)
            // Держится в `representedObject`: цель у пункта меню слабая, и
            // замыкание без такого хозяина освободилось бы до первого нажатия.
            representedObject = handler
            target = handler
            action = #selector(Handler.fire)
            isEnabled = true
        }
    }

    private final class Handler: NSObject {

        let body: () -> Void

        init(body: @escaping () -> Void) {
            self.body = body
        }

        @objc func fire() {
            body()
        }
    }
}
