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

            SettingsNote(verbatim: model.adminAccess.management.explanation)

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
                SettingsNote(verbatim: problem, isAlarming: true)
            }

            if let confirmation {
                SettingsNote(verbatim: confirmation)
            }
        }

        // Разделов «Забытый пароль» и «Что закрыто» здесь больше нет.
        //
        // Оба объясняли то, что человек в этот момент не спрашивает. Про
        // восстановление кода читают, когда пароль уже забыт, — а тогда до
        // этого раздела не дойти вовсе, он за паролем; сам путь написан там,
        // где он нужен, в окне входа. А список закрытого — это перечень
        // соседних разделов того же окна: администратор видит их в сайдбаре
        // прямо сейчас, и список стареет молча при первом же новом разделе.
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
