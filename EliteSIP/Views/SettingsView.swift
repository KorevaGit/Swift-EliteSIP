import CallGuard
import MediaCore
import SIPCore
import SwiftUI

/// Отдельное полноценное окно настроек, а не панель `Settings`.
struct SettingsView: View {

    var body: some View {
        TabView {
            AccountSettingsTab()
                .tabItem { Label("Аккаунт", systemImage: "person.crop.circle") }

            AudioSettingsTab()
                .tabItem { Label("Звук", systemImage: "speaker.wave.2") }

            IncomingCallSettingsTab()
                .tabItem { Label("Входящие", systemImage: "bell") }

            DiagnosticsTab()
                .tabItem { Label("Диагностика", systemImage: "stethoscope") }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 460)
    }
}

private struct AccountSettingsTab: View {

    @Environment(AppModel.self) private var model
    @State private var isPasswordRevealed = false

    var body: some View {
        Form {
            Section("Учётная запись SIP") {
                TextField("Внутренний номер", text: Binding(
                    get: { model.settings.account.username },
                    set: { model.settings.account.username = $0 }
                ))
                TextField("Отображаемое имя", text: Binding(
                    get: { model.settings.account.displayName },
                    set: { model.settings.account.displayName = $0 }
                ))
                TextField("Домен или адрес сервера", text: Binding(
                    get: { model.settings.account.domain },
                    set: { model.settings.account.domain = $0 }
                ))
                TextField("Логин для входа, если отличается", text: Binding(
                    get: { model.settings.account.authUsername ?? "" },
                    set: { model.settings.account.authUsername = $0.isEmpty ? nil : $0 }
                ))
            }

            Section("Пароль") {
                HStack {
                    if isPasswordRevealed {
                        TextField("Пароль", text: Binding(
                            get: { model.passwordDraft },
                            set: { model.passwordDraft = $0 }
                        ))
                    } else {
                        SecureField("Пароль", text: Binding(
                            get: { model.passwordDraft },
                            set: { model.passwordDraft = $0 }
                        ))
                    }
                    Button {
                        isPasswordRevealed.toggle()
                    } label: {
                        Image(systemName: isPasswordRevealed ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }

                HStack {
                    Button("Сохранить в Keychain") {
                        model.savePassword()
                    }
                    .disabled(model.passwordDraft.isEmpty)

                    if model.hasStoredPassword {
                        Button("Удалить сохранённый") {
                            model.forgetPassword()
                        }
                    }

                    Spacer()

                    Label(
                        model.hasStoredPassword ? "Пароль сохранён" : "Пароль не задан",
                        systemImage: model.hasStoredPassword ? "checkmark.circle" : "exclamationmark.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Text("Пароль хранится в Keychain и не попадает ни в файл настроек, ни в выгрузку диагностики.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Сеть") {
                Picker("Транспорт", selection: Binding(
                    get: { model.settings.account.transport },
                    set: { model.settings.account.transport = $0 }
                )) {
                    Text("TLS (боевой)").tag(SIPTransport.tls)
                    Text("UDP (только лаборатория)").tag(SIPTransport.udp)
                }
                .pickerStyle(.radioGroup)

                TextField("Порт", text: Binding(
                    get: { model.settings.account.serverPort.map(String.init) ?? "" },
                    set: { model.settings.account.serverPort = UInt16($0) }
                ))
                .frame(width: 100)

                Stepper(
                    "Срок регистрации: \(model.settings.account.registrationExpires) с",
                    value: Binding(
                        get: { model.settings.account.registrationExpires },
                        set: { model.settings.account.registrationExpires = $0 }
                    ),
                    in: 60...3600,
                    step: 60
                )

                Toggle("Доверять любому сертификату TLS", isOn: Binding(
                    get: { model.settings.acceptsAnyTLSCertificate },
                    set: { model.settings.acceptsAnyTLSCertificate = $0 }
                ))

                if model.settings.acceptsAnyTLSCertificate {
                    Label(
                        "Проверка сертификата отключена. Перехватчик сможет прочитать пароль и разговор. Только для самоподписанного сертификата лаборатории.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(Theme.Palette.failure)
                }
            }

            Section {
                HStack {
                    if model.isConnected || model.isBusy {
                        Button("Отключить") { Task { await model.disconnect() } }
                        Button("Переподключить") { Task { await model.reconnect() } }
                    } else {
                        Button("Подключить") { Task { await model.connect() } }
                            .disabled(!model.canConnect)
                    }
                    Spacer()
                    Text(model.registrationTitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Лаборатория") {
                HStack {
                    Button("Пир 100 · UDP") { model.applyLabPreset(.labUDP) }
                    Button("Пир 200 · TLS + SRTP") { model.applyLabPreset(.labTLS) }
                    Spacer()
                }
                Text("Пароли лабораторных пиров: elite100 и elite200.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AudioSettingsTab: View {

    @Environment(AppModel.self) private var model
    /// Список держится в состоянии, а не читается на каждой перерисовке:
    /// перечисление ходит в HAL, а перерисовок у формы много. Обновляется он по
    /// уведомлению от системы — см. `onAppear`.
    @State private var inputs: [AudioDevice] = []
    @State private var outputs: [AudioDevice] = []
    @State private var observation: AudioDeviceCatalog.Observation?

    var body: some View {
        Form {
            Section("Устройства разговора") {
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
                    // Размен настоящий и неприятный, поэтому назван прямо.
                    // VoiceProcessingIO не принимает агрегатные устройства —
                    // проверено на приватном, публичном и с разными ведущими,
                    // всегда -10851. Свой агрегат он строит только для
                    // системных умолчаний, отсюда и совет ниже.
                    Label(
                        "Разные устройства — эхоподавления не будет",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(Theme.Palette.failure)

                    Text("""
                        macOS не даёт совместить системное эхоподавление с разными \
                        устройствами на вход и выход. Через колонки в таком режиме \
                        разговаривать нельзя — собеседник услышит себя.

                        Если нужна именно эта пара и эхоподавление, назначьте её \
                        системной по умолчанию в «Звуке», а здесь оставьте «системное»: \
                        такую пару macOS сводит сама и эхоподавление сохраняет.
                        """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }

            Section("Bluetooth") {
                Toggle("Отпускать устройство между звонками", isOn: Binding(
                    get: { model.settings.audio.releasesDeviceWhenIdle },
                    set: { model.settings.audio.releasesDeviceWhenIdle = $0 }
                ))
                MilestoneNote("""
                    Пока микрофон гарнитуры открыт, AirPods работают в двустороннем \
                    режиме, и звук всей системы становится глуше. Остановки движка \
                    для возврата не хватает — устройство надо отпускать явно.
                    """)

                if model.isHeadsetModeActive {
                    Label(
                        "Сейчас включён режим гарнитуры",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }

            Section("Полоса") {
                Toggle("Предлагать широкую полосу (G.722)", isOn: Binding(
                    get: { model.settings.audio.prefersWideband },
                    set: { model.settings.audio.prefersWideband = $0 }
                ))
                MilestoneNote("""
                    50–7000 Гц вместо 300–3400 при том же битрейте. Работает на \
                    внутренних звонках и в очередях. Лид с городского номера всё равно \
                    приедет через G.711 — там выигрыша не будет, а перекодирование на \
                    АТС появится.
                    """)
            }

            Section("Эхоподавление") {
                MilestoneNote("Берём системный VoiceProcessingIO — тот же движок, что у FaceTime. Своего эхоподавителя не пишем.")

                Toggle("Автоматическая регулировка усиления", isOn: Binding(
                    get: { model.settings.audio.automaticGainControl },
                    set: { model.settings.audio.automaticGainControl = $0 }
                ))
                MilestoneNote("""
                    Система включает её сама. На встроенном микрофоне полезна, на \
                    хорошей гарнитуре «дышит»: подтягивает шум в паузах и приседает на \
                    громком слоге. Эхоподавление от неё не зависит и остаётся включённым.
                    """)
            }

            if let route = model.audioRoute {
                Section("Текущий разговор") {
                    LabeledContent("Маршрут", value: route.summary)
                    if let codec = model.negotiatedCodec {
                        LabeledContent(
                            "Кодек",
                            value: codec.sdpName + (codec.isWideband ? " — широкая полоса" : "")
                        )
                    }
                    LevelMeter(title: "Микрофон", level: model.inputLevel)
                    LevelMeter(title: "Приём", level: model.outputLevel)

                    if let remote = model.remoteAudioView {
                        LabeledContent("У собеседника", value: remote.summary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            reloadDevices()
            // Списки сами следят за составом устройств: наушники подключают и
            // отключают посреди настройки, и кнопка «обновить» в такой момент
            // выглядит как неисправность.
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

/// Полоска уровня.
///
/// Нужна затем, чтобы оператор видел, что микрофон живой, до того как начнёт
/// говорить, — а не узнавал об этом от собеседника.
private struct LevelMeter: View {

    let title: String
    let level: Float

    var body: some View {
        LabeledContent(title) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(color)
                        // Корень вместо самого уровня: слух логарифмический, и на
                        // линейной шкале обычная речь болтается у левого края.
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

/// Вкладка защиты приёма вызова.
///
/// Раздел не про внешний вид окна, а про то, ради чего написано приложение,
/// поэтому у каждой настройки в подписи стоит не «что», а «зачем»: оператор,
/// который понимает, от чего защищается, не выключает это первым делом.
private struct IncomingCallSettingsTab: View {

    @Environment(AppModel.self) private var model
    @Environment(IncomingCallPanel.self) private var incomingCall

    private var policy: Binding<CallGuardPolicy> {
        Binding(
            get: { model.settings.incomingCall },
            set: { model.settings.incomingCall = $0 }
        )
    }

    private var isGuardOn: Bool { model.settings.incomingCall.isEnabled }

    var body: some View {
        Form {
            Section {
                Toggle("Защита от автокликеров", isOn: policy.isEnabled)
                    // Место под вариант «значением управляет EliteDash»: пока
                    // всегда активно, но интерфейс уже готов показать иное.
                    .disabled(model.settings.incomingCall.isServerManaged)

                if model.settings.incomingCall.isServerManaged {
                    Text("Значением управляет EliteDash.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !isGuardOn {
                    Label(
                        "Выключение фиксируется в журнале, а в M8 уедет в EliteDash.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.decline)
                }
            } footer: {
                Text("Автокликер принимает лид быстрее коллег, не находясь за рабочим местом, и лид уходит в тишину.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Случайность") {
                Toggle("Случайная позиция окна", isOn: policy.isRandomPositionEnabled)
                    .help("Ломает кликеры по фиксированным координатам")

                LabeledContent("Минимальное смещение") {
                    SettingSlider(value: policy.minimumTravel, range: 0...600, step: 25, unit: "pt")
                }
                .disabled(!model.settings.incomingCall.isRandomPositionEnabled)

                LabeledContent("Отступ от краёв экрана") {
                    SettingSlider(value: policy.screenMargin, range: 0...200, step: 8, unit: "pt")
                }

                LabeledContent("Задержка активации") {
                    HStack(spacing: 8) {
                        DelayField(milliseconds: policy.minimumActivationDelayMilliseconds)
                        Text("—").foregroundStyle(.secondary)
                        DelayField(milliseconds: policy.maximumActivationDelayMilliseconds)
                        Text("мс").foregroundStyle(.secondary)
                    }
                }
                .help("Клик раньше срока не принимается и попадает в отчёт")

            }
            .disabled(!isGuardOn)

            Section {
                Toggle("Цифровое подтверждение", isOn: Binding(
                    get: { model.settings.incomingCall.targetCount > 1 },
                    set: { model.settings.incomingCall.targetCount = $0 ? 3 : 1 }
                ))

                if model.settings.incomingCall.targetCount > 1 {
                    Picker("Целей на выбор", selection: policy.targetCount) {
                        ForEach(2...5, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                }
            } header: {
                Text("Подтверждение цифрой")
            } footer: {
                Text("""
                Вместо кнопки «Ответить» показывается ряд цифр, и вызов принимает \
                только одна из них — названная в подписи. Ломает кликер, который ищет \
                кнопку по картинке. Выключено по умолчанию: это внимание оператора на \
                каждом вызове, а случайная позиция окна обходится ему бесплатно.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .disabled(!isGuardOn)

            Section("Признаки живого человека") {
                Toggle("Требовать движения курсора", isOn: policy.requiresCursorMovement)
                    .help("CGEvent.post ставит курсор в точку одним событием — пути у такого движения нет")

                LabeledContent("Нужный путь курсора") {
                    SettingSlider(value: policy.requiredCursorTravel, range: 0...200, step: 10, unit: "pt")
                }
                .disabled(!model.settings.incomingCall.requiresCursorMovement)

                Toggle("Отклонять синтетические нажатия", isOn: policy.rejectsSyntheticEvents)
                    .help("Признак подделывается, поэтому по умолчанию он только пишется в отчёт")
            }
            .disabled(!isGuardOn)

            Section("Звонок") {
                Toggle("Проигрывать рингтон", isOn: Binding(
                    get: { model.settings.ringtone.isEnabled },
                    set: { model.settings.ringtone.isEnabled = $0 }
                ))

                LabeledContent("Громкость") {
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
                .help("Гарнитура на столе звонка не слышна — тогда звонить должны колонки")
            }
            .disabled(!model.settings.ringtone.isEnabled)

            Section {
                Button {
                    incomingCall.show(
                        callerNumber: "2929",
                        callerName: "AutoDialer",
                        policy: model.settings.incomingCall,
                        onAnswer: {},
                        onDecline: {}
                    )
                } label: {
                    Label("Показать окно для проверки", systemImage: "bell.badge")
                }

                if let report = model.lastGuardReport {
                    LabeledContent("Последний вызов", value: report.summary)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct SettingSlider: View {

    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String?

    var body: some View {
        HStack {
            Slider(value: $value, in: range, step: step)
            Text(unit == nil ? String(format: "%.0f %%", value * 100) : "\(Int(value)) \(unit!)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
    }
}

/// Поле для миллисекунд.
///
/// Именно числом, а не ползунком: диапазон задержки — это то, что настраивают
/// один раз и по договорённости, и «примерно 700» здесь бесполезно.
private struct DelayField: View {

    @Binding var milliseconds: Int

    var body: some View {
        TextField("", value: $milliseconds, format: .number)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: 64)
            .labelsHidden()
    }
}

private struct DiagnosticsTab: View {

    @Environment(AppModel.self) private var model

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    private var glassAvailability: String {
        if #available(macOS 26.0, *) {
            "Liquid Glass доступен"
        } else {
            "Liquid Glass недоступен, используются материалы"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Section("Сборка") {
                    LabeledContent("Версия", value: appVersion)
                    LabeledContent("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
                    LabeledContent("Оформление", value: glassAvailability)
                    LabeledContent("Файл настроек", value: SettingsStore.fileURL.path(percentEncoded: false))
                }

                Section("Уровень журнала") {
                    Picker("Показывать от", selection: Binding(
                        get: { model.settings.minimumLogLevel },
                        set: { model.settings.minimumLogLevel = $0 }
                    )) {
                        ForEach(SIPLogLevel.allCases, id: \.self) { level in
                            Text(level.rawValue).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 240)

            HStack {
                Text("Журнал SIP")
                    .font(.headline)
                Spacer()
                Button("Скопировать") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.logText, forType: .string)
                }
                .disabled(model.log.isEmpty)
                Button("Очистить") { model.clearLog() }
                    .disabled(model.log.isEmpty)
            }

            logView
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.log) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.date.formatted(date: .omitted, time: .standard))
                                .foregroundStyle(.tertiary)
                            Text(entry.message)
                                .foregroundStyle(color(for: entry.level))
                                .textSelection(.enabled)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(entry.id)
                    }
                }
                .padding(8)
            }
            .frame(minHeight: 120)
            .themedControlSurface()
            .onChange(of: model.log.count) {
                // Прокрутка к свежей строке: без неё журнал бесполезен ровно в
                // тот момент, когда он нужен.
                if let last = model.log.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .overlay {
                if model.log.isEmpty {
                    Text("Пусто. Нажмите «Подключить».")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func color(for level: SIPLogLevel) -> Color {
        switch level {
        case .debug: .secondary
        case .info: .primary
        case .warning: Theme.Palette.connecting
        case .error: Theme.Palette.failure
        }
    }
}
