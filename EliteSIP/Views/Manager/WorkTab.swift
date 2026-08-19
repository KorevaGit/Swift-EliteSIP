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
struct WorkTab: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        SettingsSection("Рабочее место") {
            SettingsRow("Работа") {
                Picker("", selection: Binding(
                    get: { model.workplaceSite },
                    set: { site in Task { await model.setProfileSite(site, for: model.settings.profiles.activeID) } }
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
            .disabled(!model.canSwitchProfile)

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

            if !model.canSwitchProfile {
                SettingsNote("Идёт разговор — переключить сейчас нельзя.", isAlarming: true)
            }
        }

        SettingsSection("Если не подключается") {
            SettingsButtonsRow {
                Button("Исправить сеть") {
                    Task { await model.repairNetwork() }
                }
            }

            SettingsNote("""
                Открывает дорогу до АТС снаружи — один раз и прямо сейчас. Нужно, когда из \
                дома перестало подключаться без видимой причины: у домашнего интернета \
                сменился адрес, а шлюз помнит прежний.
                """)

            if let status = model.networkRepairStatus {
                SettingsNote(verbatim: status)
            }
        }
    }
}
