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
        // «Управление» — последней секцией внутри прокрутки, а не закреплённым
        // подвалом. Закреплённый подвал стоял бы перед глазами менеджера всё
        // время, а это дверь не для него: он должен её найти, если понадобится,
        // а не спотыкаться о неё, меняя громкость.
        Form {
            WorkplaceSection()
            AudioSection()
            SelfTestSection()
            RingtoneSection()
            SupportSection()
            AdministrationSection(isAskingForPassword: $isAskingForPassword)
        }
        .compatGroupedForm()
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
            // Список, а не выпадающий выбор: у профиля три разных признака —
            // номер, формат работы и пометка менеджера, — и в одну строку
            // `Picker` они помещаются только ценой того, что два из трёх
            // придётся выбросить.
            //
            // Выбрать можно, править нельзя: завести, переименовать или удалить
            // профиль — административное действие. Менеджеру нужно ровно одно:
            // переключиться на тот, что ему выдали, и подписать его для себя.
            ForEach(model.profiles) { profile in
                ManagerProfileRow(profile: profile)
            }

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
private struct AdministrationSection: View {

    @EnvironmentObject private var model: AppModel
    @Binding var isAskingForPassword: Bool

    var body: some View {
        Section(header: Text("Управление настройками")) {
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

                Button {
                    isAskingForPassword = true
                } label: {
                    // Шеврон как у раскрывашки: кнопка не меняет эту страницу,
                    // а ведёт в другое окно, и выглядеть должна именно так.
                    HStack(spacing: 6) {
                        Text("Управление")
                        Text("\u{203A}")
                    }
                }
                // Обычная кнопка, а не акцентная: акцент на этой странице
                // принадлежит самопроверке и «Исправить сеть» — тому, чем
                // менеджер пользуется. Дорога к закрытым настройкам должна быть
                // доступной, а не заметной.
                .compatHelp("Аккаунты, макросы, защита от автокликеров и диагностика — в отдельном окне")
            }
        }
    }
}

// MARK: - Строка профиля

/// Профиль глазами менеджера: название, номер, формат работы — в этом порядке.
///
/// Три признака отвечают на три разных вопроса, и подменять один другим нельзя.
/// Название («Лаба», «Боевой») говорит, который профиль «мой», — по нему и
/// выбирают, потому что номер в списке из двух добавочных на одной АТС не
/// различает ничего. Номер и офис/удалёнка говорят, куда профиль звонит: по ним
/// его опознают в поддержке.
///
/// Отсюда порядок слева направо: сначала то, по чему выбирают, потом то, по
/// чему опознают.
///
/// **Нажатие в любое место строки переключает профиль.** Это главное действие
/// списка, и требовать попасть в галочку размером 15 pt значило бы сделать его
/// самым трудным. Переименование поэтому спрятано за карандашом: строка,
/// которая одновременно и кнопка, и поле ввода, на одно из двух не годится, а
/// править название нужно куда реже, чем переключаться.
private struct ManagerProfileRow: View {

    @EnvironmentObject private var model: AppModel
    let profile: SIPProfile

    /// Правится ли название прямо сейчас. Своё у каждой строки: два поля
    /// одновременно не нужны, а гасить чужое пришлось бы отдельным состоянием
    /// на весь список.
    @State private var isEditingLabel = false

    private var isActive: Bool { profile.id == model.activeProfileID }

    /// Формат работы как он решится на самом деле: у профиля с `.automatic`
    /// это решение по адресу сервера, и показывать «по адресу сервера» вместо
    /// ответа значило бы оставить вопрос открытым.
    private var site: SIPProfileSite {
        PortKnockPolicy.resolvedSite(serverHost: profile.account.domain, site: profile.site)
    }

    var body: some View {
        HStack(spacing: 10) {
            // Отметка занимает место и когда её нет: иначе строки разъезжаются
            // при смене активного профиля.
            if isActive {
                CompatSymbol(name: "checkmark.circle", size: 15)
                    .compatForeground(Theme.Palette.registered)
            } else {
                Color.clear.frame(width: 15, height: 15)
            }

            if isEditingLabel {
                // `labelsHidden` обязателен: в `Form` первый строковый аргумент
                // `TextField` становится подписью в левой колонке, и placeholder
                // уезжает от собственного поля через всю строку.
                TextField("Без названия", text: Binding(
                    get: { profile.label },
                    set: { model.renameProfile(profile.id, to: $0) }
                ))
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(profile.label.isEmpty ? "Без названия" : profile.label)
                    .compatForeground(profile.label.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                isEditingLabel.toggle()
            } label: {
                CompatSymbol(name: isEditingLabel ? "checkmark.circle" : "pencil")
            }
            .buttonStyle(.borderless)
            .compatForeground(.secondary)
            .compatHelp(
                isEditingLabel
                    ? "Готово"
                    : "Переименовать — название видно только на этой машине"
            )

            Text(number)
                .compatForeground(.secondary)
                .frame(width: 90, alignment: .trailing)

            Text(site == .remote ? "удалённо" : "офис")
                .compatForeground(.secondary)
                .frame(width: 80, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Нажатие по строке переключает профиль. Поле ввода и карандаш
            // забирают нажатие себе, поэтому переименование ему не мешает.
            guard !isEditingLabel, !isActive, model.canSwitchProfile else { return }
            Task { await model.selectProfile(profile.id) }
        }
        .compatHelp(
            isActive
                ? "Активный профиль"
                : (model.canSwitchProfile ? "Нажмите, чтобы сделать активным" : "Недоступно в разговоре")
        )
    }

    private var number: String {
        profile.account.username.isEmpty ? "номер не задан" : profile.account.username
    }
}
