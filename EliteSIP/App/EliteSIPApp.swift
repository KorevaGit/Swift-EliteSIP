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

    /// Окно первоначальной настройки (этап 9).
    ///
    /// Живёт только на первом запуске и после сброса машины, стоит до панели и
    /// вместо неё. Закрытие крестиком завершает приложение: мастер закрыт
    /// административным пропуском, и обойти его одним щелчком по красной кнопке
    /// значило бы не иметь пропуска вовсе.
    private var firstRunWindow: NSWindow?

    /// Черновик мастера. Ссылка нужна сильная: окно держит вью, а состояние
    /// живёт снаружи — как `administrationRouter` у «Управления».
    private var firstRunFlow: FirstRunFlow?

    /// Значок в строке меню. Заводится при запуске и живёт до выхода.
    private var statusItemController: StatusItemController?

    /// Меню телефона в строке меню и под правой кнопкой значка. Ссылки нужны
    /// сильные: `NSMenu.delegate` слабый, и без них меню перестало бы
    /// обновляться сразу после запуска.
    private var phoneMenuInBar: PhoneMenuController?
    private var phoneMenuInStatusItem: PhoneMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Тема — до первого окна: иначе панель успевает нарисоваться в
        // системном оформлении и перекрашивается уже на глазах.
        NSApp.appearance = model.settings.appearance.appKitAppearance
        // То же и с корпусом «Управления»: дальше зеркало держит `AppModel`, но
        // первое значение `didSet` не приносит — он срабатывает на изменение, а
        // не на загрузку.
        Theme.Chrome.prefersPlain = model.settings.plainChrome
        #if DEBUG
        // Тот же режим ключом — посмотреть его, не трогая чужие настройки и не
        // перезапуская приложение из «Управления». Ставится в то же зеркало, а
        // не проверяется отдельно внутри `Chrome`: иначе ключ включал бы «не
        // совсем» обычный вариант, и проверяли бы мы не то, что увидит человек.
        //   EliteSIP.app/Contents/MacOS/EliteSIP --legacy-chrome
        if ProcessInfo.processInfo.arguments.contains("--legacy-chrome") {
            Theme.Chrome.prefersPlain = true
        }
        #endif
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
        // Каталог устройств — до первого окна и на всё время работы: раздел
        // «Звук» обязан открываться с готовым списком, а не досчитывать его на
        // глазах у человека. См. `AppModel.startWatchingAudioDevices`.
        model.startWatchingAudioDevices()
        makePhoneMenus()
        NSApp.mainMenu = makeMainMenu()
        makeStatusItem()

        // Мастер первоначальной настройки стоит **до** панели и вместо неё:
        // свежая машина иначе открывает панель с пустым добавочным и без единого
        // слова о том, что делать дальше (этап 9).
        #if DEBUG
        // Посмотреть мастер, не стирая настоящие настройки. Показывает окно и
        // ничего не применяет само — дойти до «Далее» на экране 2 всё равно
        // нужно с пропуском.
        //   EliteSIP.app/Contents/MacOS/EliteSIP --first-run
        //
        // Иначе увидеть мастер можно только на машине без файла настроек, то
        // есть удалив рабочую конфигурацию проверяющего. Тот же довод, по
        // которому ключами открываются «Управление» и оба оформления.
        if ProcessInfo.processInfo.arguments.contains("--first-run") {
            showFirstRunWindow()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        #endif

        if model.firstRun != .passed {
            showFirstRunWindow()
            NSApp.activate(ignoringOtherApps: true)
            // На финале машина уже настроена и перезапущена: регистрацию
            // поднимаем, чтобы обещание «телефон зарегистрирован» на последнем
            // экране было правдой, а не вежливостью.
            if model.firstRun == .awaitingFinale { model.startAutoConnect() }
            return
        }

        showPhoneWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        #if DEBUG
        // Снимок «Управления» — по ключу, а не пятью щелчками через панель,
        // настройки и предупреждение на входе. Сверять вид сайдбара приходится
        // каждый раз в обеих темах, и путь до окна дороже самой сверки.
        //   EliteSIP.app/Contents/MacOS/EliteSIP --administration
        if ProcessInfo.processInfo.arguments.contains("--administration") {
            showAdministrationWindow(nil)
        }
        #endif
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
            alert.messageText = NSLocalizedString("Идёт разговор", comment: "вопрос при выходе во время разговора")
            alert.informativeText = NSLocalizedString(
                "Выход завершит его и снимет регистрацию.",
                comment: "вопрос при выходе во время разговора"
            )
            alert.addButton(withTitle: NSLocalizedString("Завершить и выйти", comment: "кнопка выхода во время разговора"))
            alert.addButton(withTitle: NSLocalizedString("Отмена", comment: "кнопка"))
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

    // MARK: - Меню телефона

    /// Что умеет меню телефона — одинаково для обоих его мест.
    private func phoneMenuActions() -> PhoneMenuController.Actions {
        PhoneMenuController.Actions(
            isPanelVisible: { [weak self] in self?.phoneWindow?.isVisible == true },
            togglePanel: { [weak self] in self?.togglePhoneWindow(nil) },
            showHistory: { [weak self] in self?.showCallHistoryWindow(nil) },
            showSettings: { [weak self] in self?.showSettingsWindow(nil) },
            toggleOffline: { [weak self] in self?.toggleOffline() }
        )
    }

    /// Меню телефона заводится дважды одним кодом: заголовком в строке меню и
    /// под правой кнопкой значка.
    ///
    /// Два экземпляра, а не один на два места: `NSMenu` нельзя показать в двух
    /// местах одновременно, и разница в составе всё равно есть — «Завершить»
    /// нужен только значку (в строке меню он стоит в меню приложения).
    private func makePhoneMenus() {
        phoneMenuInBar = PhoneMenuController(
            title: NSLocalizedString("Телефон", comment: "меню приложения"),
            model: model,
            actions: phoneMenuActions(),
            showsQuit: false
        )
        phoneMenuInStatusItem = PhoneMenuController(
            title: "EliteSIP",
            model: model,
            actions: phoneMenuActions(),
            showsQuit: true
        )
    }

    // MARK: - Значок в строке меню

    private func makeStatusItem() {
        guard let menu = phoneMenuInStatusItem?.menu else { return }

        statusItemController = StatusItemController(
            model: model,
            menu: menu,
            onLeftClick: { [weak self] in self?.togglePhoneWindow(nil) }
        )
        observeWindowsForActivationPolicy()
    }

    /// Уход с линии и возврат — то же, что пункт в капсуле панели.
    ///
    /// Возврат идёт через активный профиль, а не через «просто подключиться»:
    /// `goOnline` отвечает на «под каким номером работать», и другого ответа у
    /// значка нет — списка профилей в его меню нет намеренно.
    private func toggleOffline() {
        Task { @MainActor in
            if model.isOfflineByChoice {
                await model.goOnline(profile: model.activeProfileID)
            } else {
                await model.goOffline()
            }
        }
    }

    // MARK: - Форма приложения

    /// Окна, по которым считается форма приложения.
    ///
    /// Окна входящего звонка здесь нет намеренно: считай оно за окно — иконка
    /// появлялась бы в Dock на каждый звонок и уходила после него, то есть
    /// мигала бы в углу экрана несколько раз в час.
    private var windowsCountedForPolicy: [NSWindow?] {
        [phoneWindow, settingsWindow, administrationWindow, callHistoryWindow, sipTraceWindow]
    }

    /// Приложение обычное, пока открыто хоть одно окно, и живёт в строке меню,
    /// когда не открыто ни одного.
    ///
    /// **Строка меню и иконка в Dock — одно состояние, а не два.** `.regular`
    /// даёт и то и другое, `.accessory` не даёт ничего: приложения со строкой
    /// меню, но без иконки в Dock, не существует. Поэтому `LSUIElement` в
    /// `Info.plist` не ставится вовсе — он задал бы стартовую политику, а
    /// стартуем мы с открытой панелью, то есть уже обычным приложением.
    ///
    /// Панель в счёт входит: панель на экране и есть «приложение развёрнуто»,
    /// со всеми признаками обычного — Dock, ⌘Tab и настоящая строка меню, в
    /// которой работает ⌘V в поле перевода. Значок при этом способ свернуться
    /// туда, где приложение не мешает.
    private func updateActivationPolicy() {
        // Свёрнутое окно считается открытым: `isVisible` у него false, а
        // развернуть его можно только из Dock — уйдя в `.accessory`, мы
        // забрали бы у человека единственную дорогу назад.
        let hasWindow = windowsCountedForPolicy.contains { window in
            guard let window else { return false }
            return window.isVisible || window.isMiniaturized
        }

        let policy: NSApplication.ActivationPolicy = hasWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }

        NSApp.setActivationPolicy(policy)

        // Переход в обычное приложение не выводит его вперёд сам: без этого
        // окно открывается за чужим, и человек, нажавший «Настройки», видит
        // прежнюю программу.
        if policy == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Закрытие любого окна пересчитывает форму.
    ///
    /// Открытие пересчитывается явно, в самих методах показа. Первый заход
    /// ловил и открытие тоже — по `didBecomeKey`, — и на этом сломался:
    /// показ панели из `.accessory` не активирует приложение, окно ключевым не
    /// становится, уведомление не приходит. Панель оказывалась на экране, а
    /// приложение оставалось без Dock и без строки меню, то есть без ⌘V в поле
    /// перевода.
    private func observeWindowsForActivationPolicy() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { _ in
            // Через очередь: в `willClose` окно ещё видимо, и счёт, сделанный
            // сразу, нашёл бы закрывающееся окно открытым.
            Task { @MainActor [weak self] in self?.updateActivationPolicy() }
        }
    }

    // MARK: - Окна

    /// Левый щелчок по значку.
    ///
    /// Переключатель считает не «открыта ли панель», а «видно ли её»:
    /// заслонённая чужим окном панель сперва выходит вперёд и прячется только
    /// следующим щелчком. Иначе человек, у которого панель лежит под браузером,
    /// жмёт значок — и панель исчезает, то есть кнопка «показать» её спрятала.
    @objc private func togglePhoneWindow(_ sender: Any?) {
        guard let phoneWindow, phoneWindow.isVisible else {
            showPhoneWindow(nil)
            return
        }

        if NSApp.isActive, phoneWindow.isKeyWindow {
            phoneWindow.close()
        } else {
            NSApp.activate(ignoringOtherApps: true)
            phoneWindow.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func showPhoneWindow(_ sender: Any?) {
        // Форма приложения пересчитывается на выходе, на всех путях сразу:
        // у методов показа есть ранние возвраты, и вызов в конце тела
        // пропустил бы как раз тот случай, когда окно уже заведено.
        defer { updateActivationPolicy() }

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
            // Без `.miniaturizable`: свёрнутая в Dock панель — всё ещё
            // открытое окно, то есть иконка из Dock не уходит. Рядом оказались
            // бы два похожих жеста с разным результатом — «свернуть» и
            // «закрыть, уйдя в строку меню», — и разницу человек узнавал бы
            // только опытом. Убрана жёлтая, а не красная: у панели остаётся
            // ровно один способ убраться с глаз, и он же сворачивает
            // приложение в строку меню.
            styleMask: [.titled, .closable, .fullSizeContentView],
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
        window.title = NSLocalizedString("Экран вызова", comment: "заголовок окна панели")
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
        restoreFrame(
            of: window,
            autosaveName: Self.phoneWindowAutosaveName,
            defaultContentSize: CGSize(
                width: Theme.Metrics.panelWidth,
                height: Theme.Metrics.panelInitialHeight
            )
        )

        phoneWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Первоначальная настройка

    /// Показывает мастер. Кадр не запоминается: окно одноразовое, и «там, где
    /// оставили» у него не бывает.
    private func showFirstRunWindow() {
        defer { updateActivationPolicy() }

        if let firstRunWindow {
            firstRunWindow.makeKeyAndOrderFront(nil)
            return
        }

        let flow = FirstRunFlow(presets: Provisioning.factoryPresets)
        // На финал попадают уже после перезапуска: экраны до него пройдены, и
        // возвращаться туда некуда — всё применено и записано.
        if model.firstRun == .awaitingFinale { flow.step = .finale }
        firstRunFlow = flow

        let window = NSWindow(
            contentRect: CGRect(
                origin: .zero,
                size: CGSize(
                    width: Theme.Metrics.firstRunWidth,
                    height: Theme.Metrics.firstRunHeight
                )
            ),
            // Ни `.resizable`, ни `.miniaturizable`: размер один на все пять
            // экранов, а свернуть мастер в Dock значило бы спрятать единственное
            // окно приложения, которое нельзя обойти.
            //
            // `.fullSizeContentView` обязателен вместе с прозрачным окном — та же
            // ловушка, что у панели, и живой снимок 17 августа 2026 в неё
            // угодил: без него содержимое начинается под полосой заголовка, сама
            // полоса остаётся без фона, и светофор повисает над рабочим столом,
            // оторванный от окна.
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString("Настройка EliteSIP", comment: "заголовок окна первого запуска")
        window.collectionBehavior.insert(.fullScreenNone)
        // Полоса заголовка без своего фона и без названия: у окна знакомства
        // содержимое начинается от самого верха, и подпись «Настройка EliteSIP»
        // над короной повторяла бы то, что корона и говорит. Название остаётся у
        // окна — оно нужно ⌘Tab и Mission Control.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Пара обязательна вместе с материалом `.behindWindow`: иначе под ним
        // окажется непрозрачный фон окна, и размывать материалу будет нечего.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: withEnvironment(FirstRunWindowView(flow: flow))
        )
        window.center()
        window.delegate = self

        firstRunWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    /// Сброс машины: закрыть всё и позвать мастер.
    ///
    /// Не `private`: зовётся из `AppModel.resetMachine` через цепочку ответчиков —
    /// окнами владеет делегат, а модель о них не знает.
    ///
    /// Окна закрываются все, и это не уборка для красоты. «Управление», из
    /// которого сброс и запустили, осталось бы стоять над машиной без настроек;
    /// панель показывала бы пустой добавочный; история — только что стёртый
    /// список. Мастер при этом обязан быть единственным окном: он закрыт
    /// пропуском, и оставить рядом открытую дверь в настройки значит его обойти.
    @objc func showFirstRunAfterReset(_ sender: Any?) {
        // Черновик уже закрыт самим сбросом, поэтому вопросов о несохранённом
        // здесь не задаём: решение принято, и спрашивать о правках, которых
        // больше нет, — пугать без причины.
        for window in [administrationWindow, settingsWindow, callHistoryWindow, sipTraceWindow, phoneWindow] {
            guard let window else { continue }
            window.delegate = nil
            window.close()
        }
        administrationWindow = nil
        administrationRouter = nil
        settingsWindow = nil
        settingsRouter = nil
        callHistoryWindow = nil
        sipTraceWindow = nil
        phoneWindow = nil

        showFirstRunWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Финал мастера: закрыть окно и открыть панель.
    ///
    /// Не `private`: зовётся из SwiftUI через цепочку ответчиков, как открытие
    /// настроек и истории. Ссылка гасится **до** `close()` — иначе
    /// `windowWillClose` принял бы этот путь за закрытие крестиком и завершил
    /// приложение вместо того, чтобы показать панель.
    @objc func finishFirstRunWindow(_ sender: Any?) {
        if let firstRunWindow {
            self.firstRunWindow = nil
            firstRunWindow.delegate = nil
            firstRunWindow.close()
        }
        firstRunFlow = nil

        showPhoneWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.startAutoConnect()
    }

    /// Имя, под которым AppKit хранит кадр панели между запусками.
    private static let phoneWindowAutosaveName = "EliteSIPPhonePanel"
    /// То же для окна «Управление».
    private static let administrationWindowAutosaveName = "EliteSIPAdministration"
    /// То же для окна настроек. Появилось вместе с боковым списком: до него
    /// окно было фиксированной ширины и высоты по содержимому — запоминать было
    /// нечего.
    private static let settingsWindowAutosaveName = "EliteSIPSettings"

    /// Возвращает окно туда, где его оставили.
    ///
    /// Место оператор выбирает один раз, а центр экрана — это место, выбранное
    /// за него. Хранит кадр AppKit сам, от нас нужно только имя, размер по
    /// умолчанию для первого запуска и проверка на исчезнувший монитор.
    ///
    /// Панели важна только позиция: высоту она считает сама из числа макросов и
    /// ставит окну через `PanelHeight`. «Управлению» важны обе величины —
    /// разделы просят от 245 до 730 точек высоты, угодить всем одним числом
    /// нельзя, и последнее слово остаётся за человеком.
    private func restoreFrame(
        of window: NSWindow,
        autosaveName: String,
        defaultContentSize: CGSize
    ) {
        let restored = window.setFrameUsingName(autosaveName)
        window.setFrameAutosaveName(autosaveName)

        // Сохранённый кадр мог остаться от внешнего монитора, которого сейчас
        // нет: ноутбук отключили от дока, и окно уехало за пределы
        // единственного экрана — то есть исчезло. Проверяем не «попало ли оно
        // на экран целиком», а «видно ли его вообще»: частично уехавшее окно
        // человек дотащит сам, а полностью пропавшее — нет.
        let isVisible = NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame) }
        guard restored, isVisible else {
            window.setContentSize(defaultContentSize)
            window.center()
            return
        }
    }

    /// Собирает окно с боковым списком разделов.
    ///
    /// Таких окна два — «Управление» и настройки менеджера, — и рецепт у них
    /// один. Он был выведен для «Управления» и стоил нескольких итераций на
    /// живом окне; когда тот же вид понадобился настройкам, копия означала бы,
    /// что половину этих итераций рано или поздно пройдут заново и придут к
    /// другому ответу.
    ///
    /// Оформления два, и выбирается оно один раз — вызывающей стороной:
    /// `Theme.Chrome.usesLiquidGlass`. Половинчатого стекла не бывает — см. тот
    /// же `Chrome`, там записано, из чего оно складывается и почему без одной
    /// части получается не «почти стекло», а сломанное окно.
    ///
    /// - Parameters:
    ///   - isGlass: собирать ли стеклянный корпус. Приходит снаружи и тем же
    ///     значением уходит половинам в окружение: настройку «Без стекла»
    ///     правят в самом окне, и вёрстка не должна перестраиваться под уже
    ///     собранной рамкой.
    ///   - toolbarIdentifier: имя пустой панели инструментов. Своё у каждого
    ///     окна — AppKit хранит по нему состояние панели.
    private func makeSidebarWindow<Sidebar: View, Content: View>(
        title: String,
        isGlass: Bool,
        toolbarIdentifier: String,
        contentMinSize: CGSize,
        sidebar sidebarView: Sidebar,
        content contentView: Content
    ) -> NSWindow {
        let sidebarController = NSHostingController(rootView: sidebarView)
        let contentController = NSHostingController(rootView: contentView)

        // Безопасная зона обеих половин — своя, не системная.
        //
        // Только в стеклянном варианте: там системная зона меряется по всей
        // полосе заголовка вместе с панелью инструментов и даёт 66 точек, а
        // панель пустая и стоит ради размытия. В обычном варианте окно под
        // полосу не заходит, системной зоны нет вовсе, и снимать нечего.
        if isGlass, #available(macOS 13.3, *) {
            sidebarController.safeAreaRegions = []
            contentController.safeAreaRegions = []
        }

        // Слева — сайдбар со стеклом или обычная половина с разделителем.
        //
        // `NSSplitViewItem.sidebar` даёт материал и плавающую вставку; без
        // стекла материал превращается в блёклую подложку без границы, и список
        // сливается с содержимым. Обычная половина вместо него отделена той же
        // чертой, что делит любое системное окно надвое.
        let sidebar = isGlass
            ? NSSplitViewItem(sidebarWithViewController: sidebarController)
            : NSSplitViewItem(viewController: sidebarController)
        // Ширина фиксированная: список не тянется вместе с окном, иначе на
        // широком мониторе короткие названия разъезжаются по полосе в треть
        // экрана. Схлопывание выключено — разделы обязаны быть видны все сразу.
        sidebar.minimumThickness = Theme.Metrics.sidebarWidth
        sidebar.maximumThickness = Theme.Metrics.sidebarWidth
        sidebar.canCollapse = false
        if #available(macOS 11.0, *) {
            // Черта под полосой заголовка есть, и только в обычном оформлении.
            //
            // Под стеклом её быть не может: содержимое уходит под полосу, и
            // линия резала бы его пополам. Без стекла — наоборот: полоса
            // прозрачная, своего фона у неё нет, и без черты верх окна
            // расплывается, а светофор повисает над содержимым.
            //
            // Ставится обеим половинам одинаково — иначе линия рисуется над
            // одной и обрывается на середине окна. Ровно это и было видно, пока
            // сайдбар был стеклянной вставкой, а содержимое обычным.
            sidebar.titlebarSeparatorStyle = isGlass ? .none : .line
        }
        if isGlass, #available(macOS 11.0, *) {
            // Сайдбар идёт от самого верха окна, а не от низа полосы заголовка:
            // светофор обязан стоять внутри него, а строки — уходить под
            // светофор, а не обрываться выше него.
            //
            // Значение стоит по умолчанию, но записано явно: от него зависит
            // всё остальное в этом окне, и молчаливое значение по умолчанию —
            // плохая опора для того, что при его смене развалится.
            sidebar.allowsFullHeightLayout = true
        }

        let content = NSSplitViewItem(viewController: contentController)
        if #available(macOS 11.0, *) {
            content.titlebarSeparatorStyle = isGlass ? .none : .line
        }

        let split = NSSplitViewController()
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(content)

        // `.fullSizeContentView` — только под стекло: он и есть то, чем
        // содержимое заводится под полосу заголовка. В обычном варианте он
        // означал бы прозрачную полосу без фона, под которую резко ныряет
        // список, — там нужна ровно обычная полоса, а содержимое под ней.
        var styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        if isGlass { styleMask.insert(.fullSizeContentView) }

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: contentMinSize),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        // Название у окна есть, но не показывается.
        //
        // Имя открытого раздела в полосе заголовка повторяло выбранную строку
        // сайдбара в полутора сантиметрах от неё и при этом занимало верх
        // содержимого целиком. Имя нужно там, где сайдбара не видно, —
        // в переключателе окон и в Mission Control, — и `title` его туда даёт
        // и без `titleVisibility`. Сам заголовок по-прежнему меняется вместе с
        // разделом (`WindowTitle` в содержимом).
        window.title = title
        window.titleVisibility = .hidden
        // Полноэкранного режима у окон приложения нет.
        //
        // Не вкусовщина, а починка: замер живого окна 14 августа 2026 показал,
        // что «Управление» на весь экран разваливается — содержимое прижимается
        // к нижнему краю, сверху остаётся около 360 точек пустоты, а низ
        // раздела уезжает за кромку и прокруткой не достаётся. Причина в том,
        // что верхний отступ содержимое считает само (`contentTopInset`), а
        // полосы заголовка, от которой он отсчитан, в полноэкранном режиме нет
        // вовсе.
        //
        // Чинить сам отступ смысла нет: софтфон на весь экран не разворачивают
        // ни разу за смену — он стоит поверх CRM, а не вместо неё. Зелёная
        // кнопка при этом не пропадает, а возвращается к обычному разворачиванию
        // по содержимому, где полоса заголовка остаётся на месте.
        window.collectionBehavior.insert(.fullScreenNone)
        // Прозрачная полоса в обоих оформлениях, но по разным причинам. Под
        // стеклом — чтобы содержимое ушло под неё. Без стекла — чтобы у полосы
        // не было своего фона: с непрозрачной оставался светлый волосок на
        // стыке с содержимым, и он тянулся только над правой половиной, потому
        // что левая своим фоном его перекрывала. Полоса без фона показывает фон
        // окна, стыка нет вовсе.
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentViewController = split
        window.contentMinSize = contentMinSize
        if #available(macOS 11.0, *) {
            window.titlebarSeparatorStyle = isGlass ? .none : .line
        }

        // Пустая панель инструментов — ради двух вещей, которых без неё нет.
        //
        // Своих кнопок в полосе заголовка у этих окон нет и не будет: и
        // сохранение с отменой, и дверь в «Управление» живут внизу, у
        // содержимого. Но полоса с панелью инструментов — это не только место
        // под кнопки:
        //
        // 1. **Размытие на кромке прокрутки.** Содержимое, уезжающее под
        //    светофор, macOS размывает не само по себе — размытие даёт полоса.
        //    Без панели прозрачная полоса остаётся дыркой, и строки проезжают
        //    под светофором резкими.
        // 2. **Полная высота сайдбара.** Замер живого окна: без панели сайдбар
        //    получает высоту окна за вычетом полосы, с `.unifiedCompact` —
        //    тоже, и только с `.unified` он идёт во всю высоту, как в Finder.
        //    То есть стиль здесь не про вид панели, а про то, где кончается
        //    сайдбар.
        //
        // Полоса при этом остаётся пустой и высокой, но её высоту содержимое не
        // отдаёт: безопасную зону обе половины считают сами (см.
        // `Theme.Metrics.sidebarTopInset`), а полоса им нужна как источник
        // размытия.
        //
        // В обычном оформлении панели нет вовсе, и это не потеря, а отказ от
        // вреда: оба довода выше существуют только под стекло, а без него пустая
        // `NSToolbar` даёт ровно то, чем и является, — пустую полосу поперёк
        // окна.
        if isGlass, #available(macOS 11.0, *) {
            let toolbar = NSToolbar(identifier: toolbarIdentifier)
            toolbar.allowsUserCustomization = false
            toolbar.showsBaselineSeparator = false
            window.toolbar = toolbar
            window.toolbarStyle = .unified
        }

        // Ещё раз после показа, и это не суеверие: `NSSplitViewController`
        // выставляет стиль черты сам во время раскладки, по своим половинам, и
        // делает это уже после того, как окно собрано. Значение, проставленное
        // при сборке, он затирает — черта над содержимым возвращалась именно
        // так. Блок асинхронный, поэтому выполнится после того, как вызывающая
        // сторона окно покажет.
        if #available(macOS 11.0, *) {
            DispatchQueue.main.async {
                let style: NSTitlebarSeparatorStyle = isGlass ? .none : .line
                window.titlebarSeparatorStyle = style
                split.splitViewItems.forEach { $0.titlebarSeparatorStyle = style }
            }
        }

        return window
    }

    /// Не `private`: то же действие посылает кнопка на панели через
    /// `NSApp.sendAction(_:to:from:)` с пустой целью. Делегат приложения стоит в
    /// цепочке ответчиков, поэтому окно открывает один и тот же код — и пункт
    /// меню, и кнопка.
    @objc func showSettingsWindow(_ sender: Any?) {
        // Форма приложения пересчитывается на выходе, на всех путях сразу:
        // у методов показа есть ранние возвраты, и вызов в конце тела
        // пропустил бы как раз тот случай, когда окно уже заведено.
        defer { updateActivationPolicy() }

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

        // С 14 августа 2026 окно собрано тем же рецептом, что «Управление»:
        // боковой список разделов, полоса низа под действием над всем окном и
        // те же два оформления. Прежняя раскладка — одна страница фиксированной
        // ширины с высотой по содержимому — держалась ровно до тех пор, пока
        // страница оставалась короткой; после самопроверки голоса и разбора
        // рингтона на три кнопки нижние разделы стали уходить за край экрана
        // ноутбука.
        //
        // Ушло вместе с ней и прозрачное окно с материалом под всей вёрсткой:
        // под стеклом материал даёт сайдбарная половина сплита, а рисовать
        // второй поверх — тот самый двойной материал, из-за которого стекло
        // выходит мутным. Ловушка с безопасной зоной, стоившая той раскладке
        // итерации, здесь не срабатывает: размер у окна свой и меняется мышью, а
        // не выводится из идеальной высоты содержимого.
        let router = ManagerRouter()
        settingsRouter = router

        let isGlass = Theme.Chrome.usesLiquidGlass

        let window = makeSidebarWindow(
            title: NSLocalizedString("Настройки EliteSIP", comment: "заголовок окна настроек"),
            isGlass: isGlass,
            toolbarIdentifier: "EliteSIPSettings",
            contentMinSize: CGSize(
                width: Theme.Metrics.settingsMinWidth,
                height: Theme.Metrics.settingsMinHeight
            ),
            sidebar: withEnvironment(ManagerSidebarView().environmentObject(router))
                .environment(\.windowUsesGlass, isGlass),
            content: withEnvironment(ManagerContentView().environmentObject(router))
                .environment(\.windowUsesGlass, isGlass)
        )

        // Кадр помнит AppKit — по тем же доводам, что у «Управления»: окно
        // стало растяжимым, а разделы просят разной высоты.
        restoreFrame(
            of: window,
            autosaveName: Self.settingsWindowAutosaveName,
            defaultContentSize: CGSize(
                width: Theme.Metrics.settingsMinWidth,
                height: Theme.Metrics.settingsMinHeight
            )
        )
        // Ради одного: закрытие окна гасит административный режим (M7c).
        window.delegate = self

        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    /// Владелец выбранного раздела настроек.
    ///
    /// Живёт у делегата по той же причине, что и `administrationRouter`: окно
    /// собрано `NSSplitViewController`, и его половины — два разных
    /// `NSHostingController` с двумя деревьями SwiftUI.
    private var settingsRouter: ManagerRouter?

    /// Открывает историю звонков.
    ///
    /// Не `private` по той же причине, что и настройки: то же самое действие
    /// шлёт кнопка на панели через цепочку ответчиков, и второго кода,
    /// умеющего открывать это окно, в приложении нет.
    @objc func showCallHistoryWindow(_ sender: Any?) {
        // Форма приложения пересчитывается на выходе, на всех путях сразу:
        // у методов показа есть ранние возвраты, и вызов в конце тела
        // пропустил бы как раз тот случай, когда окно уже заведено.
        defer { updateActivationPolicy() }

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
        window.title = NSLocalizedString("История звонков", comment: "заголовок окна истории")
        window.titleVisibility = .visible
        // Полноэкранного режима нет — по той же причине, что у «Управления»
        // и настроек, см. `makeSidebarWindow`.
        window.collectionBehavior.insert(.fullScreenNone)
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

    /// Владелец выбранного раздела «Управления».
    ///
    /// Живёт у делегата, а не во вью: окно собрано `NSSplitViewController`, и
    /// его половины — два разных `NSHostingController` с двумя деревьями
    /// SwiftUI. Общее состояние им негде держать, кроме как снаружи.
    private var administrationRouter: AdministrationRouter?

    /// Открывает «Управление». Вызывается кнопкой уже после проверки пароля.
    @objc func showAdministrationWindow(_ sender: Any?) {
        // Форма приложения пересчитывается на выходе, на всех путях сразу:
        // у методов показа есть ранние возвраты, и вызов в конце тела
        // пропустил бы как раз тот случай, когда окно уже заведено.
        defer { updateActivationPolicy() }

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

        let router = AdministrationRouter()
        administrationRouter = router

        let isGlass = Theme.Chrome.usesLiquidGlass

        let window = makeSidebarWindow(
            title: NSLocalizedString("Управление EliteSIP", comment: "заголовок окна «Управление»"),
            isGlass: isGlass,
            toolbarIdentifier: "EliteSIPAdministration",
            contentMinSize: CGSize(
                width: Theme.Metrics.adminMinWidth,
                height: Theme.Metrics.adminMinHeight
            ),
            sidebar: withEnvironment(AdministrationSidebarView().environmentObject(router))
                .environment(\.windowUsesGlass, isGlass),
            content: withEnvironment(AdministrationContentView().environmentObject(router))
                .environment(\.windowUsesGlass, isGlass)
        )

        // Кадр помнит AppKit: разделы просят от 245 до 730 точек высоты, одним
        // числом всем не угодить, и последнее слово остаётся за тем, кто окно
        // тянул.
        restoreFrame(
            of: window,
            autosaveName: Self.administrationWindowAutosaveName,
            defaultContentSize: CGSize(
                width: Theme.Metrics.adminIdealWidth,
                height: Theme.Metrics.adminIdealHeight
            )
        )
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
        // Форма приложения пересчитывается на выходе, на всех путях сразу:
        // у методов показа есть ранние возвраты, и вызов в конце тела
        // пропустил бы как раз тот случай, когда окно уже заведено.
        defer { updateActivationPolicy() }

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
        window.title = NSLocalizedString("Трасса SIP", comment: "заголовок окна трассировки")
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
    /// Перезапуск приложения — единственный способ сменить оформление целиком.
    ///
    /// Стекло выбирается при сборке каждого окна и при первой отрисовке каждой
    /// поверхности. Панель софтфона висит открытой весь рабочий день, окно
    /// входящего создаётся заранее, а корпус «Управления» задан рамкой окна —
    /// перекрасить это на лету значит пересобрать всё, что сейчас на экране,
    /// вместе с несохранёнными правками внутри. Перезапуск делает то же самое
    /// честно и за одну секунду.
    ///
    /// Согласие спрашивает вызывающая сторона, до того как позвать сюда: здесь
    /// решение уже принято. Настройки к этому моменту обязаны быть на диске —
    /// иначе перезапуск вернёт приложение к прежнему оформлению и потеряет
    /// правку, ради которой его и затеяли.
    ///
    /// `open -n` запускается **до** завершения: после `terminate` процесса уже
    /// нет и запускать новый некому. Регистрация при этом снимается и
    /// поднимается заново — цена перезапуска, о которой сказано в
    /// предупреждении.
    @objc func relaunchApplication(_ sender: Any?) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundleURL.path]
        do {
            try task.run()
        } catch {
            // Не молчим: без нового процесса «перезапуск» превратился бы в
            // выход, а оператор остался бы без софтфона на линии.
            model.append(level: .error, message: "не удалось перезапустить приложение: \(error)")
            return
        }
        NSApp.terminate(nil)
    }

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
        alert.messageText = NSLocalizedString("Настройки изменены", comment: "вопрос при закрытии «Управления»")
        alert.informativeText = NSLocalizedString("""
            Сохранение объявит настройки этой машины локальными: их задаёт \
            администратор, а не файл конфигурации. Это будет записано в журнал.
            """, comment: "вопрос при закрытии «Управления»")
        alert.addButton(withTitle: NSLocalizedString("Сохранить", comment: "кнопка"))
        alert.addButton(withTitle: NSLocalizedString("Не сохранять", comment: "кнопка"))
        alert.addButton(withTitle: NSLocalizedString("Отмена", comment: "кнопка"))

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

        // Красная кнопка мастера завершает приложение.
        //
        // Иначе мастер, закрытый административным пропуском, обходится одним
        // щелчком — и весь смысл пропуска пропадает: машина остаётся с пустым
        // профилем и с «Управлением», открытым всякому. Путь «прошёл до конца»
        // сюда не попадает: `finishFirstRunWindow` гасит ссылку до `close()`.
        if closing === firstRunWindow {
            firstRunWindow = nil
            firstRunFlow = nil
            NSApp.terminate(nil)
            return
        }

        if closing === settingsWindow {
            // Раздел не сбрасывается: окно живёт между показами
            // (`isReleasedWhenClosed = false`), и открывший настройки застаёт
            // тот раздел, на котором закрыл, — как в любом окне с сайдбаром.
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
            administrationRouter = nil
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
            withTitle: NSLocalizedString("О программе EliteSIP", comment: "пункт меню приложения"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: NSLocalizedString("Настройки…", comment: "пункт меню приложения"),
            action: #selector(showSettingsWindow(_:)),
            keyEquivalent: ","
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: NSLocalizedString("Скрыть EliteSIP", comment: "пункт меню приложения"),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthers = appMenu.addItem(
            withTitle: NSLocalizedString("Скрыть остальные", comment: "пункт меню приложения"),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: NSLocalizedString("Показать все", comment: "пункт меню приложения"),
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: NSLocalizedString("Завершить EliteSIP", comment: "пункт меню приложения"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: NSLocalizedString("Правка", comment: "меню"))
        editMenu.addItem(
            withTitle: NSLocalizedString("Отменить", comment: "пункт меню «Правка»"),
            action: Selector(("undo:")),
            keyEquivalent: "z"
        )
        let redo = editMenu.addItem(
            withTitle: NSLocalizedString("Повторить", comment: "пункт меню «Правка»"),
            action: Selector(("redo:")),
            keyEquivalent: "z"
        )
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: NSLocalizedString("Вырезать", comment: "пункт меню «Правка»"),
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        editMenu.addItem(
            withTitle: NSLocalizedString("Скопировать", comment: "пункт меню «Правка»"),
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        editMenu.addItem(
            withTitle: NSLocalizedString("Вставить", comment: "пункт меню «Правка»"),
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        editMenu.addItem(
            withTitle: NSLocalizedString("Выбрать все", comment: "пункт меню «Правка»"),
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // «Телефон» — свой раздел между системными «Правкой» и «Окном». До него
        // история пряталась в «Окне», а настройки — в меню приложения: оба
        // места системные и правильные, но человек, ищущий их глазами, доходил
        // туда не с первого раза.
        if let phoneMenu = phoneMenuInBar?.menu {
            let phoneItem = NSMenuItem()
            phoneItem.submenu = phoneMenu
            mainMenu.addItem(phoneItem)
        }

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: NSLocalizedString("Окно", comment: "меню"))
        windowMenu.addItem(
            withTitle: NSLocalizedString("Свернуть", comment: "пункт меню «Окно»"),
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(
            withTitle: NSLocalizedString("Закрыть", comment: "пункт меню «Окно»"),
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }
}
