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
                Text(verbatim: mode)
                    .compatForeground(Theme.Palette.textSecondary)
            }

            SettingsNote(verbatim: explanation)

            // Раньше здесь стояло `AdminManagement` — «локально или из файла
            // конфигурации». Файла нет с 25 августа 2026, и перечисление
            // убрано: с одним оставшимся значением оно начало врать — машина
            // под панелью показывала бы «Локальный режим». Ответ читается
            // теперь оттуда, где он и живёт, — из `settings.panel`.
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

    /// Кто управляет настройками — теми же словами, что в полосе низа окна.
    ///
    /// Слова «Локальный режим» отсюда ушли 27 августа 2026: это название
    /// состояния изнутри реализации, а строка отвечает на «кто задаёт
    /// настройки». Отвечает она теперь именем ответственного, а не термином.
    private var mode: String {
        model.settings.panel.isManaged
            ? NSLocalizedString("Панель EliteSIP", comment: "кто управляет настройками")
            : NSLocalizedString("Администратор этой машины", comment: "кто управляет настройками")
    }

    /// Почему так — и где это меняется.
    ///
    /// Без «где» строка была тупиком: сообщала состояние, которого человек не
    /// выбирал, и не говорила, что с ним делать. Два неуправляемых случая
    /// обязаны различаться: машине, поднятой не ключом, переключать нечего —
    /// панель о ней не знает вовсе, и ей нужен ключ, а не переключатель.
    private var explanation: String {
        let panel = model.settings.panel
        if panel.isManaged {
            return NSLocalizedString(
                "Профили, макросы и политику защиты задаёт панель. Локально правятся номер, метка профиля и SIP-пароль.",
                comment: "пояснение к режиму управления")
        }
        if panel.isActivated {
            return NSLocalizedString(
                "Панель отключена вручную: файл предустановок не применяется ни в чём. Вернуть машину под панель — в разделе «Аккаунт», переключателем «Слушать панель».",
                comment: "пояснение к режиму управления")
        }
        return NSLocalizedString(
            "Машину поднимали не ключом, и панель о ней не знает. Профили, макросы и политику защиты задаёт администратор этой машины. Чтобы передать их панели, нужен ключ из неё — поле «Новый ключ» у менеджера, в «Техподдержке».",
            comment: "пояснение к режиму управления")
    }

    /// Пароль уходит в черновик, а не в настройки: применит его кнопка
    /// «Сохранить» внизу окна вместе со всем остальным.
    private func applyPassword() {
        model.stageAdminPassword(newPassword)
        newPassword = ""
        repeatedPassword = ""
        problem = nil
        confirmation = NSLocalizedString("Принято. Пароль начнёт действовать после сохранения настроек.", comment: "пароль администратора принят в черновик")
    }

    private func removePassword() {
        model.stageAdminPasswordRemoval()
        newPassword = ""
        repeatedPassword = ""
        problem = nil
        confirmation = NSLocalizedString("Принято. После сохранения «Управление» откроется без пароля.", comment: "снятие пароля принято в черновик")
    }
}
