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
    var body: some View {
        Form {
            Section("Устройства") {
                MilestoneNote("Выбор микрофона, наушников и отдельного устройства для звонка входящего появится в M2–M3, когда заведётся аудиотракт.")
            }
            Section("Эхоподавление") {
                MilestoneNote("Берём системный VoiceProcessingIO — тот же движок, что у FaceTime. Своего эхоподавителя не пишем.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct IncomingCallSettingsTab: View {

    @Environment(AppModel.self) private var model
    @Environment(IncomingCallPanel.self) private var incomingCall

    var body: some View {
        Form {
            Section("Размещение окна") {
                Toggle("Случайная позиция окна", isOn: Binding(
                    get: { model.settings.incomingCall.isRandomPositionEnabled },
                    set: { model.settings.incomingCall.isRandomPositionEnabled = $0 }
                ))

                LabeledContent("Минимальное смещение") {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { model.settings.incomingCall.minimumTravel },
                                set: { model.settings.incomingCall.minimumTravel = $0 }
                            ),
                            in: 0...600,
                            step: 25
                        )
                        Text("\(Int(model.settings.incomingCall.minimumTravel)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                .disabled(!model.settings.incomingCall.isRandomPositionEnabled)

                LabeledContent("Отступ от краёв экрана") {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { model.settings.incomingCall.screenMargin },
                                set: { model.settings.incomingCall.screenMargin = $0 }
                            ),
                            in: 0...200,
                            step: 8
                        )
                        Text("\(Int(model.settings.incomingCall.screenMargin)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                }
            }

            Section {
                Button {
                    incomingCall.show(
                        callerNumber: "22998",
                        callerName: "Проверка размещения",
                        placement: model.settings.incomingCall,
                        onAnswer: {},
                        onDecline: {}
                    )
                } label: {
                    Label("Показать окно для проверки", systemImage: "bell.badge")
                }
                MilestoneNote("Запретная зона под CRM и перетасовка кнопок — M3, когда определимся с целью рандомизации.")
            }
        }
        .formStyle(.grouped)
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
