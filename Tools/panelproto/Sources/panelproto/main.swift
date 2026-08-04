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
