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
            callerNumber: "22998",
            callerName: "Проверка размещения",
            placement: model.settings.incomingCall,
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
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isInCall ? Theme.Palette.decline : Theme.Palette.answer)
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
            MilestoneNote("M1 готов. Звонки — M2, приём — M3.")

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
                    .font(.callout)
                    .lineLimit(1)
                if let detail = model.registrationDetail {
                    Text(detail)
                        .font(.caption2)
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
            Text(model.hasDialedNumber ? model.dialedNumber : "Номер")
                .font(.system(size: Theme.Metrics.dialedNumberFontSize, weight: .light, design: .rounded))
                .foregroundStyle(model.hasDialedNumber ? .primary : .tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, alignment: .leading)

            if model.hasDialedNumber {
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
