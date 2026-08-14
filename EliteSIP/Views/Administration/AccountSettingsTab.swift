import SIPCore
import SwiftUI

/// Раздел «Аккаунт»: кто мы для АТС.
///
/// В этапе 5 раздел ужался до двух блоков, и это не сокращение, а исправление.
/// Поля учётной записи, сети и сертификата стояли здесь отдельными секциями и
/// правили активный профиль, выглядя при этом настройками машины. Теперь они
/// живут внутри карточки того профиля, которому принадлежат, — см.
/// `ProfileCard`.
///
/// Снаружи осталась только регистрация: она про машину, а не про профиль, и
/// применяется немедленно, в отличие от всего остального в этом окне.
struct AccountSettingsTab: View {

    @EnvironmentObject private var model: AppModel

    /// Какая карточка раскрыта. Одна за раз: две открытые формы на экране
    /// возвращают ровно ту путаницу, ради которой карточки и заводились.
    @State private var expandedID: UUID?

    /// Предустановка, из которой заводят следующий профиль. `nil` — вручную.
    @State private var newProfilePresetID: UUID?

    /// Номер для него: в предустановке номера нет и быть не может, он у каждого
    /// рабочего места свой.
    @State private var newProfileNumber = ""

    /// Пароль от него. Заводить место без пароля можно — регистрироваться ему
    /// будет нечем, и приложение об этом скажет само.
    @State private var newProfilePassword = ""

    /// Заводит профиль: из предустановки, если она выбрана, иначе пустой.
    ///
    /// Пустые поля — не ошибка, а «заполню в карточке»: она и так раскрывается
    /// следом. Поэтому кнопка не запрещена, а незаполненное просто не
    /// применяется.
    private func addProfile() {
        defer {
            newProfileNumber = ""
            newProfilePassword = ""
        }

        guard
            let id = newProfilePresetID,
            let preset = model.settings.presets.first(where: { $0.id == id })
        else {
            model.addProfile()
            model.settings.profiles.active.account.username = trimmedNumber
            model.settings.profiles.active.password = newProfilePassword
            return
        }
        model.applyPreset(
            preset,
            number: trimmedNumber,
            password: newProfilePassword,
            to: nil
        )
    }

    private var trimmedNumber: String {
        newProfileNumber.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        SettingsSection("Профили") {
            if model.profiles.isEmpty {
                SettingsNote("Профилей нет. Пока не заведён хотя бы один, звонить не с чего.")
            } else {
                // В один столбец всегда, в отличие от макросов и очередей:
                // раскрытая карточка — это форма, а формы рядом друг с другом
                // не ставят. Порог перестроения к этому списку не применяется.
                VStack(alignment: .leading, spacing: Theme.Metrics.elementSpacing) {
                    ForEach(model.profiles) { profile in
                        ProfileCard(profileID: profile.id, expandedID: $expandedID)
                    }
                }
            }

            // Заведение профиля — одной строкой.
            //
            // Номер, пароль и предустановка стояли по разным строкам, и это
            // читалось как три отдельные настройки, хотя они — один ввод для
            // одного действия. Теперь строка ровно одна и заканчивается той
            // кнопкой, ради которой её заполняли. «Вручную» остаётся первым
            // пунктом списка: место, для которого шаблона нет, не должно
            // заводиться труднее, чем до предустановок.
            SettingsButtonsRow {
                TextField("добавочный", text: $newProfileNumber)
                    .frame(maxWidth: 110)

                SecureField("пароль", text: $newProfilePassword)
                    .frame(maxWidth: 130)

                if !model.settings.presets.isEmpty {
                    Picker("", selection: $newProfilePresetID) {
                        Text("Вручную").tag(UUID?.none)
                        ForEach(model.settings.presets) { preset in
                            Text(preset.name).tag(UUID?.some(preset.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 160)
                }

                Button("Добавить профиль") {
                    addProfile()
                    // Новый профиль сразу раскрыт: его завели затем, чтобы
                    // заполнить, и требовать второго нажатия незачем.
                    expandedID = model.activeProfileID
                }
                .disabled(!model.canSwitchProfile)

                if !model.canSwitchProfile {
                    Text("смена профиля недоступна в разговоре")
                        .font(.footnote)
                        .compatForeground(Theme.Palette.textSecondary)
                }
            }

            SettingsNote("""
                Зарегистрирован всегда ровно один профиль — отмеченный «рабочий». У каждого свой \
                пароль; удаление профиля стирает и его. Настройки открываются нажатием на карточку \
                и правятся у любого профиля, а не только у рабочего.
                """)
        }

        SettingsSection("Регистрация") {
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

            // Единственное место раздела, которое действует немедленно, и
            // сказать об этом надо: остальное окно копит правки до «Сохранить»,
            // и «Переподключить» применит домен с диска, а не тот, что вписан
            // строкой выше.
            SettingsNote("""
                Действует сразу, в обход «Сохранить»: переподключение берёт настройки с диска. \
                Правки профиля дойдут до АТС после сохранения.
                """)
        }

        // «Лаборатория» из раздела убрана: стендовые пиры заводятся профилем, а
        // отдельная плашка с их паролями открытым текстом висела над рабочим
        // разделом. Пресеты (`AppSettings.LabPreset`, `AppModel.applyLabPreset`)
        // остались — вызывать их теперь неоткуда, кроме отладчика, и это ровно
        // то место, где они нужны.
    }
}
