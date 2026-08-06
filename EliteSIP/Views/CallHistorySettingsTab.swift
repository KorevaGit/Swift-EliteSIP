import SwiftUI

/// Раздел «История» в окне «Управление».
///
/// Закрытый паролем, а не менеджерский, и причина не в осторожности. В записях
/// лежат номера лидов, то есть персональные данные, и «сколько мы их храним» —
/// политика заказчика. Менеджер, которому дали крутить этот срок, однажды
/// поставит его на год, потому что так удобнее ему, а отвечать за это будет не
/// он.
///
/// Кнопки «очистить историю» здесь нет намеренно. История — в том числе
/// свидетельство при разборе жалобы, и стирать её тому, о ком жалоба, нельзя;
/// администратору она тоже не нужна отдельной кнопкой — уменьшенный срок
/// применяется сразу и делает ровно то же самое, только заметно и объяснимо.
struct CallHistorySettingsTab: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section(header: Text("Локальная история звонков")) {
                Toggle("Вести историю звонков", isOn: Binding(
                    get: { model.settings.history.isEnabled },
                    set: { model.settings.history.isEnabled = $0 }
                ))

                if model.settings.history.isEnabled {
                    Stepper(
                        "Хранить \(model.settings.history.maximumAgeInDays) дн.",
                        value: Binding(
                            get: { model.settings.history.maximumAgeInDays },
                            set: { model.settings.history.maximumAgeInDays = $0 }
                        ),
                        in: 1...365
                    )

                    CompatLabel(
                        title: """
                            Записи старше срока удаляются: при запуске, раз в сутки и сразу после \
                            того, как срок уменьшили. Удалить запись вручную нельзя ни менеджеру, \
                            ни администратору.
                            """,
                        symbol: "clock"
                    )
                    .font(.footnote)
                    .compatForeground(.secondary)

                    CompatLabel(
                        title: """
                            В истории лежат номера лидов и SIP-логины — как пришли, без \
                            маскирования. В архив для поддержки она не попадает: там только журнал.
                            """,
                        symbol: "lock.shield.fill"
                    )
                    .font(.footnote)
                    .compatForeground(.secondary)
                }
            }

            Section(header: Text("Хранилище")) {
                CompatLabeledContent("Файл", value: AppSettings.CallHistorySettings.fileURL.compatPath)
                // Всего и по всем профилям, а не под отбором окна истории:
                // администратор смотрит сюда, чтобы понять, сколько
                // персональных данных лежит на машине. Окно истории при этом
                // остаётся ограниченным одним профилем — здесь число, а не
                // записи, и границу это не открывает.
                CompatLabeledContent("Записей", value: "\(model.historyStore?.totalCount() ?? 0)")
                CompatLabeledContent("Состояние", value: storageState)
            }
        }
        .compatGroupedForm()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
