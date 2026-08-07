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

    /// Окно живой трассы SIP.
    ///
    /// Своё окно с этапа 5: внутри «Диагностики» трассу нельзя было ни
    /// растянуть под длинные строки, ни оставить открытой на время звонка — а
    /// нужна она ровно тогда.
    private var sipTraceWindow: NSWindow?

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
        // Название рисует окно. Своё, нарисованное вёрсткой, отсюда убрано:
        // системное никто не отключал, и два одинаковых заголовка лежали друг
        // на друге со сдвигом.
        //
        // «Экран вызова», а не «EliteSIP»: имя приложения и так стоит в меню, а
        // окон у него несколько, и заголовок должен отвечать на «какое это
        // окно», а не повторять, чьё оно.
        window.title = "Экран вызова"
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
        // Пока открыто «Управление», менеджерских настроек нет (этап 5).
        //
        // Оба окна пишут в один `settings`, запись придержана для всего сразу, и
        // «Отменить» молча откатило бы выбор, сделанный в соседнем окне. Раньше
        // ловушку можно было обойти дублем менеджерских настроек внутри
        // «Управления»; после удаления дублей обойти нельзя.
        //
        // Молчать при этом нельзя: непонятно погасшее ⌘, читается как поломка.
        // Поэтому вместо тишины вперёд выходит то окно, которое и мешает.
        if let administrationWindow {
            administrationWindow.makeKeyAndOrderFront(nil)
            return
        }

        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }

        // Тот же рецепт, что у панели, и по тем же причинам:
        //
        //   - `.fullSizeContentView` с прозрачной полосой заголовка — иначе у
        //     прозрачного окна полоса остаётся без материала, и светофор с
        //     названием повисают над чужим окном;
        //   - название рисует окно, а не вёрстка: под полосу заголовка у нас
        //     заходит только фон, поэтому системная надпись ложится на
        //     материал, а не повисает над чужим окном;
        //   - непрозрачным окно быть не должно, иначе размывать нечего.
        //
        // Не `.resizable`: ширина задана вёрсткой, высоту считает содержимое, и
        // тянуть окно не за что — страница одна и целиком видна.
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: CGSize(width: 560, height: 600)),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Видимость задана явно: она была выставлена в `.hidden`, пока
        // название рисовала вёрстка, и после возврата к системному заголовку
        // полоса осталась пустой — светофор без единой надписи рядом.
        window.title = "Настройки EliteSIP"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
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
        // Срез перечитывается до показа, и оба раза — и когда окно заводится, и
        // когда его открывают снова. Причина у первого случая не та же, что у
        // второго, и стоила она живого прогона: пока список обновлялся из
        // `onAppear`, первое открытие успевало разложить строки, получить новый
        // массив и уехать прокруткой в конец — то есть встречало оператора
        // самым старым звонком вместо самого свежего. Второй случай проще:
        // окно живёт между показами (`isReleasedWhenClosed = false`), а звонки
        // шли и пока оно было закрыто.
        model.reloadHistory()
        model.refreshHistoryDays()
        // Каждое открытие начинает список сверху: оператор пришёл смотреть
        // свежие звонки, а не то место, до которого долистал вчера.
        model.noteCallHistoryWindowOpened()

        if let callHistoryWindow {
            callHistoryWindow.makeKeyAndOrderFront(nil)
            return
        }

        // Тот же рецепт стекла, что у панели и у настроек: `.fullSizeContentView`
        // с прозрачной полосой заголовка, непрозрачность выключена, фон
        // прозрачный. Иначе окно осталось бы единственным непрозрачным из трёх,
        // и это читалось бы как забытое, а не как решение.
        //
        // Ловушка с безопасной зоной, которая стоила настройкам итерации, здесь
        // не срабатывает: у окна истории размер свой и меняется мышью, а не
        // выводится из идеальной высоты содержимого. Сходиться нечему.
        // Заводится шире своего минимума: на самом минимуме окно открывалось бы
        // впритык к ряду фильтров, а первое, что оператор делает в истории, —
        // читает строки, а не считает поля.
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: CGSize(width: 660, height: 460)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "История звонков"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
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

        // Менеджерское окно на это время закрывается: с этапа 5 его настроек в
        // «Управлении» нет вовсе, и оставленное открытым соседнее окно правило
        // бы тот же придержанный `settings` — а «Отменить» откатывало бы и его
        // правки, ничего об этом не сказав.
        if let settingsWindow {
            self.settingsWindow = nil
            settingsWindow.delegate = nil
            settingsWindow.close()
        }

        // Тот же рецепт стекла, что у панели, настроек и истории. Раньше окно
        // было единственным непрозрачным из четырёх, и это читалось как
        // забытое, а не как решение.
        //
        // Ловушка с безопасной зоной здесь не срабатывает по той же причине,
        // что и у истории: размер окна свой и меняется мышью, а не выводится из
        // идеальной высоты содержимого. Сходиться нечему.
        let window = NSWindow(
            contentRect: CGRect(
                origin: .zero,
                size: CGSize(
                    width: Theme.Metrics.adminIdealWidth,
                    height: Theme.Metrics.adminIdealHeight
                )
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Управление EliteSIP"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: withEnvironment(AdministrationWindowView())
        )
        // Размер задаётся после контроллера, а не в `contentRect`.
        //
        // `NSHostingController` пересчитывает окно под идеальный размер
        // содержимого, и тот равен минимуму: строки прижаты влево и растягивать
        // себя не просят. Живое окно из-за этого открывалось на 780 — то есть
        // всегда в одну колонку, и вторая контрольная ширина не показывалась
        // никому, пока окно не потянут мышью.
        window.setContentSize(
            CGSize(
                width: Theme.Metrics.adminIdealWidth,
                height: Theme.Metrics.adminIdealHeight
            )
        )
        window.center()
        window.delegate = self

        administrationWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    /// Открывает живую трассу SIP.
    ///
    /// Своим окном, а не разделом «Диагностики» (этап 5): трассу растягивают
    /// под длинные строки и держат открытой во время звонка, а раздел настроек
    /// закрывается вместе со всем черновиком.
    @objc func showSIPTraceWindow(_ sender: Any?) {
        if let sipTraceWindow {
            sipTraceWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: CGSize(width: 760, height: 420)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Трасса SIP"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: withEnvironment(SIPTraceWindowView())
        )
        window.center()
        window.delegate = self

        sipTraceWindow = window
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
            // Режим гасится здесь же: до этапа 5 его гасило закрытие
            // менеджерского окна, а оно теперь закрывается раньше — при входе
            // в «Управление». Без этого рабочее место оставалось бы открытым
            // после того, как администратор ушёл.
            model.lockAdministration()
        }

        // Трасса живёт сама по себе: её открывают ради звонка, а не ради
        // настроек, и закрывать её вместе с «Управлением» незачем.
        if closing === sipTraceWindow {
            sipTraceWindow = nil
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
