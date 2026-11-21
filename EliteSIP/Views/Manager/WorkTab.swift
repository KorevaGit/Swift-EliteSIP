import SIPCore
import SwiftUI

/// Раздел «Работа»: откуда менеджер работает сегодня — из офиса или из дома.
///
/// **Почему это менеджерская настройка, а не административная.** Пометка
/// рабочего места жила в «Управлении» с M7b и была убрана в этапе 5 по доводу
/// «рабочее место у машины одно и не меняется». Довод верен для машины и неверен
/// для человека: тот же менеджер с тем же номером сидит то в офисе, то дома, и
/// знает об этом только он. Администратора в этот момент рядом нет, а
/// административный пароль оператору не дают — и не должны: за дверью аккаунты и
/// защита от автокликеров, а не «я сегодня из дома».
///
/// **Что происходит по переключению.** Не пометка, а переезд: вместе с местом
/// меняется адрес АТС по паре из настроек (`siteAddresses`), регистрация
/// снимается и поднимается заново, а стук по портам уходит сам на первой же
/// регистрации по новому адресу. Разбор — `AppModel.setProfileSite`.
///
/// **Чего здесь нет.** Варианта «определять самому»: третья кнопка означала бы
/// «не выбирать», а выбирает как раз человек. Догадка по адресу осталась
/// умолчанием модели и показывается выбранной — `AppModel.workplaceSite`.
///
/// **Закрепление из Spark.** Администратор может закрепить формат за местом —
/// тогда переключатель гаснет, а при закреплённом офисе гаснет и «Исправить
/// сеть». Снять закрепление на месте можно административным паролем, ценой
/// оффлайна — разбор в `AppModel+WorkFormat`.
struct WorkTab: View {

    @EnvironmentObject private var model: AppModel

    /// Окно административного пароля — своё, не общее с «Управлением»: после
    /// входа оно не открывает окно, а оставляет человека здесь.
    @State private var isAskingForPassword = false

    var body: some View {
        SettingsSection("Рабочее место") {
            SettingsRow("Работа") {
                Picker("", selection: Binding(
                    get: { model.workplaceSite },
                    set: { site in Task { await model.chooseWorkplaceSite(site) } }
                )) {
                    Text("Офис").tag(SIPProfileSite.office)
                    Text("Из дома").tag(SIPProfileSite.remote)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                // Та же ширина, что у темы и языка в «Оформлении»: три
                // переключателя одного вида в одном окне на разной ширине
                // читаются как разные элементы.
                .frame(maxWidth: 220, alignment: .leading)
            }
            // Посреди разговора переключать нельзя — тот же запрет, что у смены
            // профиля и у отключения (M6b). Сегменты гасятся, а не молча
            // отказывают: отказ после нажатия оператор читает как поломку.
            .disabled(!model.canSwitchProfile || model.isWorkplaceSwitchLocked)

            SettingsRow("Адрес АТС") {
                Text(verbatim: model.settings.account.domain)
                    .compatMonospacedDigit()
                    .compatForeground(Theme.Palette.textSecondary)
            }

            SettingsNote("""
                Переключение меняет адрес АТС и заново поднимает регистрацию: из дома \
                внутренний адрес недостижим, а из офиса внешний ведёт на тот же сервер \
                длинной дорогой через шлюз.
                """)

            if model.isWorkplaceSwitchLocked {
                SettingsNote("Формат работы закреплён администратором.")
                SettingsButtonsRow {
                    Button("Снять закрепление…") { isAskingForPassword = true }
                }
            } else if model.lockedWorkplaceSite != nil {
                // Закрепление снято паролем, но машина ещё под панелью: цену
                // переключения надо видеть до нажатия, а не после.
                SettingsNote(
                    "Закрепление снято. Переключение переведёт машину в оффлайн.",
                    isAlarming: true
                )
            }

            if !model.canSwitchProfile {
                SettingsNote("Идёт разговор — переключить сейчас нельзя.", isAlarming: true)
            }
        }
        .sheet(isPresented: $isAskingForPassword) {
            AdminUnlockView(isPresented: $isAskingForPassword, purpose: .workplace)
                .environmentObject(model)
        }

        SettingsSection("Если не подключается") {
            SettingsButtonsRow {
                Button("Исправить сеть") {
                    Task { await model.repairNetwork() }
                }
                .disabled(model.isNetworkRepairLocked)
            }

            SettingsNote("""
                Открывает дорогу до АТС снаружи — один раз и прямо сейчас. Нужно, когда из \
                дома перестало подключаться без видимой причины: у домашнего интернета \
                сменился адрес, а шлюз помнит прежний.
                """)

            if model.isNetworkRepairLocked {
                SettingsNote("Место закреплено за офисом — из офиса АТС достижима напрямую.")
            }

            if let status = model.networkRepairStatus {
                SettingsNote(verbatim: status)
            }
        }
    }
}
