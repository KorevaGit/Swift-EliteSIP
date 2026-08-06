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
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private let model = AppModel()

    private var phoneWindow: NSWindow?
    private var settingsWindow: NSWindow?

    /// Окно «Управление» — закрытые настройки.
    ///
    /// Отдельное окно, а не вкладки в настройках (решение M7c от 3 августа
    /// 2026). Причина не в раскладке: у закрытой части свой порядок работы —
    /// правки копятся и применяются кнопкой, — и в одном окне с менеджерскими
    /// настройками, которые применяются сразу, это читалось бы как неисправность.
    private var administrationWindow: NSWindow?

    /// Окно «История звонков».
    ///
    /// Своё окно, а не вкладка панели: панель фиксированной ширины и высоты по
    /// решению M0, и список с фильтром в неё влезает только ценой нечитаемых
    /// строк. Менеджерское, без пароля — историю своих же звонков менеджер
    /// смотрит сам, а закрыта в ней только настройка срока хранения.
    private var callHistoryWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Тема — до первого окна: иначе панель успевает нарисоваться в
        // системном оформлении и перекрашивается уже на глазах.
        NSApp.appearance = model.settings.appearance.appKitAppearance
        #if DEBUG
        // Снимок обеих тем нужен для сверки контраста, а тема — настройка
        // менеджера: без ключа проверяющему пришлось бы лезть в чужие
        // настройки и возвращать их обратно.
        //   EliteSIP.app/Contents/MacOS/EliteSIP --appearance light
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--appearance"),
           index + 1 < ProcessInfo.processInfo.arguments.count {
            let name = ProcessInfo.processInfo.arguments[index + 1]
            NSApp.appearance = NSAppearance(named: name == "light" ? .aqua : .darkAqua)
        }
        #endif
        NSApp.mainMenu = makeMainMenu()
        showPhoneWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        #if DEBUG
        // До автоподключения: сетка макросов должна быть на экране с первого
        // кадра, а не появляться после первой записи настроек.
        model.seedDebugMacrosIfNeeded()
        #endif

        // Регистрация поднимается сама: ручного «Подключить» в панели нет.
        model.startAutoConnect()
    }

    /// Закрытая панель приложение не завершает: софтфон обязан оставаться на
    /// линии и принимать вызовы, даже когда оператор убрал окно с глаз.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Выход снимает регистрацию и закрывает диалоги, пока транспорт жив.
    ///
    /// Без этого сервер держит и привязку пира, и разговор до истечения сроков:
    /// оператор вышел, а очередь продолжает считать его на линии и раздавать ему
    /// лиды. Отключение здесь принудительное — в разговоре обычная кнопка
    /// «Отключить» недоступна (M6b), и выход остаётся единственной дорогой,
    /// поэтому он спрашивает подтверждение, а не рвёт разговор молча.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.isInCall {
            let alert = NSAlert()
            alert.messageText = "Идёт разговор"
            alert.informativeText = "Выход завершит его и снимет регистрацию."
            alert.addButton(withTitle: "Завершить и выйти")
            alert.addButton(withTitle: "Отмена")
            guard alert.runModal() == .alertFirstButtonReturn else {
                return .terminateCancel
            }
        }

        Task { @MainActor in
            await model.disconnect(force: true)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
                size: CGSize(width: Theme.Metrics.panelWidth, height: Theme.Metrics.panelInitialHeight)
            ),
            // Без `.resizable`: это и есть `windowResizability(.contentSize)`.
            //
            // `.fullSizeContentView` обязателен вместе с прозрачным окном:
            // без него содержимое начинается под полосой заголовка, а сама
            // полоса остаётся без фона — светофор и название повисают над
            // рабочим столом, оторванные от панели. С ним поверхность панели
            // идёт под полосу, и стекло получается сплошным.
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Имя у окна есть, но рисует его вёрстка, а не AppKit.
        //
        // Системный заголовок центрируется по своей логике, которая для узкой
        // панели даёт не середину: замер живого окна показал 108.75 точки при
        // середине 135. Спорить с ней нечем — своё же название мы ставим ровно
        // по центру. Само `title` при этом остаётся: по нему окно называется в
        // меню «Окно» и в переключателе задач.
        window.title = "EliteSIP"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true

        // Без этой пары никакая прозрачность не работает: под материалом
        // окажется непрозрачный фон самого окна, и размывать `.behindWindow`
        // будет нечего.
        window.isOpaque = false
        window.backgroundColor = .clear

        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: withEnvironment(PhonePanelView()))

        // Уровень окна задаёт вёрстка (`WindowLevel`): поверх чужих окон панель
        // нужна в разговоре, а в покое она обычное окно. Здесь только
        // поведение, которое от состояния не зависит: без
        // `.fullScreenAuxiliary` плавающее окно либо исчезает при переходе в
        // полный экран, либо выкидывает из него.
        window.collectionBehavior = [.fullScreenAuxiliary, .managed]

        // Размер задаётся до центрирования, а не после: `NSHostingController`
        // подгоняет окно под содержимое, и `center()` посчитал бы середину для
        // той, промежуточной величины. Панель после этого встаёт по своему
        // размеру (`WindowAccessor`), сохраняя верхний левый угол, — и уезжает
        // от центра ровно на разницу.
        window.setFrame(
            CGRect(
                origin: .zero,
                size: CGSize(width: Theme.Metrics.panelWidth, height: Theme.Metrics.panelInitialHeight)
            ),
            display: false
        )
        restorePosition(of: window)

        phoneWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    /// Имя, под которым AppKit хранит позицию панели между запусками.
    private static let phoneWindowAutosaveName = "EliteSIPPhonePanel"

    /// Возвращает панель туда, где её оставили.
    ///
    /// Место для панели оператор выбирает один раз, а центр экрана — это место,
    /// выбранное за него. Хранит позицию AppKit сам, от нас нужно только имя и
    /// проверка на исчезнувший монитор.
    private func restorePosition(of window: NSWindow) {
        let restored = window.setFrameUsingName(Self.phoneWindowAutosaveName)
        window.setFrameAutosaveName(Self.phoneWindowAutosaveName)

        // Сохранённая позиция могла остаться от внешнего монитора, которого
        // сейчас нет: ноутбук отключили от дока, и панель уехала за пределы
        // единственного экрана — то есть исчезла. Проверяем не «попала ли она
        // на экран целиком», а «видно ли её вообще»: частично уехавшее окно
        // оператор дотащит сам, а полностью пропавшее — нет.
        let isVisible = NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame) }
        guard restored, isVisible else {
            window.center()
            return
        }
    }

    /// Не `private`: то же действие посылает кнопка на панели через
    /// `NSApp.sendAction(_:to:from:)` с пустой целью. Делегат приложения стоит в
    /// цепочке ответчиков, поэтому окно открывает один и тот же код — и пункт
    /// меню, и кнопка.
    @objc func showSettingsWindow(_ sender: Any?) {
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
        // Ради одного: закрытие окна гасит административный режим (M7c).
        window.delegate = self

        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    /// Открывает историю звонков.
    ///
    /// Не `private` по той же причине, что и настройки: то же самое действие
    /// шлёт кнопка на панели через цепочку ответчиков, и второго кода,
    /// умеющего открывать это окно, в приложении нет.
    @objc func showCallHistoryWindow(_ sender: Any?) {
        if let callHistoryWindow {
            // Окно живёт между показами, а срез истории в нём — нет: за время,
            // пока оно было закрыто, звонки шли.
            model.reloadHistory()
            callHistoryWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: CGSize(width: 560, height: 420)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "История звонков"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: withEnvironment(CallHistoryWindowView())
        )
        window.center()

        callHistoryWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    /// Открывает «Управление». Вызывается кнопкой уже после проверки пароля.
    @objc func showAdministrationWindow(_ sender: Any?) {
        if let administrationWindow {
            administrationWindow.makeKeyAndOrderFront(nil)
            return
        }

        model.beginAdministration()

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: CGSize(width: 700, height: 540)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Управление EliteSIP"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: withEnvironment(AdministrationWindowView())
        )
        window.center()
        window.delegate = self

        administrationWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    /// Закрывает «Управление» изнутри — по «Сохранить» или «Отменить».
    ///
    /// Не `private`: вызывается из SwiftUI через цепочку ответчиков, как и
    /// открытие. Решение уже принято к этому моменту, поэтому вопрос о
    /// несохранённом не задаётся — его задаёт `windowShouldClose`.
    @objc func closeAdministrationWindow(_ sender: Any?) {
        guard let administrationWindow else { return }
        self.administrationWindow = nil
        administrationWindow.delegate = nil
        administrationWindow.close()
    }

    /// Крестик окна «Управление» с несохранёнными правками спрашивает.
    ///
    /// Три ответа, как принято в macOS. Молчаливый выброс правок отвергнут:
    /// цена случайного ⌘W — вся настройка чужого рабочего места, а запрет
    /// закрывать окно, пока не решишь, ломает привычку сильнее, чем помогает.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === administrationWindow, model.hasUnsavedAdministrationChanges else {
            return true
        }

        let alert = NSAlert()
        alert.messageText = "Настройки изменены"
        alert.informativeText = """
            Сохранение объявит настройки этой машины локальными: их задаёт \
            администратор, а не файл конфигурации. Это будет записано в журнал.
            """
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Не сохранять")
        alert.addButton(withTitle: "Отмена")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            model.commitAdministration()
            administrationWindow = nil
            return true
        case .alertSecondButtonReturn:
            model.cancelAdministration()
            administrationWindow = nil
            return true
        default:
            return false
        }
    }

    /// Закрытие окна настроек закрывает административный режим.
    ///
    /// Срок жизни сессии выбран именно таким: администратор настроил чужое
    /// рабочее место, закрыл окно и ушёл — и после этого закрытая часть снова
    /// закрыта, без таймеров и без надежды на то, что он нажмёт «Выйти».
    /// Окно живёт дальше (`isReleasedWhenClosed = false`), поэтому следующее
    /// открытие снова спросит пароль, а не покажет прошлую сессию.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }

        if closing === settingsWindow {
            // «Управление» закрывается вместе с настройками: держать открытым
            // окно с черновиком, к которому нет дороги, незачем.
            if administrationWindow != nil {
                _ = windowShouldClose(administrationWindow!)
                closeAdministrationWindow(nil)
            }
            model.lockAdministration()
            return
        }

        if closing === administrationWindow {
            administrationWindow = nil
            // Черновик мог остаться открытым, если окно закрыли не через
            // `windowShouldClose` — например, вместе с приложением. Правки в
            // этом случае не применяются: несохранённое остаётся несохранённым.
            model.cancelAdministration()
        }
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
        // Заголовок обязателен, хотя система рисует вместо него имя приложения:
        // меню без него получается безымянным и узким, и «Настройки…» в нём
        // никто не находит.
        let appMenu = NSMenu(title: "EliteSIP")
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
        windowMenu.addItem(
            withTitle: "История звонков",
            action: #selector(showCallHistoryWindow(_:)),
            keyEquivalent: "y"
        )
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }
}
