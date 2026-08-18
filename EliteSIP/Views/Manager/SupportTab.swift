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
                Button("Собрать логи") { Task { await makeArchive() } }
                    .disabled(!model.settings.logFile.isEnabled)
                Button("Исправить сеть") {
                    Task { await model.repairNetwork() }
                }
            }

            if !model.settings.logFile.isEnabled {
                SettingsNote("Журнал в файл выключен — собирать нечего. Включается в «Управлении».")
            }

            if let archiveResult {
                SettingsNote(verbatim: archiveResult)
            }

            if let status = model.networkRepairStatus {
                SettingsNote(verbatim: status)
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
