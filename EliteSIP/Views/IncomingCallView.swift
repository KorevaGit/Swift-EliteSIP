import CallGuard
import SwiftUI

/// Про что этот вызов — и, значит, что стоит на главном месте окна.
///
/// Два случая, а не запасная цепочка внутри одного. По боевым CDR на плечо
/// агента приходит CallerID очереди, а не клиента: клиентский лежит в
/// `accountcode` и в SIP не приезжает вовсе. То есть на раздаче номер одинаков
/// от вызова к вызову и не сообщает оператору ничего — а название кампании
/// сообщает, как здороваться. На обычном звонке всё наоборот: номер коллеги по
/// внутреннему или клиента — это и есть главное.
///
/// Различает случаи словарь очередей у администратора: номер найден — раздача,
/// не найден — обычный звонок. Отдельного признака «это очередь» в SIP нет, а
/// гадать по длине номера или по имени `AutoDialer` значило бы зашить в клиент
/// чужой диалплан.
enum IncomingCallSubject: Equatable {

    /// Раздача из очереди. Номер не показывается вовсе: он один и тот же.
    case queue(title: String)

    /// Обычный звонок: номер главным, имя под ним, если сервер его прислал.
    case caller(number: String, name: String?)

    /// Разбор того, что пришло в INVITE, по словарю очередей.
    ///
    /// Одно место на все вызовы окна, включая проверочный показ из настроек:
    /// иначе проверка показывала бы не то, что увидит оператор на боевом
    /// вызове, — а ради этого её и открывают.
    init(callerNumber: String, callerName: String?, queues: AppSettings.QueueDirectory) {
        if let title = queues.title(forCallerNumber: callerNumber) {
            self = .queue(title: title)
        } else {
            self = .caller(number: callerNumber, name: callerName)
        }
    }
}

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

    let subject: IncomingCallSubject
    let challenge: CallGuardChallenge
    let isGuarded: Bool
    let onAttempt: @MainActor (Character) -> Void
    let onDecline: @MainActor () -> Void

    @EnvironmentObject private var panel: IncomingCallPanel

    var body: some View {
        // Промежутки заданы поимённо, а не общим spacing: ярусы здесь неравные
        // по смыслу — шапка и карточка отвечают на «что это за вызов» и стоят
        // близко, кнопки отделены, потому что это уже действие.
        //
        // Без Spacer и без заданной высоты: окно подгоняется под содержимое.
        // Растянутый по фиксированной высоте столбец оставлял пустую полосу
        // между именем звонящего и кнопками.
        VStack(alignment: .leading, spacing: 0) {
            header
            caller
                .padding(.top, Theme.Gap.incomingHeaderToCaller)
            actions
                .padding(.top, Theme.Gap.incomingCallerToActions)
        }
        .padding(Theme.Metrics.contentPadding)
        .frame(width: Theme.Metrics.incomingCallPanelWidth)
        .themedIncomingSurface()
    }

    /// Шапка: цветной якорь, подпись, щит.
    ///
    /// Причина отказа занимает место подписи «Входящий вызов». Одно место на
    /// оба сообщения и в обоих состояниях окна: отдельная строка под отказ
    /// дёргала бы высоту окна прямо под рукой оператора, а подпись в этот
    /// момент всё равно ничего не сообщает — что вызов входящий, он уже понял.
    private var header: some View {
        HStack(spacing: Theme.Metrics.elementSpacing) {
            anchor

            Text(panel.refusal ?? "Входящий вызов")
                .font(Theme.Text.incomingCaption)
                .compatForeground(panel.refusal == nil ? Color.secondary : Theme.Palette.decline)
                .animation(.easeOut(duration: 0.15), value: panel.refusal)

            Spacer(minLength: Theme.Metrics.sectionSpacing)

            // Щит — честный индикатор того, что защита работает. Когда её
            // выключили, значка нет, и это видно на скриншоте экрана.
            if isGuarded {
                CompatSymbol(name: "lock.shield.fill", size: Theme.Icon.medium)
                    .compatForeground(Theme.Palette.textTertiary)
                    .compatAccessibilityLabel("Защита от автокликеров включена")
            }
        }
    }

    /// Цветной якорь — то, чем окно набирает заметность.
    ///
    /// Оно встаёт в случайную точку поверх произвольной CRM, и найти его глазами
    /// оператор обязан за доли секунды. Плотностью фона это не решается: фон у
    /// окна стеклянный и тон берёт у того, что под ним.
    ///
    /// Цена названа прямо и записана в `docs/anti-autoclicker.md`: постоянный
    /// узнаваемый якорь обесценивает случайную позицию против кликера по
    /// шаблону изображения — тот находит якорь и жмёт по постоянному смещению.
    /// Принято потому, что позицией мы от шаблонного кликера и так не
    /// защищались: от него защищает цифровая цель. В обычном режиме на окне и
    /// так есть зелёная «Ответить», и якорь шаблону ничего нового не даёт; в
    /// цифровом принимающая цифра случайна, и клик по постоянному смещению
    /// попадает в цель в одном случае из четырёх.
    /// Фигура — та же, что в истории (`CallOutcomeBadge`), а не своя картинка
    /// из комплекта. Оператор видит эти два окна каждый день, и входящий вызов
    /// в них должен выглядеть одинаково: залитый кружок со стрелкой внутрь.
    /// Заодно стрелка рисуется путём и остаётся резкой на любом размере, а
    /// комплект иконок для Catalina от неё не растёт.
    ///
    /// Размер — иконочный (`Icon.large`), а не тот, что в истории. Там значок
    /// главный в строке и потому крупный, здесь он стоит рядом с подписью в
    /// 11 точек, и на двадцати двух возвышался над ней, как ярлык над текстом.
    /// Якорю хватает цвета: заметность даёт зелёное пятно, а не его площадь.
    private var anchor: some View {
        CallOutcomeBadge(
            isIncoming: true,
            isCompleted: true,
            color: Theme.Palette.outcomeAnswered,
            size: Theme.Icon.large
        )
    }

    /// Карточка вызова. Главный ярус — одна строка с ужатием, без переноса:
    /// длина чужого названия не имеет права двигать высоту окна.
    @ViewBuilder
    private var caller: some View {
        switch subject {
        case .queue(let title):
            Text(title)
                .font(Theme.Text.incomingTitle)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

        case .caller(let number, let name):
            VStack(alignment: .leading, spacing: Theme.Metrics.hairSpacing) {
                Text(number)
                    .font(Theme.Text.incomingTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                if let name, !name.isEmpty {
                    Text(name)
                        .font(Theme.Text.incomingLine)
                        .compatForeground(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if challenge.hasChoice {
            VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
                prompt
                digitTargets
                declineButton
            }
        } else {
            plainActions
        }
    }

    /// Подсказка набрана одним кеглем целиком.
    ///
    /// Цифра внутри неё раньше говорила своим, четвёртым по счёту: 15 pt против
    /// 13 у остального текста. Два кегля в одной строке ради одного символа —
    /// разнобой, а не иерархия; выделяет её цвет, а не размер.
    private var prompt: some View {
        HStack(spacing: Theme.Metrics.tightSpacing) {
            Text("Чтобы ответить, нажмите")
                .compatForeground(.secondary)
            Text(String(challenge.answer))
                .compatForeground(.primary)
        }
        .font(Theme.Text.incomingLine)
    }

    private var digitTargets: some View {
        HStack(spacing: Theme.Metrics.sectionSpacing) {
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
            HStack(spacing: Theme.Metrics.elementSpacing) {
                CompatSymbol(name: "phone.down.fill")
                Text("Отклонить")
            }
            .font(Theme.Text.controlLabel)
            .compatForeground(Theme.Palette.decline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Metrics.incomingButtonPadding)
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
        HStack(spacing: Theme.Metrics.sectionSpacing) {
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
                .padding(.vertical, Theme.Metrics.incomingButtonPadding)
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
            HStack(spacing: Theme.Metrics.elementSpacing) {
                CompatSymbol(name: icon)
                Text(title)
            }
            .font(Theme.Text.controlLabel)
            .compatForeground(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Metrics.incomingButtonPadding)
            .compatBackground(fill, cornerRadius: Theme.Radius.control)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverHighlight()
    }
}
