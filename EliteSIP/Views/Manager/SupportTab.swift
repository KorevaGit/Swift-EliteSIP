import AppKit
import SwiftUI

/// Логи для техподдержки.
///
/// **«Исправить сеть» отсюда ушла 19 августа 2026** — в новый раздел «Работа».
/// Стояла она здесь потому, что от бывшего «Рабочего места» осталась одна
/// кнопка, а одна кнопка раздела не образует. Раздел появился: кнопка открывает
/// дорогу до АТС снаружи, то есть чинит ровно ту работу из дома, которую
/// «Работа» и переключает, — и стоять ей надо там, где человек уже думает про
/// «я сегодня не в офисе», а не в соседстве со сбором логов.
struct SupportTab: View {

    @EnvironmentObject private var model: AppModel

    @State private var archiveResult: String?

    /// Версия и сборка одной строкой — тем же составом, что у администратора в
    /// «Диагностике». Две разные записи об одном и том же в двух окнах
    /// разошлись бы при первой правке, и поддержка узнавала бы номер сборки в
    /// зависимости от того, кто снял трубку.
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    var body: some View {
        SettingsSection("Техподдержка") {
            SettingsNote("""
                Архив с журналом и сведениями о системе: по нему в поддержке \
                разбирают, что случилось со звонком.
                """)

            SettingsButtonsRow {
                Button("Собрать логи") { Task { await makeArchive() } }
                    .disabled(!model.settings.logFile.isEnabled)
            }

            if !model.settings.logFile.isEnabled {
                SettingsNote("Журнал в файл выключен — собирать нечего. Включается в «Управлении».")
            }

            if let archiveResult {
                SettingsNote(verbatim: archiveResult)
            }

            // Кнопка проверки обновлений (M7h). Не рядом со сбором логов
            // случайно: это тот же раздел «раз что-то не так — я это делаю
            // сам, не дожидаясь администратора», и «у меня старая версия» сюда
            // укладывается ровно так же, как «соберите мне архив».
            // Версия — прямо над кнопкой проверки, а не в отдельном разделе.
            //
            // Первое, что просит поддержка по телефону, — «какая у вас версия»,
            // и до этой правки менеджеру было нечего ответить: строка стояла
            // только в «Диагностике», за административным паролем. Соседство с
            // «Проверить обновления сейчас» тоже не случайное: человек видит
            // номер и тут же может выяснить, не устарел ли он.
            SettingsRow("Версия") {
                Text(verbatim: appVersion)
                    .compatForeground(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            UpdateCheckRow(isChecking: model.isCheckingForUpdates, result: model.updateCheckResult)

            // Строки «Площадка» здесь нет. Она была задумана как «есть что
            // назвать в поддержке», но поддержка эти же сведения получает
            // архивом по соседней кнопке — и получает полнее. Строка на
            // чтение, которую оператор не понимает и не может изменить,
            // занимала место и объясняла себя только сама себе.
        }
    }

    private func makeArchive() async {
        do {
            let url = try await model.makeSupportArchive()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            archiveResult = String(format: NSLocalizedString("Готово: %@", comment: "архив для поддержки собран"), url.lastPathComponent)
        } catch {
            archiveResult = String(
                format: NSLocalizedString("Не удалось собрать архив: %@", comment: "архив для поддержки не собрался"),
                error.localizedDescription
            )
        }
    }
}
