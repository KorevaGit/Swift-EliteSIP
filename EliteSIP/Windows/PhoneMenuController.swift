import AppKit

/// Меню телефона: состояние, окна и уход с линии.
///
/// Живёт в двух местах сразу — под правой кнопкой значка и в строке меню
/// заголовком «Телефон», — и собирается одним кодом на оба. Иначе два списка
/// расходятся: первый же пункт, добавленный в одно место и забытый в другом,
/// превращает «два входа в одно и то же» в «две разные программы».
///
/// Разница между входами ровно одна — «Завершить». У значка он обязателен: при
/// спрятанной панели приложение уходит в `.accessory`, строки меню нет, и ⌘Q
/// взяться неоткуда. В самой строке меню он стоит там, где ему и положено —
/// в меню приложения, и второй раз не нужен.
///
/// Пересборка — по `menuNeedsUpdate`, то есть перед каждым показом: состояние в
/// первой строке живое, а собранный однажды список показывал бы регистрацию
/// такой, какой она была при запуске.
@MainActor
final class PhoneMenuController: NSObject, NSMenuDelegate {

    /// Что делать по пунктам. Замыкания, а не ссылка на делегата приложения:
    /// меню ничего не знает про окна — оно только зовёт и только спрашивает.
    struct Actions {
        var isPanelVisible: () -> Bool
        var togglePanel: () -> Void
        var showHistory: () -> Void
        var showSettings: () -> Void
        var toggleOffline: () -> Void
    }

    let menu: NSMenu

    private let model: AppModel
    private let actions: Actions
    private let showsQuit: Bool

    init(title: String, model: AppModel, actions: Actions, showsQuit: Bool) {
        self.menu = NSMenu(title: title)
        self.model = model
        self.actions = actions
        self.showsQuit = showsQuit
        super.init()

        menu.delegate = self
        // Автогашение выключено: доступность пунктов задаётся здесь же, при
        // сборке, а системная проверка целей погасила бы всё разом — цели у нас
        // не в цепочке отклика, а в самих пунктах.
        menu.autoenablesItems = false
        rebuild()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    /// Первая строка — состояние текстом.
    ///
    /// Слова те же, что в панели: `registrationTitle` при отказе — это причина
    /// отказа, ради неё строка и заведена. Цветная точка на значке говорит
    /// «плохо», но не говорит «почему», а при спрятанной панели узнать причину
    /// больше неоткуда.
    ///
    /// Срок продления регистрации (`registrationDetail`), который в панели
    /// стоит вторым планом, сюда не переносится: человек открывает меню с
    /// вопросом «телефон работает?», и время следующего REGISTER отвечает не на
    /// него.
    private var statusTitle: String {
        guard !model.isOfflineByChoice else {
            return NSLocalizedString("Отключён", comment: "состояние в меню значка")
        }

        let number = model.settings.account.username
        let state = model.registrationTitle
        return number.isEmpty ? state : "\(state) · \(number)"
    }

    private func rebuild() {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        menu.addItem(.separator())

        // «Показать» и «Скрыть» — один пункт с двумя подписями: два отдельных,
        // из которых один всегда погашен, читаются как поломка.
        add(
            title: actions.isPanelVisible()
                ? NSLocalizedString("Скрыть панель", comment: "пункт меню значка")
                : NSLocalizedString("Показать панель", comment: "пункт меню значка"),
            key: "0"
        ) { [weak self] in self?.actions.togglePanel() }

        add(title: NSLocalizedString("История звонков", comment: "пункт меню значка"), key: "y") { [weak self] in self?.actions.showHistory() }

        // Без клавиши: ⌘, стоит на «Настройках…» в меню приложения, где их и
        // ищут по системной привычке. Две одинаковые клавиши в одной строке
        // меню — это не два входа, а один: система находит первый и до второго
        // не доходит.
        add(title: NSLocalizedString("Настройки…", comment: "пункт меню значка"), key: "") { [weak self] in self?.actions.showSettings() }

        menu.addItem(.separator())

        // Уход с линии — единственное здесь, что меняет состояние телефона.
        // Держится в меню потому, что сняться на обед надо каждый день, а ради
        // этого иначе приходится разворачивать панель.
        let offline = add(title: NSLocalizedString("Не беспокоить", comment: "пункт меню значка"), key: "") { [weak self] in
            self?.actions.toggleOffline()
        }
        offline.state = model.isOfflineByChoice ? .on : .off
        // В разговоре недоступно по той же причине, что и смена профиля:
        // отключение снимает регистрацию и закрывает диалоги (M6b).
        offline.isEnabled = model.canSwitchProfile

        guard showsQuit else { return }

        menu.addItem(.separator())
        add(title: NSLocalizedString("Завершить EliteSIP", comment: "пункт меню значка"), key: "") { NSApp.terminate(nil) }
    }

    @discardableResult
    private func add(title: String, key: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: key)
        let target = MenuAction(action)
        item.target = target
        // Цель у `NSMenuItem` слабая, поэтому обёртку держит сам пункт: иначе
        // она освобождается сразу после сборки меню, и пункт молча перестаёт
        // нажиматься.
        item.representedObject = target
        item.isEnabled = true
        menu.addItem(item)
        return item
    }
}

/// Обёртка над замыканием пункта меню.
///
/// `NSMenuItem` умеет звать только селектор у объекта, и без обёртки пришлось
/// бы заводить по методу на каждый пункт.
private final class MenuAction: NSObject {

    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func run() { action() }
}
