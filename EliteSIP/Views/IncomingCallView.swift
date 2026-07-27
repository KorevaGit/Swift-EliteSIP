import SwiftUI

/// Содержимое плавающего окна входящего вызова.
///
/// Порядок кнопок фиксированный: «Ответить» слева, «Отклонить» справа.
/// Рандомизируется только позиция окна. Если цель — сбить мышечную память
/// целиком, в M3 сюда добавится и перетасовка кнопок, но по умолчанию менять
/// местами действия с разными последствиями опасно.
struct IncomingCallView: View {

    let callerNumber: String
    let callerName: String?
    let onAnswer: @MainActor () -> Void
    let onDecline: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "phone.arrow.down.left.fill")
                    .foregroundStyle(Theme.Palette.answer)
                Text("Входящий вызов")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(callerNumber)
                    .font(.system(size: 24, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                if let callerName, !callerName.isEmpty {
                    Text(callerName)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 10) {
                Button {
                    onAnswer()
                } label: {
                    Label("Ответить", systemImage: "phone.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.answer)
                .keyboardShortcut(.defaultAction)

                Button {
                    onDecline()
                } label: {
                    Label("Отклонить", systemImage: "phone.down.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(Theme.Palette.decline)
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(
            width: Theme.Metrics.incomingCallPanelSize.width,
            height: Theme.Metrics.incomingCallPanelSize.height
        )
        .themedSurface()
    }
}
