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
///
/// Принять вызов можно только мышью и сразу: клавиатурного пути нет намеренно
/// (нажатие клавиши не оставляет защите ни одного признака живого человека), а
/// задержки активации нет по решению заказчика — её цену платил оператор на
/// каждом вызове. «Отклонить» доступен и с клавиатуры, и для screen reader.
struct IncomingCallView: View {

    let callerNumber: String
    let callerName: String?
    let challenge: CallGuardChallenge
    let isGuarded: Bool
    let onAttempt: @MainActor (Character) -> Void
    let onDecline: @MainActor () -> Void

    @EnvironmentObject private var panel: IncomingCallPanel

    var body: some View {
        // Без Spacer и без заданной высоты: окно подгоняется под содержимое.
        // Растянутый по фиксированной высоте столбец оставлял пустую полосу
        // между именем звонящего и кнопками.
        VStack(alignment: .leading, spacing: challenge.hasChoice ? 12 : 14) {
            header
            caller

            if challenge.hasChoice {
                prompt
                digitTargets
                declineButton
            } else {
                plainActions
            }
        }
        .padding(16)
        .frame(width: Theme.Metrics.incomingCallPanelWidth)
        .themedSurface()
    }

    /// Причина отказа занимает место подписи «Входящий вызов».
    ///
    /// Одно место на оба сообщения и в обоих состояниях окна: отдельная строка
    /// под отказ дёргала бы высоту окна прямо под рукой оператора, а подпись в
    /// этот момент всё равно ничего не сообщает — что вызов входящий, он уже
    /// понял.
    private var header: some View {
        HStack(spacing: 6) {
            CompatSymbol(name: "phone.arrow.down.left.fill")
                .compatForeground(Theme.Palette.answer)
            Text(panel.refusal ?? "Входящий вызов")
                .compatForeground(panel.refusal == nil ? Color.secondary : Theme.Palette.decline)
                .animation(.easeOut(duration: 0.15), value: panel.refusal)
            Spacer(minLength: 8)

            // Щит — честный индикатор того, что защита работает. Когда её
            // выключили, значка нет, и это видно на скриншоте экрана.
            if isGuarded {
                CompatSymbol(name: "lock.shield.fill")
                    .compatForeground(Theme.Palette.tertiary)
                    .compatHelp("Защита от автокликеров включена")
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
                    .compatForeground(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var prompt: some View {
        HStack(spacing: 4) {
            Text("Чтобы ответить, нажмите")
                .font(Theme.Text.incomingDetail)
                .compatForeground(.secondary)
            Text(String(challenge.answer))
                .font(Theme.Text.incomingTarget)
                .compatForeground(.primary)
        }
    }

    private var digitTargets: some View {
        HStack(spacing: 8) {
            // Только мышью: цифра на клавиатуре вызов не принимает. Клавиатурное
            // нажатие не оставляет защите ни одного признака живого человека, и
            // отдельного пути для него здесь нет.
            ForEach(challenge.targets, id: \.self) { target in
                DigitTargetButton(digit: target) {
                    onAttempt(target)
                }
            }
        }
    }

    private var declineButton: some View {
        Button(action: onDecline) {
            HStack(spacing: 6) {
                CompatSymbol(name: "phone.down.fill")
                Text("Отклонить")
            }
            .font(Theme.Text.controlLabel)
            .compatForeground(Theme.Palette.decline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .themedControlSurface()
        .hoverHighlight()
        .compatCancelShortcut()
        .compatAccessibilityLabel("Отклонить вызов")
    }

    /// Обычная пара кнопок, когда подтверждение цифрой выключено.
    private var plainActions: some View {
        HStack(spacing: 10) {
            // Кнопка активна с первого кадра: локальной задержки активации нет.
            FilledCallButton(
                title: "Ответить",
                icon: "phone.fill",
                fill: Theme.Palette.answer
            ) {
                onAttempt(challenge.answer)
            }
            // У цели приёма намеренно нет действия доступности: `AXPress`
            // нажимает элемент вообще без событий мыши, и ни одна проверка
            // живого человека при этом не выполняется. Цена — недоступность
            // для screen reader именно этой кнопки; «Отклонить» и номер
            // звонящего доступность сохраняют, то есть отказаться от вызова
            // можно и без мыши.
            .compatAccessibilityHidden(true)

            FilledCallButton(
                title: "Отклонить",
                icon: "phone.down.fill",
                fill: Theme.Palette.decline,
                action: onDecline
            )
            .compatCancelShortcut()
            .compatAccessibilityLabel("Отклонить вызов")
        }
    }
}

/// Одна цифровая цель: нейтральная поверхность, как у остальных элементов окна.
private struct DigitTargetButton: View {

    let digit: Character
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Text(String(digit))
                .font(Theme.Text.controlKey)
                .compatForeground(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .themedControlSurface()
        .hoverHighlight()
        // Нажать через Accessibility API нельзя — см. пояснение у «Ответить».
        .compatAccessibilityHidden(true)
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
                CompatSymbol(name: icon)
                Text(title)
            }
            .font(Theme.Text.controlLabel)
            .compatForeground(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .compatBackground(fill, cornerRadius: Theme.Radius.control)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverHighlight()
    }
}
