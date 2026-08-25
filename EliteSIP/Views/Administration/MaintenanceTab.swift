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

    var body: some View {
        // Секции «Перенос рабочего места» и «Загрузка конфигурации» здесь
        // больше нет, и это не сокращение экрана.
        //
        // Файл конфигурации был конторскими настройками в локальном артефакте,
        // применяемым мимо панели: сброшенная машина восстанавливалась из
        // слепка, унесённого месяц назад, и панель не узнавала об этом никогда.
        // Перенос рабочего места на новый компьютер теперь называется
        // «выпустить ключ» — одно нажатие в панели, и приезжает свежее, а не
        // годичной давности.
        SettingsSection("Для поддержки") {
            SettingsButtonsRow {
                Button("Выгрузить журнал…") { Task { await exportLog() } }
                Button("Выгрузить файл настроек…") { exportSettings() }
            }

            SettingsNote("""
                Журнал уходит тем же архивом, что и «Собрать логи» у менеджера: сведения о \
                сборке и системе внутри, секреты замаскированы.
                """)

            SettingsNote("""
                Файл настроек — сырой `settings.json` как он есть на диске, включая \
                несохранённое из этого окна. Он для разбора жалобы, а не для переноса: другая \
                машина его не примет, и всё машинное в нём остаётся как было.
                """)

            SettingsNote("""
                История звонков не выгружается ни тем, ни другим: в ней номера лидов и \
                SIP-логины без маскирования. Это решение этапа 4, и оно осталось в силе.
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

    private func exportLog() async {
        guard let url = save(name: SupportArchive.suggestedName()) else { return }
        do {
            try await model.exportLog(to: url)
            show(String(format: NSLocalizedString("Журнал выгружен в %@.", comment: "итог выгрузки журнала"), url.lastPathComponent))
        } catch {
            show(String(format: NSLocalizedString("Не удалось выгрузить журнал: %@", comment: "выгрузка журнала не удалась"), error.localizedDescription))
        }
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
