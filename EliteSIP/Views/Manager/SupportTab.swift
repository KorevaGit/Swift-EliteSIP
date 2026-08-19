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
