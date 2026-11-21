import AppKit
import Combine

/// Значок в строке меню: состояние телефона и второй вход к панели.
///
/// `NSStatusItem` руками, а не `MenuBarExtra`: сцена появилась в macOS 13, а
/// срез x86_64 обязан работать на Catalina.
///
/// **Значок — не единственный вход, а второй.** Панель осталась обычным окном
/// со светофором, и закрыть её можно по-прежнему красной кнопкой. Разница в
/// том, что теперь закрытие панели означает не «убрать с глаз», а «свернуть
/// приложение в строку меню»: последнее закрытое окно уводит `NSApp` в
/// `.accessory`, и иконка уходит из Dock — см.
/// `AppDelegate.updateActivationPolicy`.
///
/// **Почему значок рисуется руками.** Template-изображение система красит
/// целиком одним цветом, и цветная точка состояния этого не переживает.
/// Поэтому изображение составное и не template: корона из своего комплекта, под
/// ней точка состояния. Цена — перерисовка руками: цвет глифа
/// приходится считать самим при каждой смене вида строки меню, а подсветку
/// нажатой кнопки система нам больше не отрабатывает (см. `redraw`).
@MainActor
final class StatusItemController: NSObject {

    private let model: AppModel
    private let menu: NSMenu
    private let onLeftClick: () -> Void
    private let statusItem: NSStatusItem
    private var cancellables: Set<AnyCancellable> = []
    private var appearanceObservation: NSKeyValueObservation?

    /// Из чего собрано изображение, которое стоит на кнопке сейчас.
    ///
    /// Без этой сверки значок перерисовывал сам себя без конца. На macOS 26
    /// установка `button.image` рисует кнопку заново, а отрисовка заново
    /// выставляет ей вид — и KVO на `effectiveAppearance` срабатывает на каждом
    /// кадре, хотя вид не менялся. Наблюдатель звал `redraw`, тот ставил новое
    /// изображение, и круг замыкался: выпуск 0.1.36 на живой машине 14 сентября
    /// 2026 держал 70–75 % процессора в простое, а в Пункт управления уходило
    /// около сотни обновлений значка в секунду. Изображение ставится только
    /// когда поменялось то, из чего оно состоит.
    private var drawn: (isDark: Bool, dot: NSColor, toolTip: String)?

    init(model: AppModel, menu: NSMenu, onLeftClick: @escaping () -> Void) {
        self.model = model
        self.menu = menu
        self.onLeftClick = onLeftClick
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()
        observeModel()
        observeAppearance()
        redraw()
    }

    // MARK: - Кнопка и щелчки

    private func configureButton() {
        guard let button = statusItem.button else { return }

        // Обе кнопки ловятся одним действием. Штатный `statusItem.menu`
        // перехватил бы и левый щелчок тоже — панель тогда открывалась бы
        // только через меню, а левый клик показывал бы список.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.target = self
        button.action = #selector(handleClick)
        button.setAccessibilityLabel("EliteSIP")
    }

    @objc private func handleClick() {
        let isRightClick = NSApp.currentEvent.map { event in
            event.type == .rightMouseUp || event.modifierFlags.contains(.control)
        } ?? false

        if isRightClick {
            showMenu()
        } else {
            onLeftClick()
        }
    }

    /// Меню показывается через временную привязку к `statusItem`.
    ///
    /// `NSMenu.popUp(positioning:)` тоже открыл бы его, но не подсветил бы саму
    /// кнопку, и значок при открытом меню выглядел бы ненажатым.
    private func showMenu() {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - Наблюдение

    private func observeModel() {
        // Перерисовка по любому изменению модели, а не по трём отдельным
        // публикациям: значок читает регистрацию, разговор и уход с линии, и
        // подписаться на каждое поле порознь дороже, чем перерисовать
        // изображение в восемнадцать точек.
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { _ in Task { @MainActor [weak self] in self?.redraw() } }
            .store(in: &cancellables)
    }

    /// Вид строки меню — свой, и с темой приложения он не совпадает.
    ///
    /// Тема — настройка менеджера (`NSApp.appearance`), а строка меню живёт по
    /// системному виду: светлое приложение на тёмной системе получает тёмную
    /// строку меню, и глиф в ней обязан быть светлым. Поэтому цвет считается по
    /// виду самой кнопки, а не по виду приложения.
    private func observeAppearance() {
        appearanceObservation = statusItem.button?.observe(\.effectiveAppearance) { _, _ in
            Task { @MainActor [weak self] in self?.redraw() }
        }

        // «Уменьшение прозрачности» и увеличенный контраст меняют не цвет, а
        // требования к нему: точка в несколько точек размером — первое место,
        // где контраст ломается.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            // Входы изображения при этом прежние, а нарисовать его надо
            // заново: системные цвета под новым контрастом другие.
            Task { @MainActor [weak self] in
                self?.drawn = nil
                self?.redraw()
            }
        }
    }

    // MARK: - Рисование

    private func redraw() {
        guard let button = statusItem.button else { return }

        let isDark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        // Подсветка нажатой кнопки цвет глифа не меняет, и это решение, а не
        // упущение. Первый заход инвертировал глиф под подсветку — в расчёте на
        // тёмно-синюю заливку прежних систем, — и на живом Tahoe оказалось, что
        // подсветка там светлая: белый глиф на ней пропал бы целиком. Угадывать
        // цвет заливки по версии системы не станем; чем это грозит на Catalina,
        // записано в плане строкой «что проверять живьём».
        let glyphColor: NSColor = isDark ? .white : .black
        let dot = dotColor
        let toolTip = model.isOfflineByChoice
            ? NSLocalizedString("Отключён", comment: "подсказка на значке в строке меню")
            : model.registrationTitle

        // Сверка обязательна, а не экономия: см. `drawn`.
        if let drawn, drawn.isDark == isDark, drawn.dot == dot, drawn.toolTip == toolTip { return }
        drawn = (isDark, dot, toolTip)

        button.image = Self.makeImage(glyph: glyphColor, dot: dot)
        button.toolTip = toolTip
    }

    /// Цвет точки. Словарь тот же, что в капсуле панели, плюс разговор.
    ///
    /// Разговор перекрывает регистрацию, а не приписывается к ней: при
    /// спрятанной панели значок — единственный признак того, что микрофон
    /// живой, и это важнее, чем «зарегистрирован», о котором и так говорит сам
    /// факт разговора.
    private var dotColor: NSColor {
        if model.isOfflineByChoice { return Theme.Palette.statusOffline }
        if model.isInCall { return Theme.Palette.statusInCall }

        switch model.registration {
        case .idle: return Theme.Palette.statusOffline
        case .registering, .unregistering: return Theme.Palette.statusConnecting
        case .registered: return Theme.Palette.statusRegistered
        case .failed: return Theme.Palette.statusFailure
        }
    }

    // MARK: - Изображение

    /// Сторона изображения. Восемнадцать точек — системный размер значка в
    /// строке меню: больше — обрезается, меньше — висит в воздухе.
    private static let side: CGFloat = 18

    /// Знак «Шампань» контуром, целиком цветом состояния.
    ///
    /// С Windows-клиентом 1.0.1 — тот же контур, что в иконке, без подложки, и
    /// весь символ окрашен по состоянию, как в трее Windows. В покое (не на
    /// линии) контур берёт цвет строки меню: серая точка рядом с серой короной
    /// читалась бы как ещё одна неработающая деталь.
    private static func makeImage(glyph glyphColor: NSColor, dot dotColor: NSColor) -> NSImage {
        let size = NSSize(width: side, height: side)
        let color = dotColor == Theme.Palette.statusOffline ? glyphColor : dotColor

        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let box = CGRect(x: 0.5, y: 0.5, width: side - 1, height: side - 1)
            context.addPath(BrandMark.path(in: box))
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(BrandMark.lineWidth * box.width / 32)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
            return true
        }

        // Не template: template система красит целиком в свой цвет, а цвет здесь
        // и есть состояние.
        image.isTemplate = false
        return image
    }
}
