import AppKit
import PanelLink
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
        // «Система» Windows 1.0.4: «Приложение» — версия, обновления, архив;
        // «Spark» — схема связи, машина и предустановка. Строки со значками и
        // действиями справа, а не абзацы.
        SettingsSection("Приложение", icon: "package") {
            HStack(spacing: Theme.Metrics.sectionSpacing) {
                LucideIcon(name: "crown-split", size: 20)
                Text(verbatim: "EliteSIP").font(.callout.weight(.semibold))
                Spacer()
                Text(verbatim: appVersion)
                    .compatMonospacedDigit()
                    .compatForeground(Theme.Palette.textSecondary)
            }

            SettingsDivider()

            UpdateCheckRow(isChecking: model.isCheckingForUpdates, result: model.updateCheckResult)

            SettingsDivider()

            HStack(spacing: Theme.Metrics.sectionSpacing) {
                LucideIcon(name: "archive", size: Theme.Icon.large + 2)
                    .compatForeground(Theme.Palette.textSecondary)
                Text("Архив для поддержки")
                Spacer()
                Button(action: { Task { await makeArchive() } }) {
                    HStack(spacing: Theme.Metrics.tightSpacing) {
                        LucideIcon(name: "files", size: Theme.Icon.medium)
                        Text("Собрать")
                    }
                }
                .disabled(!model.settings.logFile.isEnabled)
                .compatHelp("Журнал и сведения о системе одним файлом — по нему поддержка разбирает звонок.")
            }

            if !model.settings.logFile.isEnabled {
                SettingsNote("Журнал в файл выключен — включается в «Управлении».")
            }

            if let archiveResult {
                SettingsNote(verbatim: archiveResult)
            }
        }

        if model.settings.panel.hasChannelKey || model.settings.panel.isManaged || model.isPanelOffline {
            SettingsSection("Spark", icon: "cloud") {
                HStack(spacing: Theme.Metrics.sectionSpacing) {
                    sparkNode("monitor", title: "Этот компьютер")
                    LucideIcon(name: "arrow-left-right", size: Theme.Icon.medium)
                        .compatForeground(model.isPanelOffline ? Theme.Palette.failure : Theme.Palette.registered)
                    sparkNode("cloud", title: "Spark")
                }
                .frame(maxWidth: .infinity)

                if model.settings.panel.hasChannelKey {
                    HStack(spacing: Theme.Metrics.sectionSpacing) {
                        LucideIcon(name: "fingerprint", size: Theme.Icon.large)
                            .compatForeground(Theme.Palette.textSecondary)
                        Text(verbatim: machineSummary)
                            .font(.system(.callout, design: .monospaced))
                            .compatForeground(Theme.Palette.textSecondary)
                            .lineLimit(1)
                        Spacer()
                        Button(action: copyMachineID) {
                            HStack(spacing: Theme.Metrics.tightSpacing) {
                                LucideIcon(name: "copy", size: Theme.Icon.medium)
                                Text("Копировать ID")
                            }
                        }
                    }
                }

                HStack(spacing: Theme.Metrics.sectionSpacing) {
                    LucideIcon(name: "list-checks", size: Theme.Icon.large)
                        .compatForeground(Theme.Palette.textSecondary)
                    Text(verbatim: presetLine)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .compatHelp(verbatim: presetLine)
                    Spacer()
                }

                if model.settings.panel.isManaged || model.isPanelOffline {
                    PanelSyncRow()
                }
            }
        }
    }

    private var presetLine: String {
        let panel = model.settings.panel
        if !panel.presetName.isEmpty { return panel.presetName }
        if !panel.presetID.isEmpty { return panel.presetID }
        return NSLocalizedString("Не применены", comment: "предустановки на машине нет")
    }

    private func sparkNode(_ icon: String, title: LocalizedStringKey) -> some View {
        VStack(spacing: Theme.Metrics.tightSpacing) {
            LucideIcon(name: icon, size: 22)
            Text(title).font(.caption).lineLimit(1)
        }
        .compatForeground(Theme.Palette.textSecondary)
        .frame(minWidth: 96)
    }

    private func copyMachineID() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.settings.panel.installationID, forType: .string)
    }

    private var machineSummary: String {
        let panel = model.settings.panel
        let id = String(panel.installationID.prefix(8))
        guard panel.hasMachineKey else {
            return String(format: NSLocalizedString("%@ · переходит на настройки из Spark",
                                                    comment: "строка машины в «Техподдержке»"), id)
        }
        return String(format: NSLocalizedString("%@ · настройки: ревизия %lld",
                                                comment: "строка машины в «Техподдержке»"),
                      id, Int64(panel.appliedConfigRevision))
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
