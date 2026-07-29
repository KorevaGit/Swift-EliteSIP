import SIPCore
import SwiftUI

struct PhonePanelView: View {

    @Environment(AppModel.self) private var model
    @Environment(IncomingCallPanel.self) private var incomingCall

    var body: some View {
        VStack(spacing: Theme.Metrics.sectionSpacing) {
            RegistrationBadge()

            DialedNumberField()

            DialpadView()

            if model.isInCall {
                CallControls()
            }

            callButton

            Divider()

            debugSection
        }
        .padding(.horizontal, Theme.Metrics.contentPadding)
        .padding(.bottom, Theme.Metrics.contentPadding)
        .padding(.top, Theme.Metrics.titleBarInset)
        .frame(width: Theme.Metrics.panelWidth)
        .frame(maxHeight: .infinity)
        .background {
            WindowAccessor { window in
                // Заголовок скрыт, поэтому окно надо таскать за фон.
                window.isMovableByWindowBackground = true

                // Размер задаём рамке окна, а не контенту. При скрытом
                // заголовке рамка получается на высоту полосы заголовка больше
                // контента, и «высота 500» у контента давала окно в 532 точки.
                // Свободную вертикаль внутри забирает клавиатура.
                window.styleMask.remove(.resizable)
                let size = CGSize(
                    width: Theme.Metrics.panelWidth,
                    height: Theme.Metrics.panelHeight
                )
                let topLeft = CGPoint(x: window.frame.minX, y: window.frame.maxY)
                window.setFrame(
                    CGRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height),
                    display: true
                )
            }
        }
        .onAppear {
            #if DEBUG
            // Позволяет проверить плавающую панель без ручного клика:
            // `EliteSIP.app/Contents/MacOS/EliteSIP --demo-incoming`.
            // В M3 через этот же флаг гоняются регрессии по рандомизации.
            if ProcessInfo.processInfo.arguments.contains("--demo-incoming") {
                showIncomingCallDemo()
            }
            // Позволяет проверить регистрацию в собранном приложении без ручного
            // клика — например снимком экрана из скрипта.
            if ProcessInfo.processInfo.arguments.contains("--connect-on-launch") {
                Task { await model.connect() }
            }

            // Проверка звука одной командой: подключиться и сразу позвонить.
            // Автоматизировать «слышно себя» нельзя, а вот дойти до разговора
            // без десятка кликов — можно.
            //   EliteSIP.app/Contents/MacOS/EliteSIP --call-on-launch 600
            if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--call-on-launch"),
               index + 1 < ProcessInfo.processInfo.arguments.count {
                let number = ProcessInfo.processInfo.arguments[index + 1]
                Task {
                    await model.connect()
                    _ = await waitForRegistration()
                    model.dialedNumber = number
                    await model.placeCall()
                }
            }
            #endif
        }
    }

    #if DEBUG
    /// Ждёт регистрации перед отладочным звонком: без неё Asterisk ответит 401
    /// и звонок не состоится.
    private func waitForRegistration(timeout: Duration = .seconds(15)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if model.isConnected { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return model.isConnected
    }
    #endif

    private func showIncomingCallDemo() {
        incomingCall.show(
            callerNumber: "2929",
            callerName: "AutoDialer",
            policy: model.settings.incomingCall,
            onAnswer: {},
            onDecline: {}
        )
    }

    private var isCallButtonEnabled: Bool {
        model.isInCall || (model.canPlaceCall && model.hasDialedNumber)
    }

    private var callButton: some View {
        VStack(spacing: 4) {
            Button {
                Task {
                    if model.isInCall {
                        await model.hangUp()
                    } else {
                        await model.placeCall()
                    }
                }
            } label: {
                Label(
                    model.isInCall ? "Завершить" : "Позвонить",
                    systemImage: model.isInCall ? "phone.down.fill" : "phone.fill"
                )
                .font(Theme.Text.controlLabel)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    (model.isInCall ? Theme.Palette.decline : Theme.Palette.answer),
                    in: .rect(cornerRadius: Theme.Radius.control)
                )
                .contentShape(.rect)
            }
            // Заливка задана явно, а не через .borderedProminent с tint: у того
            // радиус меньше макетного, а в неактивном окне акцент выцветает в
            // серый — панель висит поверх CRM и активной бывает редко.
            .buttonStyle(.plain)
            .hoverHighlight(isEnabled: isCallButtonEnabled)
            .disabled(!isCallButtonEnabled)
            // Системное затемнение выключенной кнопки на стеклянном фоне почти
            // не видно, и ярко-зелёная «Позвонить» выглядит рабочей, хотя ещё нет.
            .opacity(isCallButtonEnabled ? 1 : 0.4)
            .help(model.isInCall ? "Завершить разговор" : "Позвонить по набранному номеру")

            if !model.callStatus.isEmpty {
                Text(model.callStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var debugSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            MilestoneNote("M5: слепой перевод готов; консультация и три линии — в работе.")

            Button {
                showIncomingCallDemo()
            } label: {
                Label("Показать окно входящего", systemImage: "bell.badge")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .help("Проверка плавающей панели и рандомизации позиции")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RegistrationBadge: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            indicator

            VStack(alignment: .leading, spacing: 1) {
                Text(model.registrationTitle)
                    .font(Theme.Text.panelStatus)
                    .lineLimit(1)
                if let detail = model.registrationDetail {
                    Text(detail)
                        .font(Theme.Text.panelDetail)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            connectionButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .themedControlSurface()
    }

    @ViewBuilder
    private var indicator: some View {
        if model.isBusy {
            ProgressView()
                .controlSize(.small)
                .frame(width: 10, height: 10)
        } else {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
    }

    @ViewBuilder
    private var connectionButton: some View {
        if model.isConnected || model.isBusy {
            Button("Отключить") {
                Task { await model.disconnect() }
            }
            .controlSize(.small)
        } else {
            Button("Подключить") {
                Task { await model.connect() }
            }
            .controlSize(.small)
            .disabled(!model.canConnect)
            .help(model.canConnect ? "Зарегистрироваться на сервере" : "Сначала заполните учётную запись в настройках")
        }
    }

    private var color: Color {
        switch model.registration {
        case .idle: Theme.Palette.offline
        case .registering, .unregistering: Theme.Palette.connecting
        case .registered: Theme.Palette.registered
        case .failed: Theme.Palette.failure
        }
    }
}

struct DialedNumberField: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            // В разговоре здесь видны отправленные тоны, а не набранный номер:
            // без обратной связи оператор не отличит «цифра ушла» от «кнопка
            // не нажалась», а голосовое меню молчит одинаково в обоих случаях.
            Text(model.displayedNumber.isEmpty ? placeholder : model.displayedNumber)
                .font(.system(size: Theme.Metrics.dialedNumberFontSize, weight: .light, design: .rounded))
                .foregroundStyle(model.displayedNumber.isEmpty ? .tertiary : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !model.isInCall, model.hasDialedNumber {
                Button {
                    model.removeLastDigit()
                } label: {
                    Image(systemName: "delete.left")
                }
                .buttonStyle(.borderless)
                .help("Удалить последнюю цифру")

                Button {
                    model.clearDialedNumber()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Очистить")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .themedSurface()
    }

    private var placeholder: String {
        model.callPhase == .active ? "Тоны" : "Номер"
    }
}

/// Кнопки, которые имеют смысл только в разговоре: удержание, микрофон, макросы.
///
/// Появляются вместе с разговором и исчезают вместе с ним. Держать их на экране
/// постоянно, но выключенными, значит занимать место на узкой панели ради того,
/// чем нельзя воспользоваться.
struct CallControls: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                controlButton(
                    title: model.isOnHold ? "Вернуть" : "Удержать",
                    systemImage: model.isOnHold ? "play.fill" : "pause.fill",
                    isOn: model.isOnHold,
                    isEnabled: model.canHold,
                    help: model.isOnHold
                        ? "Вернуться к разговору"
                        : "Собеседник услышит музыку ожидания сервера"
                ) {
                    Task { await model.toggleHold() }
                }

                controlButton(
                    title: model.isMicrophoneMuted ? "Включить" : "Микрофон",
                    systemImage: model.isMicrophoneMuted ? "mic.slash.fill" : "mic.fill",
                    isOn: model.isMicrophoneMuted,
                    isEnabled: model.callPhase == .active,
                    help: "Собеседник не услышит вас и не узнает об этом"
                ) {
                    model.toggleMicrophone()
                }
            }

            if !model.usableMacros.isEmpty {
                // Ряд с переносом: макросов может быть сколько угодно, а панель
                // шириной 280 точек не резиновая.
                FlowRow(spacing: 6) {
                    ForEach(model.usableMacros) { macro in
                        Button(macro.title) {
                            model.send(macro: macro)
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .themedControlSurface()
                        .hoverHighlight(isEnabled: model.canSendDTMF)
                        .disabled(!model.canSendDTMF)
                        .opacity(model.canSendDTMF ? 1 : 0.4)
                        .help(model.settings.dtmf.sequence(of: macro).displayText)
                    }
                }
            }

            Button {
                model.showTransferEntry()
            } label: {
                Label("Перевести", systemImage: "phone.arrow.right")
                    .font(Theme.Text.controlLabel)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .themedControlSurface()
            .hoverHighlight(isEnabled: model.canTransfer)
            .disabled(!model.canTransfer)
            .opacity(model.canTransfer ? 1 : 0.4)
            .help("Слепой перевод текущего разговора")

            if model.isTransferEntryVisible {
                TransferEntry()
            }
        }
    }

    private func controlButton(
        title: String,
        systemImage: String,
        isOn: Bool,
        isEnabled: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(Theme.Text.controlLabel)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? Color.white : Color.primary)
        .background {
            if isOn {
                RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.Palette.connecting)
            }
        }
        .themedControlSurface()
        .hoverHighlight(isEnabled: isEnabled)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .help(help)
    }
}

/// Номер и подтверждение слепого перевода.
///
/// Поле показывается только по явному нажатию: в панели 280 точек, и постоянно
/// занимать место редкой операцией за счёт клавиатуры и статуса звонка нельзя.
private struct TransferEntry: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 6) {
            TextField(
                "Номер перевода",
                text: Binding(
                    get: { model.transferNumber },
                    set: { model.transferNumber = $0 }
                )
            )
                .textFieldStyle(.roundedBorder)
                .disabled(model.isTransferring)
                .onSubmit {
                    guard model.hasTransferNumber, !model.isTransferring else { return }
                    Task { await model.blindTransfer() }
                }

            HStack(spacing: 6) {
                Button("Отмена") {
                    model.cancelTransferEntry()
                }
                .frame(maxWidth: .infinity)
                .disabled(model.isTransferring)

                Button {
                    Task { await model.blindTransfer() }
                } label: {
                    if model.isTransferring {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Перевести")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.hasTransferNumber || model.isTransferring)
            }
            .controlSize(.small)
        }
        .padding(8)
        .themedSurface()
    }
}

/// Ряд с переносом на следующую строку.
///
/// SwiftUI до `Layout` этого не умел, а `LazyVGrid` раздаёт колонкам одинаковую
/// ширину — подписи макросов бывают и в два символа, и в десять.
struct FlowRow: Layout {

    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > width {
                totalHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += rowWidth > 0 ? spacing + size.width : size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        return CGSize(width: width == .infinity ? rowWidth : width, height: totalHeight + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Честная пометка о том, что ещё не сделано.
///
/// Нужна, чтобы скелет нельзя было принять за работающее приложение: кнопка,
/// которая выглядит рабочей и молча ничего не делает, хуже отсутствующей.
struct MilestoneNote: View {

    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Label(text, systemImage: "hammer.fill")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}
