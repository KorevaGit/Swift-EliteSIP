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
        guard let view, view.window != nil else { return }
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
        AnchorView(anchor: anchor)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if nsView.window != nil { anchor.view = nsView }
    }

    /// Якорем становится только вью, стоящая в окне.
    ///
    /// При смене обоев дерево SwiftUI пересобирается: новая вью создаётся
    /// раньше, чем уходит старая, и старая последним `updateNSView` забирала
    /// якорь себе — а потом покидала окно. Меню раскрывалось во вью без окна,
    /// то есть никуда, и капсула профиля переставала открываться до перезапуска.
    private final class AnchorView: NSView {
        weak var anchor: MenuAnchor?

        init(anchor: MenuAnchor) {
            self.anchor = anchor
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                anchor?.view = self
            } else if anchor?.view === self {
                anchor?.view = nil
            }
        }
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
