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
        /// Главное действие, которое что-то стирает или обрывает. Enter его
        /// не нажимает: стереть историю или оборвать разговор случайным
        /// нажатием нельзя, для этого тянутся мышью.
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

    /// Список на карточке — «Что нового» в предложении обновиться.
    struct Listing {
        let icon: String
        let heading: Text
        let items: [String]
    }

    /// Строка под карточкой: значок и короткий факт.
    struct Remark: Identifiable {
        let id = UUID()
        let icon: String
        let text: Text
        var isPositive = false
    }

    let icon: String
    let title: Text
    /// Вторая строка шапки: «EliteSIP 0.1.71 → 0.1.72».
    var subtitle: Text?
    var message: Text?
    var listing: Listing?
    /// То, что надо прочесть, но что не сам вопрос: «вернуть нельзя».
    var footnote: Text?
    var remarks: [Remark] = []
    /// Слева от кнопок, вторым планом: «Напомним через 4 часа».
    var caption: Text?
    /// Слева направо, как стоят на экране.
    let actions: [Action]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing + 2) {
            HStack(alignment: .center, spacing: Theme.Metrics.sectionSpacing + 2) {
                LucideIcon(name: icon, size: 20)
                    .frame(width: 40, height: 40)
                    .graphiteSurface(.control, cornerRadius: 20)
                VStack(alignment: .leading, spacing: 2) {
                    title
                        .font(Font.system(size: 17, weight: .semibold))
                    if let subtitle {
                        subtitle
                            .font(.footnote)
                            .compatForeground(Theme.Palette.textSecondary)
                    }
                }
            }

            if message != nil || footnote != nil || listing != nil {
                VStack(alignment: .leading, spacing: Theme.Metrics.elementSpacing) {
                    if let message {
                        message
                            .font(.callout)
                            .compatForeground(Theme.Palette.textSecondary)
                            // Не сжимается в одну строку с многоточием, если
                            // окну досталось меньше высоты, чем нужно.
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let listing {
                        self.list(listing)
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

            if !remarks.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Metrics.tightSpacing + 2) {
                    ForEach(remarks) { remark in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Metrics.elementSpacing) {
                            LucideIcon(name: remark.icon, size: Theme.Icon.medium)
                                .compatForeground(
                                    remark.isPositive ? Theme.Palette.registered : Theme.Palette.textSecondary
                                )
                            remark.text
                                .compatForeground(
                                    remark.isPositive ? Theme.Palette.textPrimary : Theme.Palette.textSecondary
                                )
                        }
                        .font(.footnote)
                    }
                }
                .padding(.horizontal, 2)
            }

            HStack(spacing: Theme.Metrics.elementSpacing) {
                if let caption {
                    caption
                        .font(.footnote)
                        .compatForeground(Theme.Palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                ForEach(actions) { action in
                    button(for: action)
                }
            }
        }
        .padding(Theme.Metrics.contentPadding)
        .frame(width: Self.width)
    }

    /// Пункты списка. Короткий список стоит как есть, длинный прокручивается:
    /// окно не должно вырастать выше экрана из-за подробных заметок.
    @ViewBuilder
    private func list(_ listing: Listing) -> some View {
        HStack(spacing: Theme.Metrics.elementSpacing) {
            LucideIcon(name: listing.icon, size: Theme.Icon.medium)
            listing.heading.font(Font.callout.weight(.semibold))
        }
        let rows = VStack(alignment: .leading, spacing: Theme.Metrics.elementSpacing) {
            ForEach(Array(listing.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Metrics.elementSpacing) {
                    Text(verbatim: "•").compatForeground(Theme.Palette.textSecondary)
                    Text(verbatim: item).fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if listing.items.count > Self.listingRowsBeforeScroll {
            ScrollView { rows }.frame(height: Self.listingScrollHeight)
        } else {
            rows
        }
    }

    private static let listingRowsBeforeScroll = 6
    /// `MaxHeight="224"` у списка заметок в окне обновления Windows.
    private static let listingScrollHeight: CGFloat = 224

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
    init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        message: String?,
        listing: GraphiteDialog.Listing? = nil,
        footnote: String? = nil,
        remarks: [GraphiteDialog.Remark] = [],
        caption: String? = nil,
        buttons: [Button]
    ) {
        let panel = DialogPanel(
            contentRect: .zero,
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window = panel
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.backgroundColor = Graphite.windowBackground

        func response(_ index: Int) -> NSApplication.ModalResponse {
            NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index)
        }
        let actions = buttons.enumerated().reversed().map { index, button in
            GraphiteDialog.Action(Text(verbatim: button.title), role: button.role) { [weak self] in
                self?.finish(response(index))
            }
        }
        // Клавиши и там, где SwiftUI их не умеет (Catalina): Esc — отказ,
        // Enter — главное действие, но не разрушающее.
        if let index = buttons.firstIndex(where: { $0.role == .cancel }) {
            panel.onCancel = { [weak self] in self?.finish(response(index)) }
        }
        if let index = buttons.firstIndex(where: { $0.role == .primary }) {
            panel.onDefault = { [weak self] in self?.finish(response(index)) }
        }
        let view = GraphiteDialog(
            icon: icon,
            title: Text(verbatim: title),
            subtitle: subtitle.map { Text(verbatim: $0) },
            message: message.map { Text(verbatim: $0) },
            listing: listing,
            footnote: footnote.map { Text(verbatim: $0) },
            remarks: remarks,
            caption: caption.map { Text(verbatim: $0) },
            actions: actions
        )
        // Полоса заголовка прозрачна и пуста — содержимое заходит под неё,
        // иначе над значком остаётся пустая строка высотой с заголовок.
        let host = FullBleedHostingView(rootView: view.edgesIgnoringSafeArea(.all))
        if #available(macOS 13.0, *) {
            // Вид не диктует окну размер: свой он считает вместе с полосой
            // заголовка, и окно выходило выше содержимого — под кнопками
            // оставалось лишнее поле.
            host.sizingOptions = []
        }
        window.contentView = host
        // Размер — по содержимому вне окна, без полосы заголовка.
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

/// Содержимое на всю панель, включая место под прозрачной полосой заголовка.
///
/// `edgesIgnoringSafeArea` одного мало: SwiftUI всё равно предлагает содержимому
/// высоту за вычетом полосы, сообщение сжималось в строку с многоточием, а под
/// кнопками оставалось поле на высоту полосы.
private final class FullBleedHostingView<Content: View>: NSHostingView<Content> {

    @available(macOS 11.0, *)
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets() }
}

/// Панель вопроса: клавиши Esc и Enter без помощи SwiftUI.
private final class DialogPanel: NSPanel {

    var onCancel: (() -> Void)?
    var onDefault: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        // 36 — Return, 76 — Enter цифрового блока.
        if event.keyCode == 36 || event.keyCode == 76, let onDefault {
            onDefault()
        } else {
            super.keyDown(with: event)
        }
    }
}
