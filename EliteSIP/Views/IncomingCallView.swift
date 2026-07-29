import CallGuard
import SwiftUI

/// Содержимое плавающего окна входящего вызова.
///
/// Порядок «Ответить / Отклонить» не перемешивается: у этих действий разные
/// последствия, и провоцировать оператора на случайный отказ от лида
/// недопустимо. Перемешивается другое — какая из цифровых целей принимает
/// вызов; на этом ломается поиск кнопки по шаблону изображения.
struct IncomingCallView: View {

    let callerNumber: String
    let callerName: String?
    let challenge: CallGuardChallenge
    let activatesAt: ContinuousClock.Instant
    let onAttempt: @MainActor (CallGuardAttempt.Source, Character) -> Void
    let onDecline: @MainActor () -> Void

    @Environment(IncomingCallPanel.self) private var panel

    /// Активны ли цели. Отдельным состоянием, а не вычислением от текущего
    /// времени: SwiftUI не перерисовывает вид по ходу часов, и без явного
    /// переключения кнопки остались бы серыми до первого чужого события.
    @State private var isActive = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            caller
            Spacer(minLength: 0)
            actions
        }
        .padding(16)
        .frame(
            width: Theme.Metrics.incomingCallPanelSize.width,
            height: Theme.Metrics.incomingCallPanelSize.height
        )
        .themedSurface()
        .task {
            let remaining = activatesAt - .now
            if remaining > .zero {
                try? await Task.sleep(for: remaining)
            }
            isActive = true
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "phone.arrow.down.left.fill")
                .foregroundStyle(Theme.Palette.answer)
            Text("Входящий вызов")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()

            if let refusal = panel.refusal {
                Text(refusal)
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.decline)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: panel.refusal)
    }

    private var caller: some View {
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
    }

    private var prompt: String {
        guard challenge.hasChoice else { return "Ответить" }
        return "Ответить: нажмите \(challenge.answer)"
    }

    // Фон кнопок задан явно, а не через .borderedProminent с tint: окно
    // намеренно не забирает фокус, а системные акцентные стили в неактивном
    // окне выцветают в серый — цель ответа тогда выглядит выключенной. Для
    // единственного действия, которое оператор делает под звонок, это
    // недопустимо.
    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(prompt)
                .font(.caption)
                .foregroundStyle(isActive ? .secondary : .tertiary)

            HStack(spacing: 8) {
                // Клавиатурный путь ловится монитором событий в панели, а не
                // `keyboardShortcut`: окно намеренно не забирает фокус, и
                // ярлыки в нём просто не сработали бы.
                ForEach(challenge.targets, id: \.self) { target in
                    AnswerTargetButton(digit: target, isActive: isActive) {
                        onAttempt(.mouse, target)
                    }
                }

                Button {
                    onDecline()
                } label: {
                    Label("Отклонить", systemImage: "phone.down.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Theme.Palette.decline, in: .rect(cornerRadius: Theme.Radius.control))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Отклонить вызов")
                .accessibilityLabel("Отклонить вызов")
            }
        }
    }
}

/// Одна цифровая цель.
///
/// У неё намеренно нет действия доступности: `AXPress` нажимает элемент вообще
/// без событий мыши, и любая проверка живого человека при этом не выполняется.
/// Цена — недоступность для screen reader именно этих кнопок; «Отклонить»,
/// поле номера и остальное окно доступность сохраняют, и отказаться от вызова
/// можно и без мыши.
private struct AnswerTargetButton: View {

    let digit: Character
    let isActive: Bool
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Text(String(digit))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    Theme.Palette.answer.opacity(isActive ? 1 : 0.35),
                    in: .rect(cornerRadius: Theme.Radius.control)
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
        .animation(.easeOut(duration: 0.2), value: isActive)
    }
}
