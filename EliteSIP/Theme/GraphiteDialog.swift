import AppKit
import SwiftUI

/// Вопрос в оформлении окна пароля — как `Theme/Dialog.xaml` Windows 1.0.4:
/// значок в графитовом круге, заголовок, короткое последствие на карточке и
/// кнопки справа, подписанные тем же глаголом, каким задан вопрос.
///
/// Своё окно вместо `NSAlert` и `Alert` по той же причине, что и в Windows:
/// системный вопрос приходит со своей типографикой и значком приложения и на
/// фоне графитовых окон читается как окно другой программы. Поведение macOS
/// при этом сохранено: лист у окна, Esc — отмена, Enter — главное действие,
/// отмена стоит левее подтверждения.
struct GraphiteDialog: View {

    enum Role {
        /// Главное действие: акцентная кнопка и Enter.
        case primary
        /// Главное действие, которое что-то стирает или обрывает.
        case destructive
        /// Отказ: Esc.
        case cancel
        /// Третья дорога («Не сохранять»).
        case normal
    }

    struct Action: Identifiable {
        let id = UUID()
        let title: Text
        let role: Role
        var isDisabled = false
        let perform: () -> Void

        init(_ title: Text, role: Role, isDisabled: Bool = false, perform: @escaping () -> Void) {
            self.title = title
            self.role = role
            self.isDisabled = isDisabled
            self.perform = perform
        }
    }

    let icon: String
    let title: Text
    var message: Text?
    /// То, что надо прочесть, но что не сам вопрос: «вернуть нельзя».
    var footnote: Text?
    /// Слева направо, как стоят на экране.
    let actions: [Action]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing + 2) {
            HStack(alignment: .center, spacing: Theme.Metrics.sectionSpacing + 2) {
                LucideIcon(name: icon, size: 20)
                    .frame(width: 40, height: 40)
                    .graphiteSurface(.control, cornerRadius: 20)
                title
                    .font(Font.system(size: 17, weight: .semibold))
            }

            if message != nil || footnote != nil {
                VStack(alignment: .leading, spacing: Theme.Metrics.elementSpacing) {
                    if let message {
                        message
                            .font(.callout)
                            .compatForeground(Theme.Palette.textSecondary)
                    }
                    if let footnote {
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Metrics.tightSpacing) {
                            LucideIcon(name: "triangle-alert", size: Theme.Icon.medium)
                            footnote
                        }
                        .font(.footnote)
                        .compatForeground(Theme.Palette.failure)
                    }
                }
                .padding(Theme.Metrics.sectionSpacing + 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .graphiteSurface(.control)
            }

            HStack(spacing: Theme.Metrics.elementSpacing) {
                Spacer()
                ForEach(actions) { action in
                    button(for: action)
                }
            }
        }
        .padding(Theme.Metrics.contentPadding)
        .frame(width: Self.width)
    }

    /// 420, как у Windows без полей окна: у коротких вопросов не остаётся
    /// пустого поля, а длинные не растягиваются в строку на весь экран.
    static let width: CGFloat = 420

    @ViewBuilder
    private func button(for action: Action) -> some View {
        let button = Button(action: action.perform) { action.title }
            .disabled(action.isDisabled)
        switch action.role {
        case .primary:
            button
                .compatProminentButtonStyle()
                .compatKeyboardShortcut("\r", modifiers: [])
        case .destructive:
            button
                .compatForeground(action.isDisabled ? Theme.Palette.textSecondary : Theme.Palette.failure)
                .compatKeyboardShortcut("\r", modifiers: [])
        case .cancel:
            button.compatCancelShortcut()
        case .normal:
            button
        }
    }
}

extension View {

    /// Подтверждение листом у окна вместо `alert(isPresented:)`.
    func graphiteConfirmation(
        isPresented: Binding<Bool>,
        icon: String,
        title: Text,
        message: Text? = nil,
        footnote: Text? = nil,
        confirm: Text,
        role: GraphiteDialog.Role = .primary,
        cancel: Text = Text("Отмена"),
        onConfirm: @escaping () -> Void
    ) -> some View {
        sheet(isPresented: isPresented) {
            GraphiteDialog(
                icon: icon,
                title: title,
                message: message,
                footnote: footnote,
                actions: [
                    .init(cancel, role: .cancel) { isPresented.wrappedValue = false },
                    .init(confirm, role: role) {
                        isPresented.wrappedValue = false
                        onConfirm()
                    },
                ]
            )
        }
    }
}

// MARK: - Для AppKit

/// Тот же вопрос там, где SwiftUI-листа нет: выход, закрытие окна,
/// предложение обновиться. Ответы — как у `NSAlert`: первая кнопка списка
/// возвращает `.alertFirstButtonReturn`, вторая — `.alertSecondButtonReturn`.
@MainActor
final class GraphiteDialogWindow {

    struct Button {
        let title: String
        let role: GraphiteDialog.Role
    }

    let window: NSPanel

    /// - Parameter buttons: в порядке `NSAlert`: первая — главное действие.
    ///   На экране они встают справа налево, как у системного вопроса.
    init(icon: String, title: String, message: String?, footnote: String? = nil, buttons: [Button]) {
        window = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.backgroundColor = Graphite.windowBackground

        let actions = buttons.enumerated().reversed().map { index, button in
            GraphiteDialog.Action(Text(verbatim: button.title), role: button.role) { [weak self] in
                self?.finish(NSApplication.ModalResponse(
                    rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index
                ))
            }
        }
        let view = GraphiteDialog(
            icon: icon,
            title: Text(verbatim: title),
            message: message.map { Text(verbatim: $0) },
            footnote: footnote.map { Text(verbatim: $0) },
            actions: actions
        )
        // Полоса заголовка прозрачна и пуста — содержимое заходит под неё,
        // иначе над значком остаётся пустая строка высотой с заголовок.
        // Вид, а не `NSHostingController`: контроллер сам подгоняет окно под
        // содержимое вместе с полосой заголовка и оставляет снизу пустое поле.
        window.contentView = NSHostingView(rootView: view.edgesIgnoringSafeArea(.top))
        // Размер — по содержимому вне окна: внутри окна в него входит и
        // полоса заголовка, и снизу оставалось пустое поле той же высоты.
        let size = NSHostingController(rootView: view)
            .sizeThatFits(in: NSSize(width: GraphiteDialog.width, height: 2000))
        window.setFrame(NSRect(origin: .zero, size: size), display: false)
    }

    private var completion: ((NSApplication.ModalResponse) -> Void)?

    /// Модально, поверх всех окон приложения — как `NSAlert.runModal()`.
    func runModal() -> NSApplication.ModalResponse {
        window.center()
        let response = NSApp.runModal(for: window)
        window.orderOut(nil)
        return response
    }

    /// Листом у окна — как `NSAlert.beginSheetModal(for:)`.
    func beginSheet(for parent: NSWindow, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        self.completion = completion
        parent.beginSheet(window) { [weak self] response in
            self?.completion = nil
            completion(response)
        }
    }

    /// Закрыть снаружи, как если бы нажали кнопку.
    func finish(_ response: NSApplication.ModalResponse) {
        if let parent = window.sheetParent {
            parent.endSheet(window, returnCode: response)
        } else if NSApp.modalWindow === window {
            NSApp.stopModal(withCode: response)
        } else {
            window.orderOut(nil)
            completion?(response)
            completion = nil
        }
    }
}
