import CallGuard
import MediaCore
import SIPCore
import SwiftUI

/// Отдельное полноценное окно настроек, а не панель `Settings`.
struct SettingsView: View {

    var body: some View {
        TabView {
            AccountSettingsTab()
                .tabItem { CompatLabel(title: "Аккаунт", symbol: "person.crop.circle") }

            AudioSettingsTab()
                .tabItem { CompatLabel(title: "Звук", symbol: "speaker.wave.2") }

            IncomingCallSettingsTab()
                .tabItem { CompatLabel(title: "Входящие", symbol: "bell") }

            DTMFSettingsTab()
                .tabItem { CompatLabel(title: "Тоны", symbol: "square.grid.3x3") }

            DiagnosticsTab()
                .tabItem { CompatLabel(title: "Диагностика", symbol: "stethoscope") }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 460)
    }
}

private struct AccountSettingsTab: View {

    @EnvironmentObject private var model: AppModel
    @State private var isPasswordRevealed = false

    var body: some View {
        Form {
            Section(header: Text("Учётная запись SIP")) {
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

            Section(header: Text("Пароль")) {
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
                        CompatSymbol(name: isPasswordRevealed ? "eye.slash" : "eye")
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

                    CompatLabel(title: model.hasStoredPassword ? "Пароль сохранён" : "Пароль не задан", symbol: model.hasStoredPassword ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.footnote)
                    .compatForeground(.secondary)
                }

                Text("Пароль хранится в Keychain и не попадает ни в файл настроек, ни в выгрузку диагностики.")
                    .font(.footnote)
                    .compatForeground(.secondary)
            }

            Section(header: Text("Сеть")) {
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
                    CompatLabel(title: "Проверка сертификата отключена. Перехватчик сможет прочитать пароль и разговор. Только для самоподписанного сертификата лаборатории.", symbol: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .compatForeground(Theme.Palette.failure)
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
                        .compatForeground(.secondary)
                }
            }

            Section(header: Text("Лаборатория")) {
                HStack {
                    Button("Пир 100 · UDP") { model.applyLabPreset(.labUDP) }
                    Button("Пир 200 · TLS + SRTP") { model.applyLabPreset(.labTLS) }
                    Spacer()
                }
                Text("Пароли лабораторных пиров: elite100 и elite200.")
                    .font(.footnote)
                    .compatForeground(.secondary)
            }
        }
        .compatGroupedForm()
    }
}

private struct AudioSettingsTab: View {

    @EnvironmentObject private var model: AppModel
    /// Список держится в состоянии, а не читается на каждой перерисовке:
    /// перечисление ходит в HAL, а перерисовок у формы много. Обновляется он по
    /// уведомлению от системы — см. `onAppear`.
    @State private var inputs: [AudioDevice] = []
    @State private var outputs: [AudioDevice] = []
    @State private var observation: AudioDeviceCatalog.Observation?

    var body: some View {
        Form {
            Section(header: Text("Устройства разговора")) {
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
                    CompatLabel(title: "Разные устройства — эхоподавления не будет", symbol: "exclamationmark.triangle.fill")
                    .compatForeground(Theme.Palette.failure)

                    Text("""
                        macOS не даёт совместить системное эхоподавление с разными \
                        устройствами на вход и выход. Через колонки в таком режиме \
                        разговаривать нельзя — собеседник услышит себя.

                        Если нужна именно эта пара и эхоподавление, назначьте её \
                        системной по умолчанию в «Звуке», а здесь оставьте «системное»: \
                        такую пару macOS сводит сама и эхоподавление сохраняет.
                        """)
                    .font(.footnote)
                    .compatForeground(.secondary)
                }
            }

            Section(header: Text("Bluetooth")) {
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
                    CompatLabel(title: "Сейчас включён режим гарнитуры", symbol: "exclamationmark.triangle")
                    .compatForeground(.orange)
                }
            }

            Section(header: Text("Полоса")) {
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

            Section(header: Text("Эхоподавление")) {
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
                Section(header: Text("Текущий разговор")) {
                    CompatLabeledContent("Маршрут", value: route.summary)
                    if let codec = model.negotiatedCodec {
                        CompatLabeledContent(
                            "Кодек",
                            value: codec.sdpName + (codec.isWideband ? " — широкая полоса" : "")
                        )
                    }
                    // Эхоподавление отпадает молча: при разных устройствах на
                    // вход и выход VoiceProcessingIO не запускается вовсе, а при
                    // отказе движка тракт поднимается откатом. Через колонки в
                    // таком разговоре собеседник услышит себя.
                    if let active = model.echoCancellationActive {
                        CompatLabeledContent(
                            "Эхоподавление",
                            value: active ? "работает" : "выключено"
                        )
                        .foregroundColor(active ? nil : Theme.Palette.failure)
                    }
                    LevelMeters(levels: model.audioLevels)

                    if let remote = model.remoteAudioView {
                        CompatLabeledContent("У собеседника", value: remote.summary)
                    }
                }
            }
        }
        .compatGroupedForm()
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
/// Пара индикаторов.
///
/// Отдельная вьюха с собственной подпиской, а не два вызова прямо в форме:
/// уровни обновляются двадцать раз в секунду, и подписываться на них должно
/// только то, что их показывает. Читай `AppModel.audioLevels` эта форма
/// напрямую — перерисовывалась бы вся вкладка вместе со списками устройств.
private struct LevelMeters: View {

    @ObservedObject var levels: AudioLevels

    var body: some View {
        Group {
            LevelMeter(title: "Микрофон", level: levels.input)
            LevelMeter(title: "Приём", level: levels.output)
        }
    }
}

private struct LevelMeter: View {

    let title: String
    let level: Float

    var body: some View {
        CompatLabeledContent(title: title) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.Palette.tertiary.opacity(0.5))
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

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var incomingCall: IncomingCallPanel

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
                        .compatForeground(.secondary)
                } else if !isGuardOn {
                    CompatLabel(
                        title: "Выключение фиксируется в журнале, а в M8 уедет в EliteDash.",
                        symbol: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .compatForeground(Theme.Palette.decline)
                }
            } footer: {
                Text("Автокликер принимает лид быстрее коллег, не находясь за рабочим местом, и лид уходит в тишину.")
                    .font(.caption)
                    .compatForeground(.secondary)
            }

            Section(header: Text("Случайность")) {
                Toggle("Случайная позиция окна", isOn: policy.isRandomPositionEnabled)
                    .compatHelp("Ломает кликеры по фиксированным координатам")

                CompatLabeledContent(title: "Минимальное смещение") {
                    SettingSlider(value: policy.minimumTravel, range: 0...600, step: 25, unit: "pt")
                }
                .disabled(!model.settings.incomingCall.isRandomPositionEnabled)

                CompatLabeledContent(title: "Отступ от краёв экрана") {
                    SettingSlider(value: policy.screenMargin, range: 0...200, step: 8, unit: "pt")
                }
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
                .compatForeground(.secondary)
            }
            .disabled(!isGuardOn)

            Section(header: Text("Признаки живого человека")) {
                Toggle("Требовать движения курсора", isOn: policy.requiresCursorMovement)
                    .compatHelp("CGEvent.post ставит курсор в точку одним событием — пути у такого движения нет")

                CompatLabeledContent(title: "Нужный путь курсора") {
                    SettingSlider(value: policy.requiredCursorTravel, range: 0...200, step: 10, unit: "pt")
                }
                .disabled(!model.settings.incomingCall.requiresCursorMovement)

                Toggle("Отклонять синтетические нажатия", isOn: policy.rejectsSyntheticEvents)
                    .compatHelp("Признак подделывается, поэтому по умолчанию он только пишется в отчёт")
            }
            .disabled(!isGuardOn)

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
                    CompatLabel(title: "Показать окно для проверки", symbol: "bell.badge")
                }

                if let report = model.lastGuardReport {
                    CompatLabeledContent("Последний вызов", value: report.summary)
                        .font(.caption)
                }
            }
        }
        .compatGroupedForm()
    }
}

/// Макросы DTMF и длительность тонов.
private struct DTMFSettingsTab: View {

    @EnvironmentObject private var model: AppModel

    private var macros: [AppSettings.DTMFSettings.Macro] {
        model.settings.dtmf.macros
    }

    var body: some View {
        Form {
            Section(header: Text("Макросы")) {
                if macros.isEmpty {
                    Text("Макросов нет. Кнопка появится на панели во время разговора.")
                        .compatForeground(.secondary)
                        .font(.callout)
                }

                ForEach(macros) { macro in
                    MacroRow(
                        macro: Binding(
                            get: { macro },
                            set: { updated in
                                guard let index = macros.firstIndex(where: { $0.id == macro.id }) else { return }
                                model.settings.dtmf.macros[index] = updated
                            }
                        ),
                        onDelete: {
                            model.settings.dtmf.macros.removeAll { $0.id == macro.id }
                        }
                    )
                }

                Button {
                    model.settings.dtmf.macros.append(.init(title: "Новый", sequence: ""))
                } label: {
                    CompatLabel(title: "Добавить макрос", symbol: "plus")
                }
            }

            Section(header: Text("Запись")) {
                // Формат заказчиком не задан — открытый вопрос 1 в README.
                // Пока принято привычное по телефонам, и об этом честно сказано
                // здесь, а не только в документации.
                Text(
                    """
                    Цифры, «*», «#» и A–D отправляются как тоны. Запятая — пауза; \
                    несколько запятых подряд складываются. Пробелы и дефисы \
                    ни на что не влияют и нужны только для читаемости.
                    """
                )
                .font(.callout)
                .compatForeground(.secondary)

                CompatLabeledContent(title: "Длина паузы") {
                    DelayField(
                        milliseconds: Binding(
                            get: { model.settings.dtmf.pauseMilliseconds },
                            set: { model.settings.dtmf.pauseMilliseconds = max(100, $0) }
                        )
                    )
                }
            }

            Section(header: Text("Тон")) {
                CompatLabeledContent(title: "Длительность") {
                    DelayField(
                        milliseconds: Binding(
                            get: { model.settings.dtmf.toneMilliseconds },
                            set: { model.settings.dtmf.toneMilliseconds = max(40, $0) }
                        )
                    )
                }
                .compatHelp("Минимум по RFC 4733 — 40 мс. Глухие голосовые меню лучше слышат 120")

                CompatLabeledContent(title: "Пауза между тонами") {
                    DelayField(
                        milliseconds: Binding(
                            get: { model.settings.dtmf.gapMilliseconds },
                            set: { model.settings.dtmf.gapMilliseconds = max(20, $0) }
                        )
                    )
                }
                .compatHelp("Без паузы две одинаковые цифры подряд слышны как одна длинная")
            }

            Section {
                TextField(
                    "Feature-code",
                    text: Binding(
                        get: { model.settings.conference.featureCode },
                        set: { model.settings.conference.featureCode = $0 }
                    )
                )
                .font(.system(.body, design: .monospaced))

                TextField(
                    "Добавочный комнаты",
                    text: Binding(
                        get: { model.settings.conference.roomExtension },
                        set: { model.settings.conference.roomExtension = $0 }
                    )
                )
                .font(.system(.body, design: .monospaced))

                if !model.settings.conference.isUsable {
                    CompatLabel(title: "Код должен содержать только DTMF-символы и хотя бы один тон.", symbol: "exclamationmark.triangle")
                    .font(.caption)
                    .compatForeground(.orange)
                }
            } header: {
                Text("Конференция")
            } footer: {
                Text(
                    """
                    Код выполняет dynamic feature Asterisk и переводит оба плеча \
                    текущего разговора в ConfBridge. В лаборатории это *3; боевой \
                    код нужно сверить с features.conf.
                    """
                )
                .font(.caption)
                .compatForeground(.secondary)
            }
        }
        .compatGroupedForm()
    }
}

private struct MacroRow: View {

    @Binding var macro: AppSettings.DTMFSettings.Macro
    let onDelete: () -> Void

    private var problem: String? {
        let unsupported = DTMFSequence.unsupportedCharacters(in: macro.sequence)
        if !unsupported.isEmpty {
            return "не тоны: \(String(unsupported))"
        }
        if !DTMFSequence(macro.sequence).hasTones {
            return "нет ни одного тона"
        }
        if macro.title.trimmingCharacters(in: .whitespaces).isEmpty {
            return "нет подписи"
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("Подпись", text: $macro.title)
                    .frame(width: 140)
                TextField("Набор, например 2,,101#", text: $macro.sequence)
                    .font(.system(.body, design: .monospaced))

                Button(action: onDelete) {
                    CompatSymbol(name: "trash")
                }
                .compatForeground(Theme.Palette.decline)
                .buttonStyle(.borderless)
                .compatHelp("Удалить макрос")
            }

            // Негодный макрос на панели не появится, и молчать об этом нельзя:
            // оператор будет искать кнопку, которой нет.
            if let problem {
                CompatLabel(title: problem, symbol: "exclamationmark.triangle")
                    .font(.caption)
                    .compatForeground(.orange)
            } else {
                Text(DTMFSequence(macro.sequence).displayText)
                    .font(.caption)
                    .compatForeground(.secondary)
            }
        }
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
                .compatMonospacedDigit()
                .compatForeground(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
    }
}

/// Поле для миллисекунд.
///
/// Именно числом, а не ползунком: длительности тонов настраивают один раз и по
/// договорённости с той стороной, и «примерно 700» здесь бесполезно.
private struct DelayField: View {

    @Binding var milliseconds: Int

    var body: some View {
        TextField("", value: $milliseconds, formatter: IntegerFormatter.shared)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .compatMonospacedDigit()
            .frame(width: 64)
            .labelsHidden()
    }
}

private struct DiagnosticsTab: View {

    @EnvironmentObject private var model: AppModel

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
                Section(header: Text("Сборка")) {
                    CompatLabeledContent("Версия", value: appVersion)
                    CompatLabeledContent("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
                    CompatLabeledContent("Оформление", value: glassAvailability)
                    CompatLabeledContent("Файл настроек", value: SettingsStore.fileURL.compatPath)
                }

                Section(header: Text("Уровень журнала")) {
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
            .compatGroupedForm()
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

    /// Журнал.
    ///
    /// Ветка по версии здесь не косметическая, а по наличию API:
    /// `ScrollViewReader`, без которого некуда прокручивать, и `LazyVStack`
    /// появились только в macOS 11. На Catalina журнал остаётся обычным
    /// списком без автопрокрутки — 500 строк обычный `VStack` тянет, а к свежей
    /// записи оператор доводит колесом.
    @ViewBuilder
    private var logView: some View {
        if #available(macOS 11.0, *) {
            ScrollViewReader { proxy in
                logScroll(isLazy: true)
                    .onChange(of: model.log.count) { _ in
                        // Прокрутка к свежей строке: без неё журнал бесполезен
                        // ровно в тот момент, когда он нужен.
                        if let last = model.log.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
            }
        } else {
            logScroll(isLazy: false)
        }
    }

    @ViewBuilder
    private func logScroll(isLazy: Bool) -> some View {
        ScrollView {
            Group {
                if isLazy, #available(macOS 11.0, *) {
                    LazyVStack(alignment: .leading, spacing: 2) { logLines }
                } else {
                    VStack(alignment: .leading, spacing: 2) { logLines }
                }
            }
            .padding(8)
        }
        .frame(minHeight: 120)
        .themedControlSurface()
        .compatOverlay {
            if model.log.isEmpty {
                Text("Пусто. Нажмите «Подключить».")
                    .font(.footnote)
                    .compatForeground(Theme.Palette.tertiary)
            }
        }
    }

    private var logLines: some View {
        ForEach(model.log) { entry in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(TimeText.withSeconds.string(from: entry.date))
                    .compatForeground(Theme.Palette.tertiary)
                Text(entry.message)
                    .compatForeground(color(for: entry.level))
                    .compatTextSelection()
            }
            .font(.system(size: 11, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(entry.id)
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
