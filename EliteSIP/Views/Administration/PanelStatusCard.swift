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

    var body: some View {
        if model.settings.panel.isActivated {
            SettingsSection("Связь с панелью", icon: "cloud") {
                HStack(spacing: Theme.Metrics.sectionSpacing) {
                    RouteNode(icon: "monitor", title: "Этот компьютер")
                    LucideIcon(name: "arrow-left-right", size: Theme.Icon.medium)
                        .compatForeground(
                            model.settings.panel.mode == .managed && !isOutOfTouch
                                ? Theme.Palette.registered
                                : Theme.Palette.failure
                        )
                    RouteNode(icon: "cloud", title: "Spark")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Metrics.tightSpacing)

                // Длинное название сокращается посередине, целиком — в
                // подсказке: начало и конец у названий предустановок разные
                // («Офис — менеджеры», «Офис — стажёры»), середина общая.
                SettingsRow("Предустановка") {
                    Text(verbatim: presetLine)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .compatForeground(Theme.Palette.textPrimary)
                        .compatHelp(verbatim: presetLine)
                }

                SettingsRow("Обновлена") {
                    Text(verbatim: appliedLine)
                        .compatForeground(Theme.Palette.textSecondary)
                }

                SettingsRow("Канал отвечал") {
                    Text(verbatim: contactLine)
                        .compatForeground(
                            isOutOfTouch ? Theme.Palette.textPrimary : Theme.Palette.textSecondary
                        )
                }

                // В оффлайн уводит правка управляемых настроек и «Сохранить» —
                // так сказано в предупреждении при входе в это окно. Обратно —
                // явной кнопкой «Вернуться в онлайн» ниже (решение 25 сентября
                // 2026); машина без ключа канала вернуться не может, ей — ключ.
                SettingsRow("Связь") {
                    Text(model.settings.panel.mode == .managed
                         ? "панель, онлайн"
                         : model.isPanelOffline ? "оффлайн, вручную" : "вручную, связь разорвана")
                        .compatForeground(
                            model.settings.panel.mode == .managed
                                ? Theme.Palette.textPrimary
                                : Theme.Palette.failure
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }

                // При двухчасовом такте это не удобство, а необходимость:
                // администратор, сменивший адрес АТС, не должен ждать два часа,
                // чтобы убедиться, что правка доехала. Тот же компонент, что и
                // у менеджера в «Техподдержке»: два одинаковых на вид действия
                // должны и отвечать одинаково.
                PanelSyncRow()

                if model.settings.panel.mode != .managed && !model.isPanelOffline {
                    SettingsNote(
                        "Предустановки не применяются — вернуть под панель можно только новым ключом.",
                        isAlarming: true
                    )
                }

                if isOutOfTouch {
                    SettingsNote("Канал молчит больше суток: правки из панели не доезжают, звонить это не мешает.")
                }
            }
        }
    }

    /// Имя предустановки и применённая ревизия.
    private var presetLine: String {
        let panel = model.settings.panel
        guard !panel.presetName.isEmpty else {
            return panel.presetID.isEmpty
                ? NSLocalizedString("Не применены", comment: "предустановки на машине нет")
                : panel.presetID
        }
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
