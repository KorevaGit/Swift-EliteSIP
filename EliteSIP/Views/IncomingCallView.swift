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

            // Фон кнопок задан явно, а не через .borderedProminent с tint:
            // окно намеренно не забирает фокус, а системные акцентные стили в
            // неактивном окне выцветают в серый — кнопка ответа тогда выглядит
            // выключенной. Для единственного действия, которое оператор делает
            // под звонок, это недопустимо.
            HStack(spacing: 10) {
                Button {
                    onAnswer()
                } label: {
                    CallActionLabel(
                        title: "Ответить",
                        systemImage: "phone.fill",
                        fill: Theme.Palette.answer
                    )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)

                Button {
                    onDecline()
                } label: {
                    CallActionLabel(
                        title: "Отклонить",
                        systemImage: "phone.down.fill",
                        fill: Theme.Palette.decline
                    )
                }
                .buttonStyle(.plain)
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

private struct CallActionLabel: View {

    let title: String
    let systemImage: String
    let fill: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .fontWeight(.medium)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(fill, in: .rect(cornerRadius: Theme.Radius.control))
            .contentShape(.rect)
    }
}
