import AppKit
import SwiftUI

/// Логи для техподдержки и «Исправить сеть».
///
/// Сюда переехала кнопка из бывшего «Рабочего места»: от той секции осталась
/// одна кнопка — список профилей уехал в капсулу панели, пометка и площадка
/// администратору. Одна кнопка раздела не образует, а по смыслу она здесь и
/// была: сеть чинят и логи собирают по одному поводу — «не работает, звоню в
/// поддержку».
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
                Button("Собрать логи") { makeArchive() }
                    .disabled(!model.settings.logFile.isEnabled)
                Button("Исправить сеть") {
                    Task { await model.repairNetwork() }
                }
            }

            if !model.settings.logFile.isEnabled {
                SettingsNote("Журнал в файл выключен — собирать нечего. Включается в «Управлении».")
            }

            if let archiveResult {
                SettingsNote(archiveResult)
            }

            if let status = model.networkRepairStatus {
                SettingsNote(status)
            }

            // Строки «Площадка» здесь нет. Она была задумана как «есть что
            // назвать в поддержке», но поддержка эти же сведения получает
            // архивом по соседней кнопке — и получает полнее. Строка на
            // чтение, которую оператор не понимает и не может изменить,
            // занимала место и объясняла себя только сама себе.
        }
    }

    private func makeArchive() {
        do {
            let url = try model.makeSupportArchive()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            archiveResult = "Готово: \(url.lastPathComponent)"
        } catch {
            archiveResult = "Не удалось собрать архив: \(error.localizedDescription)"
        }
    }
}
