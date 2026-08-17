import AppKit
import Diagnostics
import SwiftUI

/// Раздел «Обслуживание»: всё, что делается с файлами машины.
///
/// Отдельным разделом, а не секцией «Диагностики». Иначе в одном экране
/// оказались бы «Скопировать журнал» и «Стереть машину», и человек искал бы
/// первое, глядя на второе.
///
/// **Путей к файлам здесь нет намеренно.** Намёк «полезай в `~/Library`» на
/// чужом рабочем месте хуже кнопки: администратор должен получить файл туда,
/// куда ему нужно, — на рабочий стол или на флешку, — а не научиться ходить в
/// системные каталоги.
struct MaintenanceTab: View {

    @EnvironmentObject private var model: AppModel

    @State private var notice: String?
    @State private var isConfirmingHistoryClear = false
    @State private var isConfirmingReset = false
    @State private var pendingImport: PendingImport?

    /// Выбранный файл как повод показать вопрос: `alert(item:)` требует
    /// `Identifiable`, а вешать это на сам `URL` нельзя — соответствие вышло бы
    /// глобальным на весь модуль ради одного экрана.
    private struct PendingImport: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    var body: some View {
        SettingsSection("Выгрузка") {
            SettingsButtonsRow {
                Button("Выгрузить настройки…") { exportSettings() }
                Button("Выгрузить конфигурацию…") { exportConfiguration() }
                Button("Выгрузить журнал…") { exportLog() }
            }

            SettingsNote("""
                Настройки выгружаются такими, какими они видны в окне, — включая несохранённое. \
                Журнал уходит тем же архивом, что и «Собрать логи» у менеджера: сведения о \
                сборке и системе внутри, секреты замаскированы.
                """)

            SettingsNote("""
                Конфигурация — это то же самое в формате EliteSIP: файл, который принимает мастер \
                первоначальной настройки на новой машине. Им переносят рабочее место человека на \
                другой компьютер целиком, вместе с добавочным и паролем; при чтении из него \
                отбрасываются звуковые устройства, свой рингтон, тема со стеклом и \
                административный пароль — всё, что принадлежит той машине, а не месту.
                """)

            SettingsNote("""
                История звонков не выгружается: в ней номера лидов и SIP-логины без \
                маскирования. Это решение этапа 4, и оно осталось в силе.
                """)
        }

        SettingsSection("Загрузка настроек") {
            SettingsButtonsRow {
                Button("Загрузить настройки из файла…") { chooseImport() }
            }

            SettingsNote("""
                Файл заполняет окно целиком — профили, пароль SIP, пароль администратора, \
                макросы, очереди, стук. На диск не уходит ничего до «Сохранить», и «Отменить» \
                возвращает как было.
                """)
        }

        SettingsSection("Чистка") {
            SettingsButtonsRow {
                Button("Очистить журнал") { model.clearLogFile() }
                Button("Очистить историю") { isConfirmingHistoryClear = true }
                    .disabled(model.historyStore == nil)
            }

            SettingsNote("""
                Очистка истории стирает записи всех профилей целиком — выборочного удаления нет \
                намеренно — и пишет в журнал, сколько их было. Стереть можно, бесследно нельзя.
                """)
        }

        SettingsSection("Сброс") {
            SettingsButtonsRow {
                Button("Сбросить машину…") { isConfirmingReset = true }
                    .disabled(!model.canResetMachine)

                if !model.canResetMachine {
                    Text("недоступно в разговоре")
                        .font(.footnote)
                        .compatForeground(Theme.Palette.textSecondary)
                }
            }

            SettingsNote(
                """
                Стирает настройки, историю и журнал — машина станет такой же, как сразу после \
                установки, и пароля администратора на ней не будет. Готовится к передаче \
                рабочего места другому сотруднику.
                """,
                isAlarming: true
            )
        }

        if let notice {
            SettingsNote(verbatim: notice)
        }

        // Пусто, а не «сделано»: подтверждения живут на видимых вью, и вешать
        // три `alert` на одну строку нельзя — SwiftUI показывает только
        // последний. Поэтому каждый висит на своём носителе.
        Color.clear
            .frame(height: 0)
            .alert(isPresented: $isConfirmingHistoryClear) {
                Alert(
                    title: Text("Очистить историю звонков?"),
                    message: Text("""
                        Будут удалены записи всех профилей этой машины. Вернуть их \
                        «Отменой» нельзя. В журнал уйдёт строка с числом записей.
                        """),
                    primaryButton: .destructive(Text("Очистить")) {
                        let removed = model.clearHistory()
                        show(String.localizedStringWithFormat(
                            NSLocalizedString("История очищена: записей — %lld.", comment: "итог очистки истории"),
                            removed
                        ))
                    },
                    secondaryButton: .cancel(Text("Отмена"))
                )
            }

        Color.clear
            .frame(height: 0)
            .alert(item: $pendingImport) { pending in
                Alert(
                    title: Text("Загрузить настройки из файла?"),
                    message: Text(importWarning(pending.url)),
                    primaryButton: .default(Text("Загрузить")) { performImport(pending.url) },
                    secondaryButton: .cancel(Text("Отмена"))
                )
            }

        ResetConfirmation(isPresented: $isConfirmingReset) {
            model.resetMachine()
            show(NSLocalizedString("Машина сброшена.", comment: "итог сброса машины"))
        }
    }

    // MARK: - Действия

    private func exportSettings() {
        guard let url = save(name: "elitesip-settings.json") else { return }
        do {
            try model.exportSettings(to: url)
            show(String(format: NSLocalizedString("Настройки выгружены в %@.", comment: "итог выгрузки настроек"), url.lastPathComponent))
        } catch {
            show(String(format: NSLocalizedString("Не удалось выгрузить настройки: %@", comment: "выгрузка настроек не удалась"), error.localizedDescription))
        }
    }

    /// Выгрузка конфигурации в формате EliteSIP.
    ///
    /// Появилась 17 августа 2026 вместе с веткой переноса в мастере. До неё эта
    /// ветка была мертва: мастер `.elitesip` читать умел, а писать такой файл не
    /// умел никто — то есть «перенести рабочее место» существовало только на
    /// бумаге. Рядом с «Выгрузить настройки…», а не вместо: тот даёт сырой
    /// `settings.json` для разбора жалоб, этот — документ для другой машины.
    private func exportConfiguration() {
        let label = model.settings.profiles.active.account.username
        guard let url = save(name: EliteSIPDocument.suggestedName(.config, label: label)) else {
            return
        }
        do {
            try EliteSIPDocument.encode(config: model.settings).write(to: url, options: .atomic)
            show(
                String(
                    format: NSLocalizedString(
                        "Конфигурация выгружена в %@.", comment: "итог выгрузки конфигурации"
                    ),
                    url.lastPathComponent
                )
            )
        } catch {
            show(
                String(
                    format: NSLocalizedString(
                        "Не удалось выгрузить конфигурацию: %@",
                        comment: "выгрузка конфигурации не удалась"
                    ),
                    error.localizedDescription
                )
            )
        }
    }

    private func exportLog() {
        guard let url = save(name: SupportArchive.suggestedName()) else { return }
        do {
            try model.exportLog(to: url)
            show(String(format: NSLocalizedString("Журнал выгружен в %@.", comment: "итог выгрузки журнала"), url.lastPathComponent))
        } catch {
            show(String(format: NSLocalizedString("Не удалось выгрузить журнал: %@", comment: "выгрузка журнала не удалась"), error.localizedDescription))
        }
    }

    private func chooseImport() {
        // `NSOpenPanel`, а не `fileImporter`: тот появился в macOS 11, а срез
        // x86_64 живёт с Catalina. Тем же способом выбирается файл рингтона.
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = ["json"]
        panel.prompt = NSLocalizedString("Загрузить", comment: "кнопка в окне выбора файла")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingImport = PendingImport(url: url)
    }

    private func importWarning(_ url: URL) -> String {
        var lines = [
            NSLocalizedString("""
                Все закрытые настройки в окне будут заменены содержимым файла, включая пароль \
                добавочного и пароль администратора. На диск это уйдёт только по «Сохранить».
                """, comment: "предупреждение перед загрузкой настроек из файла")
        ]
        if model.importWouldRemoveAdminPassword(url) {
            lines.append(NSLocalizedString("""
                В файле нет пароля администратора: после сохранения закрытые настройки \
                этой машины будут открыты всем.
                """, comment: "предупреждение перед загрузкой настроек из файла"))
        }
        return lines.joined(separator: "\n\n")
    }

    private func performImport(_ url: URL) {
        do {
            try model.importSettings(from: url)
            show(NSLocalizedString("Настройки загружены. Проверьте разделы и нажмите «Сохранить».", comment: "итог загрузки настроек"))
        } catch let failure as AppModel.SettingsImportFailure {
            show(failure.title)
        } catch {
            show(String(format: NSLocalizedString("Не удалось прочитать файл: %@", comment: "файл настроек не прочитался"), error.localizedDescription))
        }
        pendingImport = nil
    }

    private func save(name: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.prompt = NSLocalizedString("Выгрузить", comment: "кнопка в окне сохранения файла")
        // Рабочий стол по умолчанию: это то место, откуда файл переносят на
        // флешку или прикладывают к письму. Каталог журнала предлагать нельзя —
        // туда администратор как раз и не должен ходить.
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func show(_ text: String) {
        notice = text
    }
}
