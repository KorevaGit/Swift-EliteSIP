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

            SettingsButtonsRow {
                Button("Добавить профиль") {
                    model.addProfile()
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
