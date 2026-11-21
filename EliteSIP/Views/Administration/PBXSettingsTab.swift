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
        SettingsSection("Адреса АТС", icon: "server") {
            WorkplaceRoute(isRemote: model.workplaceSite == .remote)

            SettingsRow("Из офиса") {
                TextField("", text: Binding(
                    get: { model.settings.siteAddresses.office },
                    set: { model.settings.siteAddresses.office = $0 }
                ))
                .labelsHidden()
                .frame(width: 220)
            }

            SettingsRow("Из дома") {
                TextField("", text: Binding(
                    get: { model.settings.siteAddresses.remote },
                    set: { model.settings.siteAddresses.remote = $0 }
                ))
                .labelsHidden()
                .frame(width: 220)
            }

            if model.settings.siteAddresses.isEmpty {
                SettingsNote(
                    "Половина пары пуста — переключение «Работы» адрес не поменяет.",
                    isAlarming: true
                )
            } else if !model.settings.siteAddresses.recognizes(model.settings.account.domain) {
                SettingsNote(
                    "Адрес АТС активного профиля не из этой пары — переезд ему не достанется.",
                    isAlarming: true
                )
            } else {
                SettingsHint("Между этими адресами профиль переключает «Работа» в настройках.")
            }
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
        SettingsSection("Стук по портам", icon: "shield-check") {
            SettingsOrderedList(
                items: sequence.steps,
                emptyNote: "Шагов нет: стучать нечем, и удалённое место не подключится.",
                addTitle: "Добавить шаг",
                keepsSingleColumn: true,
                makeElement: { PortKnockStep(payloadBytes: 100) }
            ) { step in
                PortKnockStepRow(step: step)
            }

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

            SettingsHint("Размер пакета — подпись для шлюза. Пустой хост — АТС из профиля.")

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

/// «Конференция» — в «Клавишах», как функции АТС в «Управлении» Windows 1.0.4:
/// это та же команда тонами в разговор, что и макросы.
struct ConferenceSettingsSection: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        SettingsSection("Конференция", icon: "headset") {
            SettingsRow("Feature-code") {
                TextField("", text: Binding(
                    get: { model.settings.conference.featureCode },
                    set: { model.settings.conference.featureCode = $0 }
                ))
                .labelsHidden()
                .font(.system(.body, design: .monospaced))
                .frame(width: 90)
            }

            SettingsRow("Номер комнаты") {
                TextField("", text: Binding(
                    get: { model.settings.conference.roomExtension },
                    set: { model.settings.conference.roomExtension = $0 }
                ))
                .labelsHidden()
                .font(.system(.body, design: .monospaced))
                .frame(width: 90)
            }

            if model.settings.conference.featureCode.isEmpty {
                SettingsHint("""
                    Код не задан — кнопка «Конференция» у оператора недоступна.
                    """)
            } else if !model.settings.conference.isUsable {
                SettingsNote(
                    "Код должен содержать только DTMF-символы и хотя бы один тон.",
                    isAlarming: true
                )
            }

            SettingsHint("Код уходит тонами в разговор; вход в комнату сервер не подтверждает.")

            SettingsHint("В «core show features» боевого сервера кода конференции нет — сверьте с АТС.")
        }
    }
}
