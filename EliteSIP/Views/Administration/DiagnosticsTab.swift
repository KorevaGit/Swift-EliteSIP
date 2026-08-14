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

    private var isGlassAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    private var glassAvailability: String {
        isGlassAvailable
            ? "Liquid Glass доступен"
            : "Liquid Glass недоступен, используются материалы"
    }

    var body: some View {
        SettingsSection("Сборка") {
            SettingsRow("Версия") { value(appVersion) }
            SettingsRow("macOS") { value(ProcessInfo.processInfo.operatingSystemVersionString) }
            SettingsRow("Оформление") { value(glassAvailability) }

            // Сам выключатель «Без стекла» стоит у менеджера, в «Оформлении»
            // рядом с темой. Строка выше от этого не лишняя: она отвечает на
            // «почему выключатель серый» — стекла может не быть в самой
            // системе, — и это сведения о сборке, которым здесь и место.
            //
            // Дубля здесь не будет: одна настройка в двух окнах — это два
            // текста про один выключатель, и разойдутся они на первой же
            // правке. Разбор, почему выбран менеджер, а не администратор, — в
            // `AppearanceTab`.
            SettingsNote("Выключается в «Настройках», раздел «Оформление»: там же, где тема.")
        }

        SettingsSection("Журнал") {
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
                .frame(maxWidth: 280)
            }

            SettingsButtonsRow {
                Button("Показать трассу…") { openTrace() }
                Button("Скопировать") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.logText, forType: .string)
                }
                .disabled(model.log.isEmpty)
            }

            SettingsNote("""
                Трасса открывается своим окном: её держат открытой во время звонка, а раздел \
                настроек для этого не годится — он закрывается вместе с «Управлением».
                """)
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
        SettingsSection("Журнал в файле") {
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
                    .frame(maxWidth: 280)
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

                SettingsNote("""
                    Секреты в файл не попадают: ответ Digest и ключи SRTP маскируются на записи. \
                    Номера и SIP-логины остаются — по ним и разбирают звонок.
                    """)

                SettingsButtonsRow {
                    Button("Собрать архив для поддержки") { makeArchive() }
                }

                if let archiveResult {
                    SettingsNote(archiveResult)
                }
            }
        }
    }

    /// Архив собирается и сразу показывается в Finder: инструкция оператору
    /// должна состоять из одного шага, а дальше он его просто перетащит.
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
            SettingsSection("Текущий разговор") {
                SettingsRow("Маршрут") {
                    Text(route.summary)
                        .compatForeground(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let codec = model.negotiatedCodec {
                    SettingsRow("Кодек") {
                        Text(codec.sdpName + (codec.isWideband ? " — широкая полоса" : ""))
                            .compatForeground(Theme.Palette.textSecondary)
                    }
                }

                // Эхоподавление отпадает молча: при разных устройствах на вход
                // и выход VoiceProcessingIO не запускается вовсе, а при отказе
                // движка тракт поднимается откатом. Через колонки в таком
                // разговоре собеседник услышит себя.
                if let active = model.echoCancellationActive {
                    SettingsRow("Эхоподавление") {
                        Text(active ? "работает" : "выключено")
                            .compatForeground(
                                active ? Theme.Palette.textSecondary : Theme.Palette.failure
                            )
                    }
                }

                LevelMeters(levels: model.audioLevels)

                if let remote = model.remoteAudioView {
                    SettingsRow("У собеседника") {
                        Text(remote.summary)
                            .compatForeground(Theme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// Пара индикаторов.
///
/// Отдельная вьюха с собственной подпиской, а не два вызова прямо в разделе:
/// уровни обновляются двадцать раз в секунду, и подписываться на них должно
/// только то, что их показывает. Читай `AppModel.audioLevels` весь раздел
/// напрямую — перерисовывался бы вместе со списками и полями.
private struct LevelMeters: View {

    @ObservedObject var levels: AudioLevels

    var body: some View {
        Group {
            LevelMeter(title: "Микрофон", level: levels.input)
            LevelMeter(title: "Приём", level: levels.output)
        }
    }
}

/// Полоска уровня.
///
/// Нужна затем, чтобы оператор видел, что микрофон живой, до того как начнёт
/// говорить, — а не узнавал об этом от собеседника.
private struct LevelMeter: View {

    let title: String
    let level: Float

    var body: some View {
        SettingsRow(title) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.Palette.textTertiary.opacity(0.5))
                    Capsule()
                        .fill(color)
                        // Корень вместо самого уровня: слух логарифмический, и
                        // на линейной шкале обычная речь болтается у левого края.
                        .frame(width: geometry.size.width * CGFloat(sqrt(max(level, 0))))
                }
            }
            .frame(width: 160, height: 6)
        }
    }

    private var color: Color {
        // Красный только у самой шкалы: там начинается ограничение, и голос
        // хрипит независимо от кодека и сети.
        level > 0.95 ? Theme.Palette.failure : .accentColor
    }
}
