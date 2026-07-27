import SwiftUI

struct PhonePanelView: View {

    @Environment(AppModel.self) private var model
    @Environment(IncomingCallPanel.self) private var incomingCall

    var body: some View {
        VStack(spacing: Theme.Metrics.sectionSpacing) {
            RegistrationBadge(state: model.registration)

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
        .background {
            // Заголовок скрыт, поэтому окно надо таскать за фон.
            WindowAccessor { window in
                window.isMovableByWindowBackground = true
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
            #endif
        }
    }

    private func showIncomingCallDemo() {
        incomingCall.show(
            callerNumber: "22998",
            callerName: "Проверка размещения",
            placement: model.placement,
            onAnswer: {},
            onDecline: {}
        )
    }

    private var callButton: some View {
        Button {
            // M2: здесь появится исходящий INVITE.
        } label: {
            Label("Позвонить", systemImage: "phone.fill")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.Palette.answer)
        .disabled(!model.canPlaceCall || !model.hasDialedNumber)
        .help("Исходящие звонки появятся в M2, вместе с транспортом и медиа")
    }

    private var debugSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            MilestoneNote("Скелет M0: окна и сборка. Регистрация — M1, звук — M2.")

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

    let state: AppModel.RegistrationState

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(state.title)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .themedControlSurface()
    }

    private var color: Color {
        switch state {
        case .offline: Theme.Palette.offline
        case .registering: Theme.Palette.connecting
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
                .font(.system(size: 26, weight: .light, design: .rounded))
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
