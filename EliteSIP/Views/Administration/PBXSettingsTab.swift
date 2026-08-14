import SIPCore
import SwiftUI

/// Раздел «АТС»: всё, что задано не нами, а сервером заказчика.
///
/// Собран в этапе 5 из разных мест. Коды конференции лежали в «Тонах» — рядом с
/// длительностью тона в миллисекундах, куда попали лишь потому, что задаются
/// DTMF-строкой. Широкая полоса лежала в «Звуке», хотя это не про наушники, а
/// про то, что мы предлагаем серверу в SDP. Последовательности стука не было в
/// интерфейсе ни на чтение, ни на правку.
///
/// Общее у них одно: сверяются они не с рабочим местом, а с чужим сервером, и
/// сверяются вместе — одним заходом к администратору Asterisk.
struct PBXSettingsTab: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        SettingsSection("Конференция") {
            SettingsRow("Feature-code") {
                TextField("", text: Binding(
                    get: { model.settings.conference.featureCode },
                    set: { model.settings.conference.featureCode = $0 }
                ))
                .labelsHidden()
                .font(.system(.body, design: .monospaced))
                .frame(width: 90)
            }

            SettingsRow("Добавочный комнаты") {
                TextField("", text: Binding(
                    get: { model.settings.conference.roomExtension },
                    set: { model.settings.conference.roomExtension = $0 }
                ))
                .labelsHidden()
                .font(.system(.body, design: .monospaced))
                .frame(width: 90)
            }

            if !model.settings.conference.isUsable {
                SettingsNote(
                    "Код должен содержать только DTMF-символы и хотя бы один тон.",
                    isAlarming: true
                )
            }

            SettingsNote("""
                Код выполняет dynamic feature Asterisk и переводит оба плеча текущего разговора \
                в ConfBridge. В лаборатории это *3; боевой код нужно сверить с features.conf — \
                в выводе «core show features» с боевого сервера конференции нет вовсе.
                """)
        }

        SettingsSection("Кодеки") {
            SettingsToggleRow("Предлагать широкую полосу (G.722)", isOn: Binding(
                get: { model.settings.audio.prefersWideband },
                set: { model.settings.audio.prefersWideband = $0 }
            ))

            SettingsNote("""
                Предложение, а не требование: сервер выбирает из предложенного сам. Сверяется \
                со списком кодеков добавочного на АТС, а не с наушниками оператора.
                """)
        }

        PortKnockSection()
    }
}

// MARK: - Стук

/// Последовательность ICMP-пакетов, открывающая дорогу до АТС.
///
/// Самый опасный редактор в окне: ошибка в одной цифре обрывает связь всем
/// удалённым сотрудникам, и проявится она не сообщением, а тем, что регистрация
/// перестала проходить. Поэтому здесь показано всё, что можно посчитать
/// заранее, — число пакетов и время до первого REGISTER, — и рядом стоит
/// «Проверить», то есть тот же ручной стук, что и «Исправить сеть».
private struct PortKnockSection: View {

    @EnvironmentObject private var model: AppModel

    private var sequence: Binding<PortKnockSequence> {
        Binding(
            get: { model.settings.portKnock },
            set: { model.settings.portKnock = $0 }
        )
    }

    var body: some View {
        SettingsSection("Стук") {
            SettingsOrderedList(
                items: sequence.steps,
                emptyNote: "Шагов нет: стучать нечем, и удалённое место не подключится.",
                addTitle: "Добавить шаг",
                keepsSingleColumn: true,
                makeElement: { PortKnockStep(payloadBytes: 100) }
            ) { step in
                PortKnockStepRow(step: step)
            }

            SettingsDivider()

            SettingsRow("Пауза") {
                Stepper(
                    "\(paused) с между пакетами",
                    value: Binding(
                        get: { Int(model.settings.portKnock.spacingSeconds) },
                        set: { model.settings.portKnock.spacingSeconds = Double(max(1, $0)) }
                    ),
                    in: 1...10
                )
            }

            SettingsRow("Повтор") {
                Stepper(
                    "каждые \(repeated) мин, пока всё работает",
                    value: Binding(
                        get: { Int(model.settings.portKnock.repeatIntervalSeconds / 60) },
                        set: { model.settings.portKnock.repeatIntervalSeconds = Double(max(1, $0) * 60) }
                    ),
                    in: 1...60
                )
            }

            // Не украшение: это ровно та задержка, которую человек увидит перед
            // первой регистрацией. Без неё «приложение думает» выглядит как
            // поломка, а не как восемь пакетов с паузой в секунду.
            SettingsResolvedValue(
                verbatim: String(
                    format: NSLocalizedString(
                        "%1$@ · до первой регистрации %2$@ с",
                        comment: "сколько пакетов стука и сколько это займёт"
                    ),
                    packets,
                    duration
                )
            )

            SettingsNote("""
                Размер — это подпись: правило на шлюзе смотрит на длину пакета, а не на его \
                содержимое. Пустой хост означает «сервер из профиля»; заполненный — стучать \
                именно по нему.
                """)

            SettingsButtonsRow {
                Button("Проверить стук") {
                    Task { await model.repairNetwork() }
                }
                .compatHelp("Отправить последовательность прямо сейчас")

                if let status = model.networkRepairStatus {
                    Text(status)
                        .font(.footnote)
                        .compatForeground(Theme.Palette.textSecondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var paused: Int { Int(model.settings.portKnock.spacingSeconds) }
    private var repeated: Int { Int(model.settings.portKnock.repeatIntervalSeconds / 60) }

    /// Время стука целиком, как его считает сам `PortKnockSequence`: считать
    /// второй раз здесь значило бы однажды разойтись с тем, что происходит.
    private var duration: String {
        String(format: "%.0f", model.settings.portKnock.estimatedDuration.seconds)
    }

    /// Число пакетов вместе с существительным.
    ///
    /// Формы даёт каталог, а не своя функция на остатки от деления: у русского
    /// их три, у английского две, и правило, написанное под один язык, второму
    /// не годится ни при какой правке.
    private var packets: String {
        String.localizedStringWithFormat(
            NSLocalizedString("%lld пакетов", comment: "сколько пакетов в последовательности стука"),
            model.settings.portKnock.packetCount
        )
    }
}

private struct PortKnockStepRow: View {

    @Binding var step: PortKnockStep

    var body: some View {
        HStack(spacing: Theme.Metrics.elementSpacing) {
            TextField("хост из профиля", text: $step.host)
                .labelsHidden()
                .frame(minWidth: 120)

            TextField("", value: $step.payloadBytes, formatter: IntegerFormatter.shared)
                .labelsHidden()
                .frame(width: 56)
                .compatHelp("Байты данных ICMP — то же, что «ping -s»")

            Text("б")
                .compatForeground(Theme.Palette.textSecondary)

            TextField("", value: $step.count, formatter: IntegerFormatter.shared)
                .labelsHidden()
                .frame(width: 40)
                .compatHelp("Сколько пакетов подряд — то же, что «ping -c»")

            Text("шт")
                .compatForeground(Theme.Palette.textSecondary)
        }
    }
}
