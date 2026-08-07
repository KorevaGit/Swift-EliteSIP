import SIPCore
import SwiftUI

/// Раздел «Аккаунт»: кто мы для АТС и как до неё дозваниваемся.
///
/// Самый крупный раздел окна и единственный, где ошибка стоит связи целиком.
/// Отсюда две особенности раскладки, которых нет в остальных разделах:
/// подключение отделено от полей чертой, а опасное вынесено вниз своей группой.
struct AccountSettingsTab: View {

    @EnvironmentObject private var model: AppModel
    @State private var isPasswordRevealed = false

    var body: some View {
        SettingsSection("Профили") {
            if model.profiles.isEmpty {
                SettingsNote("Профилей нет. Пока не заведён хотя бы один, звонить не с чего.")
            } else {
                SettingsColumns(model.profiles) { profile in
                    ProfileCard(profile: profile)
                }
            }

            SettingsButtonsRow {
                Button("Добавить профиль") { model.addProfile() }
                    .disabled(!model.canSwitchProfile)

                if !model.canSwitchProfile {
                    Text("смена профиля недоступна в разговоре")
                        .font(.footnote)
                        .compatForeground(Theme.Palette.textSecondary)
                }
            }

            SettingsNote("""
                Зарегистрирован всегда ровно один профиль — отмеченный. У каждого свой пароль; \
                удаление профиля стирает и его.
                """)
        }

        SettingsSection("Рабочее место") {
            SettingsIndented { WorkplacePicker() }

            SettingsNote("""
                Переключение меняет и адрес АТС: изнутри и снаружи это один и тот же сервер, \
                но разные адреса. Удалённому месту приложение перед подключением открывает \
                дорогу до АТС.
                """)

            SettingsButtonsRow {
                Button("Исправить сеть") {
                    Task { await model.repairNetwork() }
                }
                .compatHelp("Открыть дорогу до АТС прямо сейчас — если снаружи перестало подключаться")

                if let status = model.networkRepairStatus {
                    Text(status)
                        .font(.footnote)
                        .compatForeground(Theme.Palette.textSecondary)
                        .lineLimit(1)
                }
            }
        }

        SettingsSection("Учётная запись SIP") {
            SettingsRow("Внутренний номер") {
                TextField("", text: Binding(
                    get: { model.settings.account.username },
                    set: { model.settings.account.username = $0 }
                ))
                .labelsHidden()
            }
            SettingsRow("Отображаемое имя") {
                TextField("", text: Binding(
                    get: { model.settings.account.displayName },
                    set: { model.settings.account.displayName = $0 }
                ))
                .labelsHidden()
            }
            SettingsRow("Домен АТС") {
                TextField("", text: Binding(
                    get: { model.settings.account.domain },
                    set: { model.settings.account.domain = $0 }
                ))
                .labelsHidden()
            }
            SettingsRow("Логин для входа") {
                TextField("если отличается от номера", text: Binding(
                    get: { model.settings.account.authUsername ?? "" },
                    set: { model.settings.account.authUsername = $0.isEmpty ? nil : $0 }
                ))
                .labelsHidden()
            }

            SettingsRow("Пароль") {
                // Обычное поле профиля, без кнопок «Принять» и «Удалить».
                // Придержку до «Сохранить» делает само окно «Управление»: на
                // диск не уходит ничего, пока оно открыто, а «Отменить»
                // возвращает снимок вместе с паролем.
                HStack(spacing: Theme.Metrics.tightSpacing) {
                    if isPasswordRevealed {
                        TextField("", text: Binding(
                            get: { model.settings.sipPassword },
                            set: { model.settings.sipPassword = $0 }
                        ))
                        .labelsHidden()
                    } else {
                        SecureField("", text: Binding(
                            get: { model.settings.sipPassword },
                            set: { model.settings.sipPassword = $0 }
                        ))
                        .labelsHidden()
                    }
                    Button {
                        isPasswordRevealed.toggle()
                    } label: {
                        CompatSymbol(name: isPasswordRevealed ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .compatAccessibilityLabel(isPasswordRevealed ? "Скрыть пароль" : "Показать пароль")
                }
            }

            SettingsNote("""
                Пароль от добавочного вписывает администратор: оператор его не знает и вводить \
                не должен. Хранится в файле настроек этой машины, рядом с номером профиля, \
                и в выгрузку диагностики не попадает.
                """)
        }

        SettingsSection("Сеть") {
            SettingsRow("Порт") {
                TextField("по умолчанию", text: Binding(
                    get: { model.settings.account.serverPort.map(String.init) ?? "" },
                    set: { model.settings.account.serverPort = UInt16($0) }
                ))
                .labelsHidden()
                .frame(width: 90)
            }

            SettingsRow("Регистрация") {
                Stepper(
                    "каждые \(model.settings.account.registrationExpires) с",
                    value: Binding(
                        get: { model.settings.account.registrationExpires },
                        set: { model.settings.account.registrationExpires = $0 }
                    ),
                    in: 60...3600,
                    step: 60
                )
            }

            // Черта, потому что ниже не настройка, а инструмент.
            //
            // Подключение действует немедленно, а поля над ним придержаны до
            // «Сохранить». Стоя в одном ряду, кнопка и поля читались бы как
            // одно целое, и человек ждал бы, что «Переподключить» применит
            // только что вписанный домен. Оно применит тот, что на диске.
            SettingsDivider()

            SettingsButtonsRow {
                if model.isConnected || model.isBusy {
                    // Оба действия закрывают активные диалоги, поэтому в
                    // разговоре недоступны — как и на панели.
                    Button("Отключить") { Task { await model.disconnect() } }
                        .disabled(!model.canDisconnect)
                    Button("Переподключить") { Task { await model.reconnect() } }
                        .disabled(!model.canDisconnect)
                    if !model.canDisconnect {
                        Text("недоступно в разговоре")
                            .font(.footnote)
                            .compatForeground(Theme.Palette.textSecondary)
                    }
                } else {
                    Button("Подключить") { Task { await model.connect() } }
                        .disabled(!model.canConnect)
                }
            }

            SettingsResolvedValue(model.registrationTitle)
        }

        UnsafeTransportSection()

        // Лаборатория живёт только в отладочной сборке.
        //
        // Кнопка заводит лабораторный профиль и делает его активным — то есть
        // снимает оператора со связи между звонками, — а рядом открытым текстом
        // стояли пароли пиров. На боевой машине этому места нет, и `#if DEBUG`
        // убирает из выпускаемого бинарника заодно и пароли: `strings` их там не
        // найдёт.
        #if DEBUG
        LabPresetsSection()
        #endif
    }
}

// MARK: - Опасное

/// Настройки, которые ослабляют защиту связи.
///
/// Своей группой внизу раздела, а не в общем ряду с портом. Тот же приём, что у
/// «Забытого пароля» в «Доступе»: найти можно, наткнуться случайно — нет. До
/// этапа 5 оба стояли среди обычных строк и были помечены только словом в
/// скобках, хотя первый выключает проверку сертификата, а второй пускает SIP
/// открытым текстом.
private struct UnsafeTransportSection: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        SettingsSection("Небезопасное") {
            SettingsRow("Транспорт") {
                Picker("", selection: Binding(
                    get: { model.settings.account.transport },
                    set: { model.settings.account.transport = $0 }
                )) {
                    Text("TLS (боевой)").tag(SIPTransport.tls)
                    Text("UDP (только лаборатория)").tag(SIPTransport.udp)
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
            }

            if model.settings.account.transport == .udp {
                SettingsNote(
                    """
                    UDP не шифрует ничего: пароль, номера и сам разговор идут по сети открытым \
                    текстом. Годится только для стенда.
                    """,
                    isAlarming: true
                )
            }

            SettingsToggleRow("Доверять любому сертификату TLS", isOn: Binding(
                get: { model.settings.acceptsAnyTLSCertificate },
                set: { model.settings.acceptsAnyTLSCertificate = $0 }
            ))

            if model.settings.acceptsAnyTLSCertificate {
                SettingsNote(
                    """
                    Проверка сертификата отключена. Перехватчик сможет прочитать пароль \
                    и разговор. Только для самоподписанного сертификата лаборатории.
                    """,
                    isAlarming: true
                )
            }
        }
    }
}

#if DEBUG
private struct LabPresetsSection: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        SettingsSection("Лаборатория") {
            SettingsButtonsRow {
                // Пресет заводит профиль и делает его активным, то есть это та
                // же смена профиля со всеми её последствиями.
                Button("Пир 100 · UDP") { model.applyLabPreset(.labUDP) }
                    .disabled(!model.canSwitchProfile)
                Button("Пир 200 · TLS + SRTP") { model.applyLabPreset(.labTLS) }
                    .disabled(!model.canSwitchProfile)
            }
            SettingsNote("""
                Пароли лабораторных пиров: elite100 и elite200. Блока нет в выпускаемой сборке — \
                вместе с этими паролями.
                """)
        }
    }
}
#endif
