import AppKit
import Observation
import SwiftUI

/// Окно входящего вызова.
///
/// Это `NSPanel`, а не сцена SwiftUI, и на то три причины, каждая из которых
/// сама по себе достаточна:
///
/// * окно не должно забирать фокус — оператор в этот момент печатает в CRM,
///   и активация чужого приложения посреди набора недопустима
///   (`.nonactivatingPanel` + `orderFrontRegardless`);
/// * оно должно висеть поверх всех окон и на всех рабочих столах
///   (`level = .floating`, `collectionBehavior`);
/// * позиция задаётся точно и случайно, а `windowLevel` и
///   `defaultWindowPlacement` в SwiftUI появились только в macOS 15.
@MainActor
@Observable
final class IncomingCallPanel {

    private var panel: NSPanel?

    /// Где окно было в прошлый раз — чтобы следующая позиция гарантированно
    /// отличалась и оператор не привыкал жать в одну точку.
    private var lastOrigin: CGPoint?

    var isVisible: Bool { panel != nil }

    func show(
        callerNumber: String,
        callerName: String?,
        placement settings: AppModel.IncomingCallPlacementSettings,
        onAnswer: @escaping @MainActor () -> Void,
        onDecline: @escaping @MainActor () -> Void
    ) {
        hide()

        let size = Theme.Metrics.incomingCallPanelSize
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        // Окно не должно исчезать, когда оператор уходит в другое приложение —
        // это единственный индикатор того, что кто-то звонит.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow

        panel.contentView = NSHostingView(
            rootView: IncomingCallView(
                callerNumber: callerNumber,
                callerName: callerName,
                onAnswer: { [weak self] in
                    self?.hide()
                    onAnswer()
                },
                onDecline: { [weak self] in
                    self?.hide()
                    onDecline()
                }
            )
        )

        // Размер окна берём после установки контента, а не из константы:
        // NSHostingView сообщает окну свой идеальный размер (340x196), а стиль
        // .titled добавляет сверху 32 pt прозрачной полосы заголовка, так что
        // настоящая рамка выше нарисованной карточки. Если считать размещение
        // по константе, панель вылезет за верхний отступ экрана ровно на эти
        // 32 pt. Полоса ничего не рисует и визуально незаметна; убрать её совсем
        // (borderless-панель) — задача M3, вместе с остальной полировкой окна.
        let frameSize = panel.frame.size
        let origin = nextOrigin(forPanelSize: frameSize, settings: settings)
        panel.setFrameOrigin(origin)
        lastOrigin = origin

        // Именно regardless: обычный orderFront активировал бы приложение.
        panel.orderFrontRegardless()

        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Позиционирование

    private func nextOrigin(
        forPanelSize size: CGSize,
        settings: AppModel.IncomingCallPlacementSettings
    ) -> CGPoint {
        // Экран под курсором, а не «главный»: оператор может работать на втором.
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let screen else { return .zero }

        let area = screen.visibleFrame.insetBy(dx: settings.screenMargin, dy: settings.screenMargin)

        guard settings.isEnabled else {
            return CGPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2)
        }

        var generator = SystemRandomNumberGenerator()
        let placement = IncomingCallPlacement(bounds: area, minimumTravel: settings.minimumTravel)
        return placement.origin(forPanelSize: size, previous: lastOrigin, using: &generator)
    }
}
