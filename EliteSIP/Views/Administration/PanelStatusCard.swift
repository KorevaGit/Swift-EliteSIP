import SwiftUI

/// Что панель делает с этой машиной — над карточками профилей.
///
/// Стоит первым в «Аккаунте», и это решение: если машиной управляют из панели,
/// это главное, что администратор должен узнать про неё, открыв окно. Раньше
/// блок жил в отдельном разделе «Предустановки» — вместе с локальными снимками
/// настроек, которых больше нет: снимок был конторскими настройками в локальном
/// артефакте, применяемым мимо панели, то есть обходом всей линии в два
/// нажатия.
///
/// Машина, поднятая не ключом, этого блока не видит вовсе: объяснять
/// отсутствующее незачем.
struct PanelStatusCard: View {

    @EnvironmentObject private var model: AppModel

    @State private var isConfirmingManaged = false

    var body: some View {
        if model.settings.panel.isActivated {
            SettingsSection("Панель") {
                SettingsRow("Предустановка") {
                    Text(verbatim: presetLine)
                        .compatForeground(Theme.Palette.textPrimary)
                }

                SettingsRow("Обновлена") {
                    Text(verbatim: appliedLine)
                        .compatForeground(Theme.Palette.textSecondary)
                }

                SettingsRow("Связь с каналом") {
                    Text(verbatim: contactLine)
                        .compatForeground(
                            isOutOfTouch ? Theme.Palette.textPrimary : Theme.Palette.textSecondary
                        )
                }

                SettingsToggleRow("Слушать панель", isOn: Binding(
                    get: { model.settings.panel.mode == .managed },
                    set: { managed in
                        if managed {
                            // Возврат под предустановку заменит локальные правки —
                            // спрашиваем до, а не показываем сожаление после.
                            isConfirmingManaged = true
                        } else {
                            model.settings.panel.mode = .manual
                            // Признак «этим управляет сервер» снимается сразу:
                            // иначе управляемые ползунки остались бы запертыми
                            // на машине, которая панель уже не слушает.
                            model.settings.incomingCall.isServerManaged = false
                        }
                    }
                ))

                SettingsButtonsRow {
                    // При двухчасовом такте это не удобство, а необходимость:
                    // администратор, сменивший адрес АТС, не должен ждать два
                    // часа, чтобы убедиться, что правка доехала.
                    Button("Проверить сейчас") {
                        NSApp.sendAction(#selector(AppDelegate.checkPresetsNow(_:)), to: nil, from: nil)
                    }
                }

                if model.settings.panel.mode == .managed {
                    SettingsNote("""
                        Машина применяет файл предустановок с сервера. Управляемые поля \
                        показываются, но не правятся здесь: локально остаются номер, метка \
                        профиля и пароль SIP. Обновление обязательное — отложить его нельзя, \
                        оно ждёт только конца разговора.
                        """)
                } else {
                    SettingsNote("""
                        Машина живёт своим умом: файл предустановок не применяется ни в чём. \
                        Штатный способ починить разъехавшееся рабочее место — вернуть её \
                        под предустановку.
                        """)
                }

                if isOutOfTouch {
                    SettingsNote("""
                        Канал не отвечал больше суток. Пока связи нет, правки из панели \
                        не доезжают — включая смену адреса АТС. Звонить это не мешает: \
                        машина работает тем, что применила раньше.
                        """)
                }
            }
            .alert(isPresented: $isConfirmingManaged) {
                Alert(
                    title: Text("Вернуть под предустановку?"),
                    message: Text("""
                        Локальные правки управляемых полей будут заменены тем, что \
                        лежит на сервере. Номер, метка профиля и пароль SIP останутся.
                        """),
                    primaryButton: .default(Text("Вернуть")) {
                        model.settings.panel.mode = .managed
                        model.settings.incomingCall.isServerManaged = true
                    },
                    secondaryButton: .cancel(Text("Отмена"))
                )
            }
        }
    }

    /// Имя предустановки и применённая ревизия.
    private var presetLine: String {
        let panel = model.settings.panel
        guard !panel.presetName.isEmpty else { return panel.presetID }
        guard panel.appliedRevision > 0 else { return panel.presetName }
        return String(
            format: NSLocalizedString("%1$@, ревизия %2$lld", comment: "предустановка и ревизия в разделе «Панель»"),
            panel.presetName,
            Int64(panel.appliedRevision)
        )
    }

    private var appliedLine: String {
        guard let applied = model.settings.panel.appliedAt else {
            return NSLocalizedString("ещё ни разу", comment: "ревизия предустановки не применялась")
        }
        return Self.moment.string(from: applied)
    }

    private var contactLine: String {
        guard let contact = model.settings.panel.lastContactAt else {
            return NSLocalizedString("канал ещё не отвечал", comment: "связи с каналом не было")
        }
        return Self.moment.string(from: contact)
    }

    /// Сутки без связи — уже не «сейчас проверим».
    ///
    /// Порог свой, не тот, по которому панель подсвечивает молчащие машины
    /// (пять суток): там ждут отметки от машины, здесь машина ждёт ответа
    /// канала, и час против часа это разные ожидания.
    private var isOutOfTouch: Bool {
        guard model.settings.panel.mode == .managed else { return false }
        guard let contact = model.settings.panel.lastContactAt else { return false }
        return Date().timeIntervalSince(contact) > 24 * 60 * 60
    }

    private static let moment: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}
