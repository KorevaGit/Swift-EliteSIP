import AdminAccess
import SwiftUI

/// Вкладка «Доступ»: пароль администратора и то, кто управляет настройками.
///
/// Видна только в открытом режиме — то есть либо тому, кто знает пароль, либо
/// на машине, где пароля ещё нет. Второе и есть обычный путь установки: свежее
/// рабочее место настраивают целиком, а пароль ставят последним действием.
struct AdministrationTab: View {

    @EnvironmentObject private var model: AppModel

    @State private var newPassword = ""
    @State private var repeatedPassword = ""
    @State private var problem: String?
    @State private var confirmation: String?

    var body: some View {
        Form {
            Section(header: Text("Кто управляет настройками")) {
                CompatLabeledContent("Режим", value: model.adminAccess.management.title)
                Text(model.adminAccess.management.explanation)
                    .font(.footnote)
                    .compatForeground(.secondary)
                MilestoneNote("""
                    Значение меняется само: любое сохранение в этом окне объявляет \
                    настройки локальными. Второе значение — «настройки из файла \
                    конфигурации» — заработает в M8, когда появится сама загрузка \
                    конфига. Вернуть машину под конфиг после локальной правки можно \
                    будет только повторной загрузкой файла.
                    """)
            }

            Section(header: Text("Пароль администратора")) {
                if model.isAdministrationProtectedIncludingDraft {
                    CompatLabel(title: "Пароль задан, закрытая часть закрыта", symbol: "lock.shield.fill")
                        .compatForeground(Theme.Palette.registered)
                } else {
                    CompatLabel(
                        title: "Пароль не задан — эти вкладки видит любой, кто откроет настройки",
                        symbol: "exclamationmark.triangle.fill"
                    )
                    .compatForeground(Theme.Palette.failure)
                }

                SecureField("Новый пароль", text: $newPassword)
                SecureField("Ещё раз", text: $repeatedPassword)

                HStack {
                    Button(model.isAdministrationProtectedIncludingDraft ? "Сменить пароль" : "Задать пароль") {
                        applyPassword()
                    }
                    .compatProminentButtonStyle()
                    .disabled(newPassword.isEmpty || newPassword != repeatedPassword)

                    Button("Снять пароль") { removePassword() }
                        .disabled(!model.isAdministrationProtectedIncludingDraft)
                        .compatHelp("Настройки станут доступны всем без вопросов")

                    Spacer()
                }

                if model.pendingAdminPassword != nil || model.pendingAdminPasswordRemoval {
                    CompatLabel(
                        title: "Применится при сохранении настроек",
                        symbol: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .compatForeground(.orange)
                }

                if !newPassword.isEmpty && newPassword != repeatedPassword {
                    Text("Пароли не совпадают.")
                        .font(.footnote)
                        .compatForeground(Theme.Palette.failure)
                }

                if let problem {
                    Text(problem)
                        .font(.footnote)
                        .compatForeground(Theme.Palette.failure)
                }

                if let confirmation {
                    Text(confirmation)
                        .font(.footnote)
                        .compatForeground(.secondary)
                }
            }

            Section(header: Text("Забытый пароль")) {
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

            Section(header: Text("Что закрыто")) {
                Text("""
                    Аккаунты и профили целиком, макросы DTMF, политика защиты от \
                    автокликеров, TLS без проверки сертификата и диагностика.

                    Менеджеру остаются устройства и громкость, рингтон, выбор профиля и \
                    переключение офис ↔ удалённо, «Исправить сеть», самопроверка голоса \
                    и сбор логов для поддержки.
                    """)
                .font(.footnote)
                .compatForeground(.secondary)
            }
        }
        .compatGroupedForm()
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
