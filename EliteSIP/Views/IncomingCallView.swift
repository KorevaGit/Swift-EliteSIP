import CallGuard
import SwiftUI

/// Содержимое плавающего окна входящего вызова.
///
/// Два состояния из макета, и переключает их одна настройка. Обычное: зелёная
/// «Ответить» и красная «Отклонить» рядом. С подтверждением цифрой: ряд
/// нейтральных цифровых целей, а «Отклонить» уезжает под них отдельной строкой.
///
/// Цели именно нейтральные, а не зелёные, и это часть защиты, а не вкусовщина:
/// кликер по шаблону изображения ищет на экране цветное пятно кнопки. Когда
/// все четыре цели выглядят одинаково, искать нечего.
///
/// Порядок «ответить / отклонить» при этом не перемешивается: у этих действий
/// разные последствия, и провоцировать оператора на случайный отказ от лида
/// недопустимо.
struct IncomingCallView: View {

    let callerNumber: String
    let callerName: String?
    let challenge: CallGuardChallenge
    let activatesAt: ContinuousClock.Instant
    let isGuarded: Bool
    let onAttempt: @MainActor (CallGuardAttempt.Source, Character) -> Void
    let onDecline: @MainActor () -> Void

    @Environment(IncomingCallPanel.self) private var panel

    /// Активны ли цели. Отдельным состоянием, а не вычислением от текущего
    /// времени: SwiftUI не перерисовывает вид по ходу часов, и без явного
    /// переключения кнопки остались бы серыми до первого чужого события.
    @State private var isActive = false

    private var size: CGSize {
        Theme.Metrics.incomingCallPanelSize(withDigitChallenge: challenge.hasChoice)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: challenge.hasChoice ? 12 : 14) {
            header
            caller
            Spacer(minLength: 0)

            if challenge.hasChoice {
                prompt
                digitTargets
                declineButton
            } else {
                plainActions
            }
        }
        .padding(16)
        .frame(width: size.width, height: size.height)
        .themedSurface()
        .task {
            let remaining = activatesAt - .now
            if remaining > .zero {
                try? await Task.sleep(for: remaining)
            }
            isActive = true
        }
    }

    /// Причина отказа занимает место подписи «Входящий вызов».
    ///
    /// Одно место на оба сообщения и в обоих состояниях окна: высота у него
    /// фиксированная, лишней строке взяться неоткуда, а подпись в этот момент
    /// всё равно ничего не сообщает — что вызов входящий, оператор уже понял.
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "phone.arrow.down.left.fill")
                .foregroundStyle(Theme.Palette.answer)
            Text(panel.refusal ?? "Входящий вызов")
                .foregroundStyle(panel.refusal == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.Palette.decline))
                .animation(.easeOut(duration: 0.15), value: panel.refusal)
            Spacer(minLength: 8)

            // Щит — честный индикатор того, что защита работает. Когда её
            // выключили, значка нет, и это видно на скриншоте экрана.
            if isGuarded {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.tertiary)
                    .help("Защита от автокликеров включена")
            }
        }
        .font(Theme.Text.incomingCaption)
    }

    private var caller: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(callerNumber)
                .font(Theme.Text.incomingNumber)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            if let callerName, !callerName.isEmpty {
                Text(callerName)
                    .font(Theme.Text.incomingDetail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var prompt: some View {
        HStack(spacing: 4) {
            Text("Чтобы ответить, нажмите")
                .font(Theme.Text.incomingDetail)
                .foregroundStyle(.secondary)
            Text(String(challenge.answer))
                .font(Theme.Text.incomingTarget)
                .foregroundStyle(.primary)
        }
    }

    private var digitTargets: some View {
        HStack(spacing: 8) {
            // Клавиатурный путь ловится монитором событий в панели, а не
            // `keyboardShortcut`: окно намеренно не забирает фокус, и ярлыки в
            // нём просто не сработали бы.
            ForEach(challenge.targets, id: \.self) { target in
                DigitTargetButton(digit: target, isActive: isActive) {
                    onAttempt(.mouse, target)
                }
            }
        }
    }

    private var declineButton: some View {
        Button(action: onDecline) {
            HStack(spacing: 6) {
                Image(systemName: "phone.down.fill")
                Text("Отклонить")
            }
            .font(Theme.Text.controlLabel)
            .foregroundStyle(Theme.Palette.decline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .themedControlSurface()
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("Отклонить вызов")
    }

    /// Обычная пара кнопок, когда подтверждение цифрой выключено.
    private var plainActions: some View {
        HStack(spacing: 10) {
            FilledCallButton(
                title: "Ответить",
                icon: "phone.fill",
                fill: Theme.Palette.answer.opacity(isActive ? 1 : 0.35)
            ) {
                onAttempt(.mouse, challenge.answer)
            }
            // У цели приёма намеренно нет действия доступности: `AXPress`
            // нажимает элемент вообще без событий мыши, и ни одна проверка
            // живого человека при этом не выполняется. Цена — недоступность
            // для screen reader именно этой кнопки; «Отклонить» и номер
            // звонящего доступность сохраняют, то есть отказаться от вызова
            // можно и без мыши.
            .accessibilityHidden(true)
            .animation(.easeOut(duration: 0.2), value: isActive)

            FilledCallButton(
                title: "Отклонить",
                icon: "phone.down.fill",
                fill: Theme.Palette.decline,
                action: onDecline
            )
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Отклонить вызов")
        }
    }
}

/// Одна цифровая цель: нейтральная поверхность, как у остальных элементов окна.
private struct DigitTargetButton: View {

    let digit: Character
    let isActive: Bool
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Text(String(digit))
                .font(Theme.Text.controlKey)
                .foregroundStyle(isActive ? .primary : .tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .themedControlSurface()
        // Нажать через Accessibility API нельзя — см. пояснение у «Ответить».
        .accessibilityHidden(true)
        .animation(.easeOut(duration: 0.2), value: isActive)
    }
}

/// Кнопка с заливкой под цвет действия.
///
/// Заливка задана явно, а не через `.borderedProminent` с tint: окно намеренно
/// не забирает фокус, а системные акцентные стили в неактивном окне выцветают в
/// серый — кнопка ответа тогда выглядит выключенной.
private struct FilledCallButton: View {

    let title: String
    let icon: String
    let fill: Color
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
            }
            .font(Theme.Text.controlLabel)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(fill, in: .rect(cornerRadius: Theme.Radius.control))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
