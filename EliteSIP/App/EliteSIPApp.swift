import SwiftUI

enum WindowID {
    static let phone = "phone"
    static let settings = "settings"
}

/// Три окна, как договорились:
///
/// 1. Панель софтфона — `Window`, фиксированной ширины, скрытый заголовок.
/// 2. Настройки — отдельное полноценное окно, а не панель `Settings`.
/// 3. Входящий вызов — НЕ сцена SwiftUI, а `NSPanel` (см. `IncomingCallPanel`).
///    Ему нужны плавающий уровень, отказ от захвата фокуса и точная случайная
///    позиция; `windowLevel` и `defaultWindowPlacement` появились только в
///    macOS 15, а цель у нас 14+.
@main
struct EliteSIPApp: App {

    @State private var model = AppModel()
    @State private var incomingCall = IncomingCallPanel()

    var body: some Scene {
        Window("EliteSIP", id: WindowID.phone) {
            PhonePanelView()
                .environment(model)
                .environment(incomingCall)
        }
        .defaultSize(width: Theme.Metrics.panelWidth, height: Theme.Metrics.panelMinHeight)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands { EliteSIPCommands() }

        Window("Настройки EliteSIP", id: WindowID.settings) {
            SettingsView()
                .environment(model)
                .environment(incomingCall)
        }
        .defaultSize(width: 660, height: 460)
    }
}

struct EliteSIPCommands: Commands {

    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Заменяем штатный пункт «Settings…», чтобы ⌘, открывал наше окно.
        CommandGroup(replacing: .appSettings) {
            Button("Настройки…") {
                openWindow(id: WindowID.settings)
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        // Ничего из этого пока нечем наполнить, а пустые меню только мешают.
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .help) {}
    }
}
