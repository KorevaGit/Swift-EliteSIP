import AppKit
import SwiftUI

/// Запуск стенда без бандла: `swift run --package-path Tools/panelproto`.
///
/// Окно создаётся руками, а не через `App`-сцену: пакету без Info.plist сцены
/// SwiftUI не дают ни политику активации, ни фокус клавиатуры, а поле ввода
/// номера в прототипе надо проверять именно с клавиатуры.
@MainActor
final class StageDelegate: NSObject, NSApplicationDelegate {

    private var window: NSWindow?
    private let state = PrototypeState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `--render <файл>` печатает лист состояний в PNG и выходит: лист шире
        // экрана, и снимком окна его не снять.
        if let index = CommandLine.arguments.firstIndex(of: "--render"),
           index + 1 < CommandLine.arguments.count {
            render(to: CommandLine.arguments[index + 1])
            NSApp.terminate(nil)
            return
        }

        // `--panel` открывает панель настоящим окном: со своим светофором, со
        // своим заголовком и с прозрачным фоном.
        //
        // Без этого режима прозрачность обсуждать нечем. Внутри стенда панель
        // лежит на нарисованной подложке и просвечивает её, а не рабочий стол:
        // видно материал, но не видно главного — как он ведёт себя поверх
        // настоящей CRM, которую панель закрывает весь день.
        if CommandLine.arguments.contains("--panel") {
            showPanelWindow()
            return
        }

        // `--settings` — макет окна настроек менеджера (этап 2). Своим окном и
        // по тем же причинам, что `--panel`: прозрачность внутри стенда не
        // видна, а в этом макете она и есть предмет разговора.
        if CommandLine.arguments.contains("--settings") {
            showSettingsWindow()
            return
        }

        // `--sheet` рисует все состояния сразу и нужен для снимка на
        // согласование; без него открывается интерактивный стенд.
        let isSheet = CommandLine.arguments.contains("--sheet")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: isSheet ? 1900 : 900, height: isSheet ? 560 : 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "EliteSIP · прототип панели"
        window.contentView = isSheet
            ? NSHostingView(rootView: SheetView())
            : NSHostingView(rootView: StageView().environmentObject(state))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)

        // Рамка окна в точках — по ней снимок обрезается до окна без ручного
        // выделения области.
        let frame = window.frame
        let screenHeight = window.screen?.frame.height ?? 0
        print("FRAME \(frame.minX) \(screenHeight - frame.maxY) \(frame.width) \(frame.height)")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Панель настоящим окном: свой светофор, свой заголовок, прозрачный фон.
    ///
    /// Так же она будет собрана в приложении, поэтому здесь и лежит всё, что
    /// нельзя показать вёрсткой:
    ///
    ///   - заголовок виден, но полоса прозрачна — название встаёт по центру над
    ///     содержимым, а не отрезает сверху непрозрачную ленту;
    ///   - окно не непрозрачно и без своего фона — иначе `NSVisualEffectView`
    ///     с `.behindWindow` размывать нечего, и вся затея с прозрачностью
    ///     упирается в белый прямоугольник под ней;
    ///   - уровень `.floating` — панель обязана оставаться поверх CRM (этап 1
    ///     плана по интерфейсу).
    private func showPanelWindow() {
        if CommandLine.arguments.contains("--light") { state.isDark = false }
        if let index = CommandLine.arguments.firstIndex(of: "--tint"),
           index + 1 < CommandLine.arguments.count,
           let tint = Double(CommandLine.arguments[index + 1]) {
            state.surfaceTint = tint
        }
        if let index = CommandLine.arguments.firstIndex(of: "--surface"),
           index + 1 < CommandLine.arguments.count,
           let glass = Tokens.Glass.allCases.first(
               where: { $0.rawValue.lowercased().hasPrefix(CommandLine.arguments[index + 1].lowercased()) }
           ) {
            state.glass = glass
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Tokens.Metrics.panelWidth, height: 400),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "EliteSIP"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.appearance = NSAppearance(named: state.isDark ? .darkAqua : .aqua)

        // Хостинг сам подгоняет окно под содержимое, а содержимое знает свою
        // высоту само: считать её здесь второй раз значит завести второе место,
        // где эта высота задана.
        window.contentViewController = NSHostingController(
            rootView: PanelView(drawsTitleBar: false).environmentObject(state)
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
    }

    /// Настройки настоящим окном: прозрачный фон, системный материал под ним.
    ///
    /// Высоту не задаём — её считает содержимое. Смысл макета в том числе в
    /// том, чтобы увидеть, сколько окно просит, а не проверить, влезает ли оно
    /// в заранее назначенное число.
    private func showSettingsWindow() {
        let isDark = !CommandLine.arguments.contains("--light")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsTokens.windowWidth, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Настройки EliteSIP"
        // Название рисует вёрстка: системное встало бы над содержимым, которое
        // при `.fullSizeContentView` начинается под полосой, и материала под
        // ним не было бы. То же решение, что в панели.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        // Поверх остального — только в стенде и только ради снимков: окно
        // прозрачное, и если его накрыть чужим, снимать будет нечего. В
        // приложении настройки — обычное окно.
        window.level = .floating
        window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)

        // Высоту окна задаёт содержимое, и это здесь не удобство, а условие.
        // При `.fullSizeContentView` окно ровно такой высоты, какую попросила
        // вёрстка, — значит, материал накрывает и полосу заголовка. Стоит
        // вёрстке оказаться ниже окна (например, от `maxHeight: .infinity`),
        // как разница вылезает сверху дырой насквозь: у прозрачного окна там не
        // «чуть светлее», а чужие вкладки под светофором.
        window.contentViewController = NSHostingController(rootView: SettingsProtoView())

        // Не по центру, а в заданную точку главного экрана: центр приходится на
        // тот дисплей, где мышь, и снимок для сверки каждый раз промахивается
        // мимо окна.
        // `screens.first`, а не `main`: главным считается экран с курсором, а
        // нужен тот, где строка меню, — его координаты совпадают с теми, в
        // которых снимает `screencapture`.
        if let screen = NSScreen.screens.first {
            let visible = screen.visibleFrame
            window.setFrameTopLeftPoint(
                NSPoint(x: visible.minX + 80, y: visible.maxY - 20)
            )
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)

        let frame = window.frame
        let screenHeight = window.screen?.frame.height ?? 0
        print("FRAME \(frame.minX) \(screenHeight - frame.maxY) \(frame.width) \(frame.height)")
    }

    private func render(to path: String) {
        let renderer = ImageRenderer(content: SheetView().frame(width: 1860, height: 620))
        renderer.scale = 2

        guard let image = renderer.nsImage,
              let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            print("Не удалось отрисовать лист")
            return
        }

        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("Готово: \(path)")
        } catch {
            print("Не удалось записать \(path): \(error)")
        }
    }
}

// Верхний уровень `main.swift` не изолирован главным актором, а всё окружение
// AppKit — изолировано. Точка запуска и есть главный поток, поэтому изоляция
// здесь утверждается, а не переносится в задачу.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = StageDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
}
