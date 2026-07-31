import Compat
import SIPCore
import SwiftUI

struct PhonePanelView: View {

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var incomingCall: IncomingCallPanel

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
        // Шестерёнка живёт в полосе заголовка, справа от светофора, а не в
        // бейдже: в бейдже она отъедала ширину у строки состояния, и «Не
        // подключено» превращалось в «Не подключ…». Накладкой, а не элементом
        // стопки, — чтобы вёрстка панели осталась ровно прежней.
        .compatOverlay(alignment: .topTrailing) { settingsButton }
        .compatBackground {
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

    /// Вход в настройки с панели.
    ///
    /// До этого дорога была одна — пункт меню, и на рабочем месте её не
    /// находили: панель показывается сама, а в строку меню оператор не смотрит.
    /// Действие то же самое, что у пункта «Настройки…»: оно уходит в цепочку
    /// ответчиков, где его ловит делегат приложения. Второго кода, умеющего
    /// открывать окно настроек, в приложении нет — иначе окон стало бы два.
    private var settingsButton: some View {
        Button {
            NSApp.sendAction(#selector(AppDelegate.showSettingsWindow(_:)), to: nil, from: nil)
        } label: {
            CompatSymbol(name: "gearshape")
        }
        .buttonStyle(.borderless)
        .compatForeground(.secondary)
        .padding(.top, 5)
        .padding(.trailing, Theme.Metrics.contentPadding)
        .compatHelp("Настройки EliteSIP (⌘,)")
        .compatAccessibilityLabel("Настройки")
    }

    #if DEBUG
    /// Ждёт регистрации перед отладочным звонком: без неё Asterisk ответит 401
    /// и звонок не состоится.
    private func waitForRegistration(timeout: Interval = .seconds(15)) async -> Bool {
        let deadline = MonotonicClock.now + timeout
        while MonotonicClock.now < deadline {
            if model.isConnected { return true }
            try? await Task.sleep(.milliseconds(200))
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
                CompatLabel(title: model.isInCall ? "Завершить" : "Позвонить", symbol: model.isInCall ? "phone.down.fill" : "phone.fill")
                .font(Theme.Text.controlLabel)
                .compatForeground(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .compatBackground(
                    model.isInCall ? Theme.Palette.decline : Theme.Palette.answer,
                    cornerRadius: Theme.Radius.control
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
            .compatHelp(model.isInCall ? "Завершить разговор" : "Позвонить по набранному номеру")

            if !model.callStatus.isEmpty {
                Text(model.callStatus)
                    .font(.system(size: 10))
                    .compatForeground(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var debugSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            MilestoneNote("M6: три линии, консультация и ConfBridge готовы; живой прогон впереди.")

            Button {
                showIncomingCallDemo()
            } label: {
                CompatLabel(title: "Показать окно входящего", symbol: "bell.badge")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .compatHelp("Проверка плавающей панели и рандомизации позиции")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RegistrationBadge: View {

    @EnvironmentObject private var model: AppModel

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
                        .compatForeground(Theme.Palette.tertiary)
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
            CompatSpinner()
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
            // Кнопка в двух сантиметрах от «Завершить», а снимает регистрацию
            // вместе со всеми диалогами. В разговоре она недоступна.
            .disabled(!model.canDisconnect)
            .compatHelp(
                model.canDisconnect
                    ? "Снять регистрацию на сервере"
                    : "Недоступно в разговоре: сначала завершите звонок"
            )
        } else {
            Button("Подключить") {
                Task { await model.connect() }
            }
            .controlSize(.small)
            .disabled(!model.canConnect)
            .compatHelp(model.canConnect ? "Зарегистрироваться на сервере" : "Сначала заполните учётную запись в настройках")
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

    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            // В разговоре здесь видны отправленные тоны, а не набранный номер:
            // без обратной связи оператор не отличит «цифра ушла» от «кнопка
            // не нажалась», а голосовое меню молчит одинаково в обоих случаях.
            Text(model.displayedNumber.isEmpty ? placeholder : model.displayedNumber)
                .font(.system(size: Theme.Metrics.dialedNumberFontSize, weight: .light, design: .rounded))
                .compatForeground(model.displayedNumber.isEmpty ? Theme.Palette.tertiary : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !model.isInCall, model.hasDialedNumber {
                Button {
                    model.removeLastDigit()
                } label: {
                    CompatSymbol(name: "delete.left")
                }
                .buttonStyle(.borderless)
                .compatHelp("Удалить последнюю цифру")

                Button {
                    model.clearDialedNumber()
                } label: {
                    CompatSymbol(name: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .compatHelp("Очистить")
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

    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 6) {
            if model.lines.count > 1 {
                LineStrip()
            }

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
                MacroFlow(items: model.usableMacros, spacing: 6) { macro in
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
                    .compatHelp(model.settings.dtmf.sequence(of: macro).displayText)
                }
            }

            HStack(spacing: 6) {
                controlButton(
                    title: "Перевести",
                    systemImage: "phone.arrow.right",
                    isOn: model.isTransferEntryVisible && model.numberEntry == .blindTransfer,
                    isEnabled: model.canTransfer && !model.isTransferEntryVisible,
                    help: "Слепой перевод текущего разговора"
                ) {
                    model.showTransferEntry()
                }

                controlButton(
                    title: "Конференция",
                    systemImage: "person.3.fill",
                    isOn: model.isConferenceCommandSent,
                    isEnabled: model.canStartConference,
                    help: "Перевести оба плеча разговора в ConfBridge"
                ) {
                    model.startConference()
                }
            }

            // Консультация: клиент уходит на удержание, оператор набирает
            // коллегу и только после разговора соединяет их.
            if let consultation = model.consultationLine {
                HStack(spacing: 6) {
                    controlButton(
                        title: "Соединить",
                        systemImage: "arrow.triangle.merge",
                        isOn: false,
                        isEnabled: model.canCompleteConsultation,
                        help: "Соединить собеседников и уйти из разговора"
                    ) {
                        Task { await model.completeConsultation() }
                    }

                    controlButton(
                        title: "Отбой \(consultation.title)",
                        systemImage: "phone.down",
                        isOn: false,
                        isEnabled: !model.isTransferring,
                        help: "Завершить консультацию и вернуться к клиенту"
                    ) {
                        Task { await model.cancelConsultation() }
                    }
                }
            } else {
                controlButton(
                    title: "Консультация",
                    systemImage: "person.badge.plus",
                    isOn: model.isTransferEntryVisible && model.numberEntry == .consultation,
                    isEnabled: model.canConsult && !model.isTransferEntryVisible,
                    help: "Позвонить коллеге, пока клиент на удержании"
                ) {
                    model.showConsultationEntry()
                }
            }

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
            CompatLabel(title: title, symbol: systemImage)
                .font(Theme.Text.controlLabel)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .compatForeground(isOn ? Color.white : Color.primary)
        .compatBackground {
            if isOn {
                RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.Palette.connecting)
            }
        }
        .themedControlSurface()
        .hoverHighlight(isEnabled: isEnabled)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .compatHelp(help)
    }
}

/// Линии оператора: какая звучит, какие ждут на удержании.
///
/// Появляется только со второй линией. Одна линия — это обычный разговор, и
/// полоса с единственной строкой заняла бы место, ничего не сообщив.
private struct LineStrip: View {

    @EnvironmentObject private var model: AppModel

    private func isSwitchable(_ line: AppModel.CallLine) -> Bool {
        line.id != model.activeLineID && !model.isSwitchingLines && !model.isTransferring
    }

    var body: some View {
        VStack(spacing: 4) {
            ForEach(model.lines) { line in
                Button {
                    Task { await model.switchLine(to: line.id) }
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(line.id == model.activeLineID ? Theme.Palette.registered : Theme.Palette.offline)
                            .frame(width: 6, height: 6)
                        Text(line.title)
                            .font(Theme.Text.panelStatus)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(line.status)
                            .font(Theme.Text.panelDetail)
                            .compatForeground(Theme.Palette.tertiary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .themedControlSurface()
                .hoverHighlight(isEnabled: isSwitchable(line))
                .disabled(!isSwitchable(line))
                .compatHelp(
                    line.id == model.activeLineID
                        ? "Звук идёт по этой линии"
                        : "Переключить звук на \(line.title)"
                )
            }
        }
    }
}

/// Номер перевода или консультации и его подтверждение.
///
/// Поле показывается только по явному нажатию: в панели 280 точек, и постоянно
/// занимать место редкой операцией за счёт клавиатуры и статуса звонка нельзя.
private struct TransferEntry: View {

    @EnvironmentObject private var model: AppModel

    private var isConsultation: Bool { model.numberEntry == .consultation }

    private var actionTitle: String { isConsultation ? "Позвонить" : "Перевести" }

    private func submit() {
        guard model.hasTransferNumber, !model.isTransferring else { return }
        Task {
            if isConsultation {
                await model.startConsultation()
            } else {
                await model.blindTransfer()
            }
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            CompatTextField(
                title: isConsultation ? "Номер коллеги" : "Номер перевода",
                text: Binding(
                    get: { model.transferNumber },
                    set: { model.transferNumber = $0 }
                ),
                onSubmit: submit
            )
                .textFieldStyle(.roundedBorder)
                .disabled(model.isTransferring)

            HStack(spacing: 6) {
                Button("Отмена") {
                    model.cancelTransferEntry()
                }
                .frame(maxWidth: .infinity)
                .disabled(model.isTransferring)

                Button(action: submit) {
                    if model.isTransferring {
                        CompatSpinner()
                            .frame(height: 12)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text(actionTitle)
                            .frame(maxWidth: .infinity)
                    }
                }
                .compatProminentButtonStyle()
                .disabled(!model.hasTransferNumber || model.isTransferring)
            }
            .controlSize(.small)
        }
        .padding(8)
        .themedSurface()
    }
}

/// Кнопки макросов: перенос по ширине там, где он есть, и сетка там, где нет.
///
/// `Layout` появился только в macOS 13, а срез x86_64 обязан работать на
/// Catalina. Замена ему — фиксированные три кнопки в ряд: подпись макроса
/// задаёт оператор, и предсказать её ширину заранее нельзя, но три коротких
/// кнопки в панель шириной 280 точек влезают всегда. Переносить по месту без
/// `Layout` пришлось бы через `GeometryReader` и preference key, а это лишний
/// проход раскладки ради ряда кнопок.
struct MacroFlow<Item: Identifiable, Content: View>: View {

    let items: [Item]
    var spacing: CGFloat = 6
    @ViewBuilder let content: (Item) -> Content

    private static var itemsPerRow: Int { 3 }

    var body: some View {
        if #available(macOS 13.0, *) {
            FlowRow(spacing: spacing) {
                ForEach(items) { content($0) }
            }
        } else {
            VStack(alignment: .leading, spacing: spacing) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: spacing) {
                        ForEach(row) { content($0) }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var rows: [[Item]] {
        stride(from: 0, to: items.count, by: Self.itemsPerRow).map { start in
            Array(items[start..<min(start + Self.itemsPerRow, items.count)])
        }
    }
}

/// Ряд с переносом на следующую строку.
///
/// SwiftUI до `Layout` этого не умел, а `LazyVGrid` раздаёт колонкам одинаковую
/// ширину — подписи макросов бывают и в два символа, и в десять.
@available(macOS 13.0, *)
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
        CompatLabel(title: text, symbol: "hammer.fill")
            .font(.footnote)
            .compatForeground(.secondary)
    }
}
