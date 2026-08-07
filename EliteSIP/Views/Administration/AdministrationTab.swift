import AdminAccess
import SwiftUI

/// Раздел «Доступ»: пароль администратора и то, кто управляет настройками.
///
/// Виден только в открытом режиме — то есть либо тому, кто знает пароль, либо
/// на машине, где пароля ещё нет. Второе и есть обычный путь установки: свежее
/// рабочее место настраивают целиком, а пароль ставят последним действием.
///
/// Состав этап 5 не менял: под файл конфигурации (M8) и обновления (M7h) место
/// в разделе оставлено, но неактивных строк не заведено. Погашенное читается
/// как «сломалось», а не как «будет позже», — та же причина, по которой у
/// менеджера нет погашенных вкладок.
struct AdministrationTab: View {

    @EnvironmentObject private var model: AppModel

    @State private var newPassword = ""
    @State private var repeatedPassword = ""
    @State private var problem: String?
    @State private var confirmation: String?

    var body: some View {
        SettingsSection("Кто управляет настройками") {
            SettingsRow("Режим") {
                Text(model.adminAccess.management.title)
                    .compatForeground(Theme.Palette.textSecondary)
            }

            SettingsNote(model.adminAccess.management.explanation)

            SettingsIndented {
                MilestoneNote("""
                    Значение меняется само: любое сохранение в этом окне объявляет \
                    настройки локальными. Второе значение — «настройки из файла \
                    конфигурации» — заработает в M8, когда появится сама загрузка \
                    конфига. Вернуть машину под конфиг после локальной правки можно \
                    будет только повторной загрузкой файла.
                    """)
            }
        }

        SettingsSection("Пароль администратора") {
            SettingsIndented {
                if model.isAdministrationProtectedIncludingDraft {
                    CompatLabel(title: "Пароль задан, закрытая часть закрыта", symbol: "lock.shield.fill")
                        .compatForeground(Theme.Palette.registered)
                } else {
                    CompatLabel(
                        title: "Пароль не задан — это окно откроет любой",
                        symbol: "exclamationmark.triangle.fill"
                    )
                    .compatForeground(Theme.Palette.failure)
                }
            }

            SettingsRow("Новый пароль") {
                SecureField("", text: $newPassword)
                    .labelsHidden()
                    .frame(maxWidth: 220)
            }

            SettingsRow("Ещё раз") {
                SecureField("", text: $repeatedPassword)
                    .labelsHidden()
                    .frame(maxWidth: 220)
            }

            SettingsButtonsRow {
                Button(model.isAdministrationProtectedIncludingDraft ? "Сменить пароль" : "Задать пароль") {
                    applyPassword()
                }
                .compatProminentButtonStyle()
                .disabled(newPassword.isEmpty || newPassword != repeatedPassword)

                Button("Снять пароль") { removePassword() }
                    .disabled(!model.isAdministrationProtectedIncludingDraft)
                    .compatHelp("Настройки станут доступны всем без вопросов")
            }

            if model.pendingAdminPassword != nil || model.pendingAdminPasswordRemoval {
                SettingsIndented {
                    CompatLabel(
                        title: "Применится при сохранении настроек",
                        symbol: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .compatForeground(Theme.Palette.unsaved)
                }
            }

            if !newPassword.isEmpty && newPassword != repeatedPassword {
                SettingsNote("Пароли не совпадают.", isAlarming: true)
            }

            if let problem {
                SettingsNote(problem, isAlarming: true)
            }

            if let confirmation {
                SettingsNote(confirmation)
            }
        }

        SettingsSection("Забытый пароль") {
            SettingsIndented {
                MilestoneNote("""
                    Пароль восстанавливается кодом из \(RecoveryCode.length) цифр: в окне \
                    входа — «Ввести код восстановления». Код показывает действующий \
                    пароль, а не сбрасывает его, потому что пароль совпадает с тем, что \
                    придёт в файле конфигурации.

                    Сейчас код один на все машины и зашит в сборку — то есть от того, \
                    кто откроет бинарник строками, он не защищает. Настоящей защитой он \
                    станет в M8, когда код начнёт приезжать файлом конфигурации — своим \
                    у каждого рабочего места.
                    """)
            }
        }

        SettingsSection("Что закрыто") {
            SettingsNote("""
                Профили и учётная запись целиком, коды АТС, адреса площадок и стук, макросы, \
                политика защиты от автокликеров, TLS без проверки сертификата, словарь очередей, \
                срок хранения истории, диагностика и обслуживание машины.
                """)

            SettingsNote("""
                Менеджеру остаются устройства и громкость, рингтон, выбор профиля и переключение \
                офис ↔ удалённо, «Исправить сеть», самопроверка голоса, тема оформления и сбор \
                логов для поддержки.
                """)
        }
    }

    /// Пароль уходит в черновик, а не в настройки: применит его кнопка
    /// «Сохранить» внизу окна вместе со всем остальным.
    private func applyPassword() {
        model.stageAdminPassword(newPassword)
        newPassword = ""
        repeatedPassword = ""
        problem = nil
        confirmation = "Принято. Пароль начнёт действовать после сохранения настроек."
    }

    private func removePassword() {
        model.stageAdminPasswordRemoval()
        newPassword = ""
        repeatedPassword = ""
        problem = nil
        confirmation = "Принято. После сохранения «Управление» откроется без пароля."
    }
}
