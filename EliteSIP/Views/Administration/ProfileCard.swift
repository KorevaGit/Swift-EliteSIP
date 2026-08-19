import SIPCore
import SwiftUI

/// Карточка профиля: свёрнутая — строка списка, раскрытая — форма этого профиля.
///
/// **Почему поля живут внутри карточки.** До этапа 5 они лежали отдельными
/// секциями ниже списка и правили `settings.account`, то есть **активный**
/// профиль. Выглядело это как общие настройки машины, а было настройками одного
/// из профилей — и заполнить второй можно было, только переведя на него
/// оператора. Теперь карточка раскрывается на месте: две коробки — два профиля,
/// перепутать нечего, и «какой правлю» перестало значить «какой зарегистрирован».
///
/// **Заголовок раскрывает, а не переключает.** Переключение активного — редкое
/// и с последствиями (перерегистрация), правка — частое; главным действием
/// карточки стало то, ради чего её открывают. Сделать профиль рабочим можно
/// явной кнопкой внутри.
struct ProfileCard: View {

    @EnvironmentObject private var model: AppModel

    let profileID: UUID
    @Binding var expandedID: UUID?

    /// Правится ли название прямо сейчас. Своё у каждой карточки: два поля
    /// одновременно не нужны, а гасить чужое пришлось бы отдельным состоянием
    /// на весь список.
    @State private var isEditingLabel = false

    /// Спрошено ли про удаление. Своё у каждой карточки, как и правка названия.
    @State private var isConfirmingRemoval = false
    @State private var isPasswordRevealed = false

    private var isActive: Bool { profileID == model.activeProfileID }
    private var isExpanded: Bool { expandedID == profileID }

    /// Профиль по идентификатору, а не переданный значением: карточка живёт
    /// дольше одной перерисовки, и значение в ней успело бы устареть.
    private var profile: SIPProfile {
        model.settings.profiles[profileID] ?? model.settings.profiles.active
    }

    private func field<Value>(
        _ keyPath: WritableKeyPath<SIPProfile, Value>
    ) -> Binding<Value> {
        Binding(
            get: { profile[keyPath: keyPath] },
            set: { updated in
                var copy = profile
                copy[keyPath: keyPath] = updated
                model.settings.profiles[profileID] = copy
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.elementSpacing) {
            header

            if isExpanded {
                SettingsDivider()
                form
            }
        }
        .padding(Theme.Metrics.sectionSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedControlSurface(cornerRadius: Theme.Radius.control)
        // Вопрос задаётся здесь, хотя записи удалит только «Сохранить».
        //
        // Решает человек в момент нажатия на корзину, и число он должен видеть
        // тогда же: узнать о потере ста записей после того, как она случилась,
        // — это не предупреждение, а отчёт. Само удаление откладывается до
        // «Сохранить» вместе со всеми правками окна, но «Отменить» историю уже
        // не вернёт, и об этом сказано прямо.
        .alert(isPresented: $isConfirmingRemoval) {
            Alert(
                title: Text("Удалить профиль «\(profile.title)»?"),
                message: Text(removalWarning),
                primaryButton: .destructive(Text("Удалить")) {
                    Task { await model.removeProfile(profileID) }
                },
                secondaryButton: .cancel(Text("Отмена"))
            )
        }
    }

    // MARK: - Шапка

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Metrics.elementSpacing) {
            Button {
                expandedID = isExpanded ? nil : profileID
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Metrics.elementSpacing) {
                    ChevronDown()
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .frame(width: Theme.Icon.medium)

                    if isEditingLabel {
                        // `labelsHidden` обязателен: без него первый строковый
                        // аргумент `TextField` становится подписью, и
                        // placeholder уезжает от своего же поля через всю
                        // карточку. Это уже было один раз и выглядело как два
                        // разных поля.
                        TextField("Без названия", text: Binding(
                            get: { profile.label },
                            set: { model.renameProfile(profileID, to: $0) }
                        ))
                        .labelsHidden()
                        .frame(maxWidth: 200)
                    } else {
                        Text(profile.title.isEmpty
                            ? NSLocalizedString("Новый профиль", comment: "профиль без подписи")
                            : profile.title)
                            .font(Font.callout.weight(.semibold))
                            .lineLimit(1)
                    }

                    Text(subtitle)
                        .font(.footnote)
                        .compatForeground(Theme.Palette.textSecondary)
                        .lineLimit(1)

                    if isActive {
                        ActiveBadge()
                    }

                    Spacer(minLength: 0)
                }
                // Нажатие ловит вся строка, а не только буквы со значком: без
                // этого по карточке промахиваются ровно так же, как по пункту
                // сайдбара.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(isEditingLabel ? "Готово" : "Изменить подпись") {
                isEditingLabel.toggle()
            }

            Button {
                isConfirmingRemoval = true
            } label: {
                CompatSymbol(name: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(isActive && !model.canSwitchProfile)
            .compatHelp("Удалить профиль вместе с его паролем и историей звонков")
        }
    }

    /// Кому и куда: номер отдельно от метки, иначе два профиля на одной АТС
    /// различимы только по слову, которое кто-то однажды вписал.
    private var subtitle: String {
        let account = profile.account
        let address = account.domain.isEmpty
            ? NSLocalizedString("домен не задан", comment: "профиль без домена")
            : account.domain
        let number = account.username.isEmpty
            ? NSLocalizedString("номер не задан", comment: "профиль без номера")
            : account.username
        return "\(number) · \(address) · \(account.transport.protocolName)"
    }

    // MARK: - Форма профиля

    @ViewBuilder
    private var form: some View {
        SettingsRow("Внутренний номер") {
            TextField("", text: field(\.account.username))
                .labelsHidden()
        }
        SettingsRow("Отображаемое имя") {
            TextField("", text: field(\.account.displayName))
                .labelsHidden()
        }
        SettingsRow("Домен АТС") {
            TextField("", text: field(\.account.domain))
                .labelsHidden()
        }
        SettingsRow("Логин для входа") {
            TextField("если отличается от номера", text: Binding(
                get: { profile.account.authUsername ?? "" },
                set: { value in
                    var copy = profile
                    copy.account.authUsername = value.isEmpty ? nil : value
                    model.settings.profiles[profileID] = copy
                }
            ))
            .labelsHidden()
        }

        SettingsRow("Пароль") {
            // Обычное поле профиля, без кнопок «Принять» и «Удалить».
            // Придержку до «Сохранить» делает само окно «Управление»: на диск
            // не уходит ничего, пока оно открыто, а «Отменить» возвращает
            // снимок вместе с паролем.
            HStack(spacing: Theme.Metrics.tightSpacing) {
                if isPasswordRevealed {
                    TextField("", text: field(\.password))
                        .labelsHidden()
                } else {
                    SecureField("", text: field(\.password))
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

        SettingsRow("Транспорт") {
            Picker("", selection: field(\.account.transport)) {
                Text("TLS").tag(SIPTransport.tls)
                Text("UDP").tag(SIPTransport.udp)
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)
        }

        SettingsRow("Порт") {
            TextField("по умолчанию", text: Binding(
                get: { profile.account.serverPort.map(String.init) ?? "" },
                set: { value in
                    var copy = profile
                    copy.account.serverPort = UInt16(value)
                    model.settings.profiles[profileID] = copy
                }
            ))
            .labelsHidden()
            .frame(width: 90)
        }

        SettingsRow("Регистрация") {
            Stepper(
                "каждые \(profile.account.registrationExpires) с",
                value: field(\.account.registrationExpires),
                in: 60...3600,
                step: 60
            )
        }

        SettingsToggleRow("Доверять любому сертификату TLS", isOn: field(\.acceptsAnyTLSCertificate))

        if profile.acceptsAnyTLSCertificate {
            SettingsNote(
                """
                Проверка сертификата отключена: перехватчик сможет прочитать пароль и разговор. \
                Только для самоподписанного сертификата лаборатории.
                """,
                isAlarming: true
            )
        }

        if profile.password.isEmpty {
            SettingsNote("Пароля нет — зарегистрироваться этим профилем нечем.", isAlarming: true)
        }

        SettingsDivider()

        SettingsButtonsRow {
            if isActive {
                Text("Рабочий профиль этой машины")
                    .font(.footnote)
                    .compatForeground(Theme.Palette.textSecondary)
            } else {
                // Отдельным действием, а не нажатием на карточку: смена
                // активного снимает регистрацию и закрывает диалоги, и цена
                // случайного попадания — положенная за оператора трубка.
                Button("Сделать рабочим") {
                    Task { await model.selectProfile(profileID) }
                }
                .disabled(!model.canSwitchProfile)

                if !model.canSwitchProfile {
                    Text("недоступно в разговоре")
                        .font(.footnote)
                        .compatForeground(Theme.Palette.textSecondary)
                }
            }
        }
    }

    // MARK: - Удаление

    /// Что именно уйдёт вместе с профилем.
    ///
    /// История считается на месте, а не берётся из окна истории: то показывает
    /// активный профиль, а удаляют обычно не его.
    private var removalWarning: String {
        let records = model.historyCount(ofProfile: profileID)
        guard records > 0 else {
            return NSLocalizedString(
                "Вместе с профилем будет удалён его пароль. Истории звонков у этого профиля нет.",
                comment: "предупреждение перед удалением профиля"
            )
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("""
                Вместе с профилем будут удалены его пароль и %lld записей \
                истории звонков. Вернуть их «Отменой» будет нельзя.
                """, comment: "предупреждение перед удалением профиля"),
            records
        )
    }

}

/// Отметка рабочего профиля.
///
/// Словом, а не одной галочкой: галочка отвечала на «выбран ли он в списке», а
/// вопрос у смотрящего другой — «с какого профиля идут звонки». Пустого места
/// под неё не резервируется: карточки теперь разной высоты и без того.
private struct ActiveBadge: View {

    var body: some View {
        HStack(spacing: Theme.Metrics.hairSpacing) {
            CompatSymbol(name: "checkmark.circle", size: Theme.Icon.small)
            Text("рабочий")
        }
        .font(.footnote)
        .compatForeground(Theme.Palette.registered)
    }
}
