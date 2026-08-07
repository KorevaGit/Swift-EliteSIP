import SwiftUI

/// Раздел «История» в окне «Управление».
///
/// Закрытый паролем, а не менеджерский, и причина не в осторожности. В записях
/// лежат номера лидов, то есть персональные данные, и «сколько мы их храним» —
/// политика заказчика. Менеджер, которому дали крутить этот срок, однажды
/// поставит его на год, потому что так удобнее ему, а отвечать за это будет не
/// он.
///
/// Чистки здесь нет: она в «Обслуживании», вместе с остальными действиями над
/// файлами машины. Здесь — политика, там — разовые действия, и путать их не
/// стоит: срок хранения работает каждый день, а чистку нажимают раз в жизни
/// рабочего места.
struct CallHistorySettingsTab: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        SettingsSection("Локальная история звонков") {
            SettingsToggleRow("Вести историю звонков", isOn: Binding(
                get: { model.settings.history.isEnabled },
                set: { model.settings.history.isEnabled = $0 }
            ))

            if model.settings.history.isEnabled {
                SettingsRow("Хранить") {
                    Stepper(
                        "\(model.settings.history.maximumAgeInDays) дн.",
                        value: Binding(
                            get: { model.settings.history.maximumAgeInDays },
                            set: { model.settings.history.maximumAgeInDays = $0 }
                        ),
                        in: 1...365
                    )
                }

                SettingsNote("""
                    Записи старше срока удаляются: при запуске, раз в сутки и сразу после того, \
                    как срок уменьшили. Уменьшение применяется по «Сохранить» — «Отменить» \
                    удалённые записи не вернёт.
                    """)

                SettingsNote("""
                    В истории лежат номера лидов и SIP-логины — как пришли, без маскирования. \
                    В архив для поддержки она не попадает: там только журнал.
                    """)
            }
        }

        SettingsSection("Хранилище") {
            // Всего и по всем профилям, а не под отбором окна истории:
            // администратор смотрит сюда, чтобы понять, сколько персональных
            // данных лежит на машине. Окно истории при этом остаётся
            // ограниченным одним профилем — здесь число, а не записи, и границу
            // это не открывает.
            SettingsRow("Записей") {
                Text("\(model.historyStore?.totalCount() ?? 0)")
                    .compatForeground(Theme.Palette.textSecondary)
            }

            SettingsRow("Состояние") {
                Text(storageState)
                    .compatForeground(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { model.reloadHistory() }
    }

    /// Про повреждённую базу администратор должен узнать здесь, а не из
    /// журнала: он единственный, кто может что-то с этим сделать.
    private var storageState: String {
        guard model.settings.history.isEnabled else { return "выключена" }
        guard let store = model.historyStore else { return "не открыта" }
        switch store.openOutcome {
        case .ready:
            return "в порядке"
        case .replacedDamaged(let damaged):
            return "была повреждена, отставлена в \(damaged.lastPathComponent)"
        case .unavailable(let reason):
            return "недоступна: \(reason)"
        }
    }
}
