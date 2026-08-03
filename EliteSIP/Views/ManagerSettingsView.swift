import AdminAccess
import AppKit
import MediaCore
import SIPCore
import SwiftUI

/// Настройки, доступные без пароля.
///
/// **Граница проведена по вкладкам, а не по секциям** (решение M7c): всё, что
/// менеджер меняет сам, собрано здесь, а закрытое лежит за кнопкой
/// «Управление». Секционная граница была бы дешевле в правке, но размазанной:
/// каждая следующая настройка требовала бы отдельного решения, куда её
/// отнести, — и однажды это решение просто забыли бы принять.
///
/// Что здесь есть и почему именно это:
///
/// - **Устройства и эхоподавление** — меняются при смене наушников, то есть
///   чаще всего остального.
/// - **Профиль и офис/удалённо** — менеджер уезжает домой сам, и звонить в
///   поддержку ради переключения адреса АТС ему незачем.
/// - **«Исправить сеть»** — стук по портам по требованию, когда доступ
///   потерялся не по нашей логике.
/// - **Рингтон вместе с заменой файла** — звук на своём рабочем месте человек
///   выбирает сам.
/// - **Самопроверка голоса** — ответ на «меня слышно?» без звонка коллеге.
/// - **Логи для техподдержки** — ради этого и делался M7a. Номера лидов
///   менеджер и так видит в панели звонков, новой утечки здесь не появляется.
struct ManagerSettingsView: View {

    @EnvironmentObject private var model: AppModel

    /// Показывать ли окно ввода административного пароля.
    @State private var isAskingForPassword = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                WorkplaceSection()
                AudioSection()
                SelfTestSection()
                RingtoneSection()
                SupportSection()
            }
            .compatGroupedForm()

            Divider()
            AdministrationFooter(isAskingForPassword: $isAskingForPassword)
        }
        .sheet(isPresented: $isAskingForPassword) {
            AdminUnlockView(isPresented: $isAskingForPassword)
                .environmentObject(model)
        }
    }
}

// MARK: - Рабочее место

private struct WorkplaceSection: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section(header: Text("Рабочее место")) {
            // Выбор из готовых профилей, но не правка: завести, переименовать
            // или удалить профиль — административное действие. Менеджеру нужно
            // ровно одно — переключиться на тот, что ему выдали.
            Picker("Профиль", selection: Binding(
                get: { model.activeProfileID },
                set: { id in Task { await model.selectProfile(id) } }
            )) {
                ForEach(model.profiles) { profile in
                    Text(profile.title.isEmpty ? profile.account.username : profile.title)
                        .tag(profile.id)
                }
            }
            .disabled(!model.canSwitchProfile)

            if !model.canSwitchProfile {
                Text("Во время разговора профиль не переключается.")
                    .font(.footnote)
                    .compatForeground(.secondary)
            }

            WorkplacePicker()

            HStack {
                Button("Исправить сеть") {
                    Task { await model.repairNetwork() }
                }
                .compatHelp("Один стук по портам шлюза, если доступ к АТС потерялся")
                Spacer()
            }

            if let status = model.networkRepairStatus {
                Text(status)
                    .font(.footnote)
                    .compatForeground(.secondary)
            }
        }
    }
}

// MARK: - Звук

private struct AudioSection: View {

    @EnvironmentObject private var model: AppModel
    @State private var inputs: [AudioDevice] = []
    @State private var outputs: [AudioDevice] = []
    @State private var observation: AudioDeviceCatalog.Observation?

    var body: some View {
        Section(header: Text("Звук разговора")) {
            Picker("Микрофон", selection: Binding(
                get: { model.settings.audio.inputDeviceUID },
                set: { model.settings.audio.inputDeviceUID = $0 }
            )) {
                Text("Системный по умолчанию").tag(String?.none)
                ForEach(inputs) { device in
                    Text(device.name).tag(String?.some(device.uid))
                }
            }

            Picker("Наушники", selection: Binding(
                get: { model.settings.audio.outputDeviceUID },
                set: { model.settings.audio.outputDeviceUID = $0 }
            )) {
                Text("Системные по умолчанию").tag(String?.none)
                ForEach(outputs) { device in
                    Text(device.name).tag(String?.some(device.uid))
                }
            }

            if needsAggregate {
                CompatLabel(
                    title: "Разные устройства — эхоподавления не будет",
                    symbol: "exclamationmark.triangle.fill"
                )
                .compatForeground(Theme.Palette.failure)

                Text("""
                    Через колонки в таком режиме разговаривать нельзя — собеседник \
                    услышит себя. Назначьте эту пару системной по умолчанию в «Звуке», \
                    а здесь оставьте «системное».
                    """)
                .font(.footnote)
                .compatForeground(.secondary)
            }

            // Эхоподавление как таковое не выключается: это системный
            // VoiceProcessingIO, и он либо есть, либо macOS его не даёт (разные
            // устройства). Выключателем остаётся автоусиление — единственное,
            // что в этом блоке действительно спорно на хорошей гарнитуре.
            Toggle("Автоматическая регулировка усиления", isOn: Binding(
                get: { model.settings.audio.automaticGainControl },
                set: { model.settings.audio.automaticGainControl = $0 }
            ))
            .compatHelp("На встроенном микрофоне полезна, на хорошей гарнитуре «дышит»")

            Toggle("Отпускать наушники между звонками", isOn: Binding(
                get: { model.settings.audio.releasesDeviceWhenIdle },
                set: { model.settings.audio.releasesDeviceWhenIdle = $0 }
            ))
            .compatHelp("Иначе AirPods держат режим гарнитуры и глушат звук всей системы")
        }
        .onAppear {
            reloadDevices()
            observation = AudioDeviceCatalog.observe { _ in
                Task { @MainActor in reloadDevices() }
            }
        }
        .onDisappear { observation = nil }
    }

    private var needsAggregate: Bool {
        AudioDeviceCatalog.needsAggregate(
            inputUID: model.settings.audio.inputDeviceUID,
            outputUID: model.settings.audio.outputDeviceUID
        )
    }

    private func reloadDevices() {
        inputs = model.inputDevices
        outputs = model.outputDevices
    }
}

// MARK: - Самопроверка голоса

private struct SelfTestSection: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section(header: Text("Самопроверка голоса")) {
            Text("""
                Пять секунд записи и сразу воспроизведение — через тот же тракт, \
                что и разговор. Запись остаётся в памяти и стирается сразу после \
                прослушивания.
                """)
            .font(.footnote)
            .compatForeground(.secondary)

            HStack {
                if model.isSelfTestRunning {
                    Button("Остановить") { model.cancelVoiceSelfTest() }
                } else {
                    Button {
                        model.startVoiceSelfTest()
                    } label: {
                        CompatLabel(title: "Записать и прослушать", symbol: "mic.fill")
                    }
                    .disabled(!model.canStartSelfTest)
                    .compatHelp(
                        model.isInCall
                            ? "Во время разговора микрофон занят"
                            : "Скажите что-нибудь — потом услышите себя"
                    )
                }
                Spacer()
            }

            if let status = model.selfTestStatus {
                Text(status)
                    .font(.footnote)
                    .compatForeground(.secondary)
            }
        }
        // Уход с экрана обязан закрыть микрофон: иначе он остаётся открытым до
        // конца пяти секунд уже после того, как окно настроек закрыли.
        .onDisappear { model.cancelVoiceSelfTest() }
    }
}

// MARK: - Звонок

private struct RingtoneSection: View {

    @EnvironmentObject private var model: AppModel

    /// Что сказать про выбранный файл. Живёт до следующего выбора.
    @State private var soundProblem: String?

    var body: some View {
        Section(header: Text("Звонок")) {
            Toggle("Проигрывать рингтон", isOn: Binding(
                get: { model.settings.ringtone.isEnabled },
                set: { model.settings.ringtone.isEnabled = $0 }
            ))

            CompatLabeledContent(title: "Громкость") {
                SettingSlider(
                    value: Binding(
                        get: { model.settings.ringtone.volume },
                        set: { model.settings.ringtone.volume = $0 }
                    ),
                    range: 0...1,
                    step: 0.05,
                    unit: nil
                )
            }

            Picker("Играть в", selection: Binding(
                get: { model.settings.ringtone.usesSystemOutput },
                set: { model.settings.ringtone.usesSystemOutput = $0 }
            )) {
                Text("системное устройство").tag(true)
                Text("устройство разговора").tag(false)
            }
            .compatHelp("Гарнитура на столе звонка не слышна — тогда звонить должны колонки")

            CompatLabeledContent("Звук", value: soundName)

            HStack {
                Button("Выбрать файл…") { chooseSound() }
                Button("Стандартный") {
                    model.settings.ringtone.customSoundPath = nil
                    soundProblem = nil
                }
                .disabled(model.settings.ringtone.customSoundPath == nil)

                Button(model.isRingtonePreviewPlaying ? "Остановить" : "Прослушать") {
                    model.toggleRingtonePreview()
                }
                .disabled(!model.settings.ringtone.isEnabled || model.isInCall)
                Spacer()
            }

            if let soundProblem {
                Text(soundProblem)
                    .font(.footnote)
                    .compatForeground(Theme.Palette.failure)
            }
        }
        .disabled(!model.settings.ringtone.isEnabled)
        // Уход с экрана глушит предпрослушивание: иначе рингтон продолжает
        // звонить после закрытия настроек, и остановить его нечем.
        .onDisappear { model.stopRingtonePreview() }
    }

    private var soundName: String {
        guard let path = model.settings.ringtone.customSoundPath, !path.isEmpty else {
            return "Стандартный"
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
        // Пропавший файл называется прямо: рингтон в этом случае молча вернётся
        // к стандартному, и человек должен понимать почему, а не слышать не то.
        return model.settings.ringtone.customSoundURL == nil ? "\(name) — файл не найден" : name
    }

    /// Выбор файла.
    ///
    /// `NSOpenPanel`, а не `fileImporter`: тот появился в macOS 11, а срез
    /// x86_64 живёт с Catalina. Песочницы нет, поэтому обычного пути хватает —
    /// закладка безопасности не нужна.
    private func chooseSound() {
        model.stopRingtonePreview()

        let panel = NSOpenPanel()
        panel.title = "Звук входящего вызова"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedFileTypes = ["wav", "aiff", "aif", "caf", "m4a", "mp3"]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard Ringtone.isPlayable(url: url) else {
            soundProblem = "Этот файл не читается как звук. Подойдут WAV, AIFF, CAF, M4A и MP3."
            return
        }
        soundProblem = nil
        model.settings.ringtone.customSoundPath = url.path
    }
}

// MARK: - Поддержка

private struct SupportSection: View {

    @EnvironmentObject private var model: AppModel

    @State private var archiveResult: String?

    var body: some View {
        Section(header: Text("Техподдержка")) {
            Text("""
                Архив с журналом и сведениями о системе. Соберите его и отправьте \
                в поддержку — по нему разбирают, что случилось со звонком.
                """)
            .font(.footnote)
            .compatForeground(.secondary)

            HStack {
                Button {
                    makeArchive()
                } label: {
                    CompatLabel(title: "Собрать логи для поддержки", symbol: "stethoscope")
                }
                .disabled(!model.settings.logFile.isEnabled)
                Spacer()
            }

            if !model.settings.logFile.isEnabled {
                Text("Журнал в файл выключен — собирать нечего. Включается в «Управлении».")
                    .font(.footnote)
                    .compatForeground(.secondary)
            }

            if let archiveResult {
                Text(archiveResult)
                    .font(.footnote)
                    .compatForeground(.secondary)
                    .lineLimit(2)
            }
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

// MARK: - Подвал с входом в режим

/// Кто управляет настройками и как попасть в закрытую часть.
///
/// Состояние управления показано всегда, а не только когда оно необычно
/// (пункт 3 роадмапа): «локальный режим» должен быть видимым фактом, иначе в
/// M8 разницу между «настройками управляет EliteDash» и «связь с ним
/// потерялась» будет неоткуда узнать.
private struct AdministrationFooter: View {

    @EnvironmentObject private var model: AppModel
    @Binding var isAskingForPassword: Bool

    var body: some View {
        HStack(spacing: 10) {
            CompatSymbol(name: "lock.shield.fill")
                .compatForeground(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.adminAccess.management.title)
                Text(model.adminAccess.management.explanation)
                    .font(.footnote)
                    .compatForeground(.secondary)
            }

            Spacer()

            if model.adminAccess.isUnlocked {
                Button("Выйти из режима") { model.lockAdministration() }
                    .compatHelp("Закрытые вкладки снова скроются")
            } else {
                Button("Управление") {
                    if model.isAdministrationProtected {
                        isAskingForPassword = true
                    } else {
                        // Пароль не задан — открывать нечего. Запись в журнал
                        // всё равно появится: вход в режим фиксируется всегда.
                        try? model.unlockAdministration(password: "")
                    }
                }
                .compatProminentButtonStyle()
                .compatHelp(
                    model.isAdministrationProtected
                        ? "Аккаунты, макросы, защита от автокликеров и диагностика"
                        : "Пароль не задан — настройки открыты. Задать пароль можно внутри."
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
