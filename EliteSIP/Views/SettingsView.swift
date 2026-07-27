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
        .frame(minWidth: 620, minHeight: 420)
    }
}

private struct AccountSettingsTab: View {

    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Учётная запись SIP") {
                TextField("Внутренний номер", text: Binding(
                    get: { model.account.username },
                    set: { model.account.username = $0 }
                ))
                TextField("Отображаемое имя", text: Binding(
                    get: { model.account.displayName },
                    set: { model.account.displayName = $0 }
                ))
                TextField("Домен или адрес сервера", text: Binding(
                    get: { model.account.domain },
                    set: { model.account.domain = $0 }
                ))
            }

            Section("Сеть") {
                Picker("Транспорт", selection: Binding(
                    get: { model.account.transport },
                    set: { model.account.transport = $0 }
                )) {
                    Text("TLS (боевой)").tag("tls")
                    Text("UDP (только лаборатория)").tag("udp")
                }
                .pickerStyle(.radioGroup)

                LabeledContent("Порт") {
                    Text(String(model.account.port))
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                MilestoneNote("Поля пока живут только в памяти. В M1 они поедут в файл настроек, а пароль — сразу в Keychain, минуя и файл, и эту модель.")
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
                    get: { model.placement.isEnabled },
                    set: { model.placement.isEnabled = $0 }
                ))

                LabeledContent("Минимальное смещение") {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { model.placement.minimumTravel },
                                set: { model.placement.minimumTravel = $0 }
                            ),
                            in: 0...600,
                            step: 25
                        )
                        Text("\(Int(model.placement.minimumTravel)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                .disabled(!model.placement.isEnabled)

                LabeledContent("Отступ от краёв экрана") {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { model.placement.screenMargin },
                                set: { model.placement.screenMargin = $0 }
                            ),
                            in: 0...200,
                            step: 8
                        )
                        Text("\(Int(model.placement.screenMargin)) pt")
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
                        placement: model.placement,
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
        Form {
            Section("Сборка") {
                LabeledContent("Версия", value: appVersion)
                LabeledContent("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
                LabeledContent("Оформление", value: glassAvailability)
            }

            Section("Лаборатория") {
                LabeledContent("SIP UDP", value: "127.0.0.1:5060")
                LabeledContent("SIP TLS", value: "127.0.0.1:5061")
                LabeledContent("Пиры", value: "100, 101, 102 (UDP) · 200 (TLS+SRTP)")
                LabeledContent("Эхо-тест", value: "600")
                LabeledContent("Конференция", value: "8000")
            }

            Section {
                MilestoneNote("Журнал и кнопка выгрузки диагностики — M7.")
            }
        }
        .formStyle(.grouped)
    }
}
