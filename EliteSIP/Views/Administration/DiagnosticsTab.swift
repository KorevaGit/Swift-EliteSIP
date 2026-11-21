import AppKit
import SIPCore
import SwiftUI

/// Раздел «Диагностика»: чем разбирают жалобу.
///
/// В этапе 5 раздел разгрузился в обе стороны. Живая трасса SIP занимала больше
/// половины экрана и уехала в своё окно — её можно растянуть и держать открытой
/// во время звонка, чего здесь было нельзя. Всё, что делается с файлами машины,
/// уехало в «Обслуживание»: рядом с «Собрать архив» не должно стоять «Стереть
/// машину».
///
/// Взамен сюда переехали индикаторы уровня из упразднённого раздела «Звук» —
/// это прибор, а не настройка, и место ему рядом с журналом.
struct DiagnosticsTab: View {

    @EnvironmentObject private var model: AppModel

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    private var isGlassAvailable: Bool { Theme.Chrome.isGlassAvailable }

    private var glassAvailability: String {
        isGlassAvailable
            ? NSLocalizedString("Liquid Glass доступен", comment: "есть ли стекло в системе")
            : NSLocalizedString("Liquid Glass недоступен, используются материалы", comment: "есть ли стекло в системе")
    }

    var body: some View {

        SettingsSection("Журнал", icon: "file-text") {
            SettingsRow("Показывать от") {
                Picker("", selection: Binding(
                    get: { model.settings.minimumLogLevel },
                    set: { model.settings.minimumLogLevel = $0 }
                )) {
                    ForEach(SIPLogLevel.allCases, id: \.self) { level in
                        Text(level.rawValue).tag(level)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                // Выравнивание по левому краю, а не умолчательное по центру:
                // сегменты уже своей рамки, и в рамке шириной 280 они вставали
                // посередине — то есть правее колонки контролов, на которой
                // стоят кнопки и пояснения под ними. Расслоение видно только
                // рядом с соседней строкой, поэтому и прожило долго.
                .frame(maxWidth: 280, alignment: .leading)
            }

            SettingsButtonsRow {
                Button("Показать трассу…") { openTrace() }
                Button("Скопировать") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.logText, forType: .string)
                }
                .disabled(model.log.isEmpty)
            }

            SettingsHint("Трасса открывается отдельным окном — её держат открытой во время звонка.")
        }

        LogFileSection()
        AudioProbeSection()
    }

    private func value(_ text: String) -> some View {
        Text(text)
            .compatForeground(Theme.Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func openTrace() {
        NSApp.sendAction(#selector(AppDelegate.showSIPTraceWindow(_:)), to: nil, from: nil)
    }
}

// MARK: - Файловый журнал

/// Файловый журнал: включение, подробность и срок хранения.
///
/// Отдельная секция, а не пара переключателей рядом с экранным уровнем: у файла
/// другой смысл. Экранный уровень — это «что мне сейчас видно», файловый — «что
/// останется, когда позвонят в поддержку», и путать их нельзя. Оператор,
/// поставивший себе «только ошибки», не должен этим лишить себя разбора.
///
/// Кнопок выгрузки здесь больше нет: они в «Обслуживании», вместе с остальными
/// действиями над файлами. Осталась «Собрать архив» — та же, что у менеджера,
/// потому что ею пользуются по телефону с поддержкой, а не при настройке.
private struct LogFileSection: View {

    @EnvironmentObject private var model: AppModel

    /// Что показать после сборки архива: путь или причину отказа.
    @State private var archiveResult: String?

    var body: some View {
        SettingsSection("Журнал в файле", icon: "file-text") {
            SettingsToggleRow("Вести журнал в файле", isOn: Binding(
                get: { model.settings.logFile.isEnabled },
                set: { model.settings.logFile.isEnabled = $0 }
            ))

            if model.settings.logFile.isEnabled {
                SettingsRow("Писать от") {
                    Picker("", selection: Binding(
                        get: { model.settings.logFile.minimumLevel },
                        set: { model.settings.logFile.minimumLevel = $0 }
                    )) {
                        ForEach(SIPLogLevel.allCases, id: \.self) { level in
                            Text(level.rawValue).tag(level)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    // По левому краю — см. пояснение у экранного уровня выше.
                    .frame(maxWidth: 280, alignment: .leading)
                }

                SettingsRow("Хранить") {
                    Stepper(
                        "\(model.settings.logFile.maximumAgeInDays) дн.",
                        value: Binding(
                            get: { model.settings.logFile.maximumAgeInDays },
                            set: { model.settings.logFile.maximumAgeInDays = $0 }
                        ),
                        in: 1...365
                    )
                }

                SettingsHint("Digest и ключи SRTP маскируются; номера и логины остаются.")

                SettingsButtonsRow {
                    Button("Собрать архив для поддержки") { Task { await makeArchive() } }
                }

                if let archiveResult {
                    SettingsNote(verbatim: archiveResult)
                }
            }
        }
    }

    /// Архив собирается и сразу показывается в Finder: инструкция оператору
    /// должна состоять из одного шага, а дальше он его просто перетащит.
    private func makeArchive() async {
        do {
            let url = try await model.makeSupportArchive()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            archiveResult = String(
                format: NSLocalizedString("Готово: %@", comment: "архив для поддержки собран"),
                url.lastPathComponent
            )
        } catch {
            archiveResult = String(
                format: NSLocalizedString("Не удалось собрать архив: %@", comment: "архив для поддержки не собрался"),
                error.localizedDescription
            )
        }
    }
}

// MARK: - Прибор

/// Что происходит в звуковом тракте прямо сейчас.
///
/// Переехало из упразднённого раздела «Звук» вместе с индикаторами уровня.
/// Показывается только в разговоре: вне его тракта нет, и пустые строки
/// «маршрут — нет» отвечали бы на незаданный вопрос.
private struct AudioProbeSection: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let route = model.audioRoute {
        }
    }
}
