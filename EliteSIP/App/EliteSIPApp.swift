import AppKit
import SwiftUI

/// Точка входа и владелец окон.
///
/// `NSApplicationDelegate`, а не `App` из SwiftUI: протокол `App`, сцена
/// `Window` и `openWindow` появились в macOS 11–13, а срез x86_64 обязан
/// работать на Catalina. Само содержимое окон остаётся общим SwiftUI — оно
/// показывается через `NSHostingController`, и вьюхи об этой замене не знают.
///
/// Три окна, как договорились:
///
/// 1. Панель софтфона — фиксированной ширины, со скрытым заголовком. Свой
///    размер она задаёт себе сама через `WindowAccessor`: при скрытой полосе
///    заголовка рамка выше содержимого, и снаружи эту разницу не угадать.
/// 2. Настройки — отдельное полноценное окно, а не панель `Settings`.
/// 3. Входящий вызов — вообще не окно приложения, а `NSPanel` со своим
///    уровнем и случайной позицией (см. `IncomingCallPanel`).
///
/// Точка входа лежит в `main.swift`, а не в `@main` на этом классе, и это не
/// вкусовщина: `NSApplication.delegate` — слабая ссылка, поэтому делегат,
/// созданный прямо в `@main`, освобождается сразу после
/// `applicationDidFinishLaunching`. Меню при этом остаётся (его держит `NSApp`),
/// а окна исчезают вместе с делегатом — приложение запускается и показывает
/// пустой экран с рабочим меню.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let model = AppModel()

    private var phoneWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        showPhoneWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Закрытая панель приложение не завершает: софтфон обязан оставаться на
    /// линии и принимать вызовы, даже когда оператор убрал окно с глаз.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Клик по иконке в доке возвращает панель — иначе закрытое окно уже ничем
    /// не открыть: пункт «Новый» из меню убран.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showPhoneWindow(nil) }
        return true
    }

    // MARK: - Окна

    @objc private func showPhoneWindow(_ sender: Any?) {
        if let phoneWindow {
            phoneWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: CGRect(
                origin: .zero,
                size: CGSize(width: Theme.Metrics.panelWidth, height: Theme.Metrics.panelHeight)
            ),
            // Без `.resizable`: это и есть `windowResizability(.contentSize)`.
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "EliteSIP"
        // Пара строк, заменяющая `windowStyle(.hiddenTitleBar)`.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: withEnvironment(PhonePanelView()))

        // Размер задаётся до центрирования, а не после: `NSHostingController`
        // подгоняет окно под содержимое, и `center()` посчитал бы середину для
        // той, промежуточной величины. Панель после этого встаёт по своему
        // размеру (`WindowAccessor`), сохраняя верхний левый угол, — и уезжает
        // от центра ровно на разницу.
        window.setFrame(
            CGRect(
                origin: .zero,
                size: CGSize(width: Theme.Metrics.panelWidth, height: Theme.Metrics.panelHeight)
            ),
            display: false
        )
        window.center()

        phoneWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func showSettingsWindow(_ sender: Any?) {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: CGSize(width: 660, height: 460)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Настройки EliteSIP"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: withEnvironment(SettingsView()))
        window.center()

        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    /// Общая для всех окон обвязка: модель и владелец окна входящего.
    private func withEnvironment<Content: View>(_ content: Content) -> some View {
        content
            .environmentObject(model)
            .environmentObject(model.incomingCallPanel)
    }

    // MARK: - Меню

    /// Меню собирается руками, потому что вместе с `App` уходит и `Commands`.
    ///
    /// Пунктов ровно столько, сколько нужно. «Правка» здесь не для галочки: без
    /// неё в полях настроек не работают ни ⌘V, ни ⌘Z.
    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "О программе EliteSIP",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Настройки…",
            action: #selector(showSettingsWindow(_:)),
            keyEquivalent: ","
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Скрыть EliteSIP",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthers = appMenu.addItem(
            withTitle: "Скрыть остальные",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: "Показать все",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Завершить EliteSIP",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Правка")
        editMenu.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Повторить", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Скопировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Выбрать все", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Окно")
        windowMenu.addItem(
            withTitle: "Свернуть",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(
            withTitle: "Закрыть",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: "Панель EliteSIP",
            action: #selector(showPhoneWindow(_:)),
            keyEquivalent: "0"
        )
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }
}
