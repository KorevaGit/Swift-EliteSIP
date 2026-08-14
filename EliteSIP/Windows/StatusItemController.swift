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
            Task { @MainActor [weak self] in self?.redraw() }
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

        button.image = Self.makeImage(glyph: glyphColor, dot: dotColor)
        button.toolTip = model.isOfflineByChoice
            ? NSLocalizedString("Отключён", comment: "подсказка на значке в строке меню")
            : model.registrationTitle
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
    /// Корона: шире, чем выше, как и в фирменном знаке.
    private static let crownSize = NSSize(width: 15, height: 11)
    /// Диаметр точки. Меньше пяти она перестаёт читаться цветом, больше —
    /// начинает спорить с короной за место.
    private static let dotDiameter: CGFloat = 5

    /// Корона, под ней точка состояния.
    ///
    /// **Точка стоит на месте подставки.** В фирменном знаке корона опирается
    /// на горизонтальную черту с ножкой; в значке строки меню эта подставка
    /// заменена цветной точкой — то есть композиция знака сохранена, а
    /// состояние занимает место, которое в нём и так было занято. Дайлпад из
    /// знака здесь не рисуется вовсе: шесть клавиш на восемнадцати точках
    /// слипаются в серую полосу, и в строке меню его роль исполняет как раз
    /// точка. Полный знак с дайлпадом живёт в доке.
    private static func makeImage(glyph glyphColor: NSColor, dot dotColor: NSColor) -> NSImage {
        let size = NSSize(width: side, height: side)

        let image = NSImage(size: size, flipped: false) { _ in
            if let crown = NSImage(named: "crown.fill") {
                // Корона прижата к верху, точка — ко дну, и обе по центру: знак
                // читается как одно целое, а не как две фигуры рядом.
                let box = NSRect(
                    x: (side - crownSize.width) / 2,
                    y: side - crownSize.height - 0.5,
                    width: crownSize.width,
                    height: crownSize.height
                )
                crown.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
                glyphColor.set()
                box.fill(using: .sourceAtop)
            }

            // Точка рисуется после заливки короны: `sourceAtop` красит всё, что
            // уже лежит в прямоугольнике, и точка, нарисованная раньше, ушла бы
            // в цвет глифа.
            dotColor.set()
            NSBezierPath(
                ovalIn: NSRect(
                    x: (side - dotDiameter) / 2,
                    y: 0.5,
                    width: dotDiameter,
                    height: dotDiameter
                )
            ).fill()

            return true
        }

        // Не template: template система красит целиком, и точка стала бы того
        // же цвета, что трубка.
        image.isTemplate = false
        return image
    }
}
