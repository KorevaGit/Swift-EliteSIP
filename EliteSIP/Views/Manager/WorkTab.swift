import SIPCore
import SwiftUI

/// Раздел «Работа»: откуда менеджер работает сегодня — из офиса или из дома.
///
/// **Почему это менеджерская настройка, а не административная.** Пометка
/// рабочего места жила в «Управлении» с M7b и была убрана в этапе 5 по доводу
/// «рабочее место у машины одно и не меняется». Довод верен для машины и неверен
/// для человека: тот же менеджер с тем же номером сидит то в офисе, то дома, и
/// знает об этом только он. Администратора в этот момент рядом нет, а
/// административный пароль оператору не дают — и не должны: за дверью аккаунты и
/// защита от автокликеров, а не «я сегодня из дома».
///
/// **Что происходит по переключению.** Не пометка, а переезд: вместе с местом
/// меняется адрес АТС по паре из настроек (`siteAddresses`), регистрация
/// снимается и поднимается заново, а стук по портам уходит сам на первой же
/// регистрации по новому адресу. Разбор — `AppModel.setProfileSite`.
///
/// **Чего здесь нет.** Варианта «определять самому»: третья кнопка означала бы
/// «не выбирать», а выбирает как раз человек. Догадка по адресу осталась
/// умолчанием модели и показывается выбранной — `AppModel.workplaceSite`.
///
/// **Закрепление из Spark.** Администратор может закрепить формат за местом —
/// тогда переключатель гаснет, а при закреплённом офисе гаснет и «Исправить
/// сеть». Снять закрепление на месте можно административным паролем, ценой
/// оффлайна — разбор в `AppModel+WorkFormat`.
struct WorkTab: View {

    @EnvironmentObject private var model: AppModel

    /// Окно административного пароля — своё, не общее с «Управлением»: после
    /// входа оно не открывает окно, а оставляет человека здесь.
    @State private var isAskingForPassword = false

    /// Состояние запуска с системой — у системы, а не в настройках: оператор
    /// мог выключить его в «Объектах входа» руками.
    @State private var startsWithSystem = LoginItem.isEnabled

    var body: some View {
        SettingsSection("Рабочее место", icon: "map-pin") {
            // Две плитки вместо сегментов и схема маршрута вместо абзаца —
            // «меньше текста, больше визуала» Windows 1.0.4.
            HStack(spacing: Theme.Metrics.sectionSpacing) {
                siteTile(.office, title: "Офис", icon: "building-2")
                siteTile(.remote, title: "Из дома", icon: "house")
            }
            // Посреди разговора переключать нельзя — тот же запрет, что у смены
            // профиля и у отключения (M6b). Плитки гаснут, а не молча
            // отказывают: отказ после нажатия оператор читает как поломку.
            .disabled(!model.canSwitchProfile || model.isWorkplaceSwitchLocked)

            WorkplaceRoute(isRemote: model.workplaceSite == .remote)

            SettingsRow("Адрес АТС") {
                HStack(spacing: Theme.Metrics.tightSpacing) {
                    LucideIcon(name: "network", size: Theme.Icon.medium)
                    Text(verbatim: model.settings.account.domain)
                        .compatMonospacedDigit()
                }
                .compatForeground(Theme.Palette.textSecondary)
            }

            if model.isWorkplaceSwitchLocked {
                SettingsNote("Формат работы закреплён администратором.")
                SettingsButtonsRow {
                    Button("Снять закрепление…") { isAskingForPassword = true }
                }
            } else if model.lockedWorkplaceSite != nil {
                // Закрепление снято паролем, но машина ещё под панелью: цену
                // переключения надо видеть до нажатия, а не после.
                SettingsNote(
                    "Закрепление снято. Переключение переведёт машину в оффлайн.",
                    isAlarming: true
                )
            }

            if !model.canSwitchProfile {
                SettingsNote("Идёт разговор — переключить сейчас нельзя.", isAlarming: true)
            }
        }
        .sheet(isPresented: $isAskingForPassword) {
            AdminUnlockView(isPresented: $isAskingForPassword, purpose: .workplace)
                .environmentObject(model)
        }

        // Группа Windows 1.0.4 под значком питания: запуск с системой, панель
        // поверх окон и восстановление подключения.
        SettingsSection("Запуск и подключение", icon: "power") {
            SettingsToggleRow("Запускать вместе с macOS", icon: "power", isOn: Binding(
                get: { startsWithSystem },
                set: { enabled in
                    if let problem = LoginItem.setEnabled(enabled) {
                        // не переводится: строка журнала
                        model.append(level: .warning, message: "запуск с системой: \(problem)")
                    }
                    startsWithSystem = LoginItem.isEnabled
                }
            ))

            SettingsToggleRow("Поверх всех окон", icon: "monitor", isOn: Binding(
                get: { model.settings.panelAlwaysOnTop },
                set: { model.settings.panelAlwaysOnTop = $0 }
            ))

            // В колонке контролов, вровень с переключателями выше — как в
            // группе Windows.
            SettingsIndented {
                HStack(spacing: Theme.Metrics.elementSpacing) {
                    LucideIcon(name: "wrench", size: Theme.Icon.large)
                        .compatForeground(Theme.Palette.textSecondary)
                    Text("Восстановить подключение")
                    Spacer()
                    Button(action: { Task { await model.repairNetwork() } }) {
                        HStack(spacing: Theme.Metrics.tightSpacing) {
                            LucideIcon(name: "refresh-cw", size: Theme.Icon.medium)
                            Text("Восстановить")
                        }
                    }
                    .disabled(model.isNetworkRepairLocked)
                    .compatHelp("Открывает дорогу до АТС снаружи — когда из дома перестало подключаться: у домашнего интернета сменился адрес.")
                }
            }


            if model.isNetworkRepairLocked {
                SettingsNote("Место закреплено за офисом — из офиса АТС достижима напрямую.")
            }

            if let status = model.networkRepairStatus {
                SettingsNote(verbatim: status)
            }
        }
    }

    /// Плитка площадки: значок, подпись и выделение выбранной.
    private func siteTile(_ site: SIPProfileSite, title: LocalizedStringKey, icon: String) -> some View {
        let isSelected = model.workplaceSite == site
        return Button {
            Task { await model.chooseWorkplaceSite(site) }
        } label: {
            VStack(spacing: Theme.Metrics.elementSpacing) {
                LucideIcon(name: icon, size: 22)
                Text(title).font(.callout.weight(isSelected ? .semibold : .regular))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .compatForeground(isSelected ? Color.accentColor : Theme.Palette.textSecondary)
        .graphiteSurface(isSelected ? .selected : .control)
        .compatOverlay {
            RoundedRectangle(cornerRadius: Graphite.cornerRadius)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
        }
        .hoverHighlight(cornerRadius: Graphite.cornerRadius, isEnabled: !isSelected)
    }
}

/// Маршрут до АТС: этот компьютер → офисная сеть или интернет со шлюзом → АТС.
///
/// Общий для «Работы» и «Адресов АТС» в «Управлении», как схема в обоих окнах
/// Windows 1.0.4: средний узел показывает площадку, выбранную сейчас.
struct WorkplaceRoute: View {

    let isRemote: Bool

    var body: some View {
        HStack(spacing: Theme.Metrics.sectionSpacing) {
            RouteNode(icon: "monitor", title: "Этот компьютер")
            arrow
            RouteNode(icon: isRemote ? "cloud" : "router", title: isRemote ? "Интернет" : "Офисная сеть")
            arrow
            RouteNode(icon: "server", title: "АТС")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Metrics.tightSpacing)
        .compatAccessibilityLabel(isRemote ? "Маршрут: компьютер, интернет, АТС" : "Маршрут: компьютер, офисная сеть, АТС")
    }

    private var arrow: some View {
        LucideIcon(name: "arrow-right", size: Theme.Icon.medium)
            .compatForeground(Theme.Palette.textTertiary)
    }

}

/// Узел схемы: значок и подпись под ним — как в схемах Windows 1.0.4.
struct RouteNode: View {

    let icon: String
    let title: LocalizedStringKey

    var body: some View {
        VStack(spacing: Theme.Metrics.tightSpacing) {
            LucideIcon(name: icon, size: 20)
            Text(title)
                .font(.caption)
                .lineLimit(1)
        }
        .compatForeground(Theme.Palette.textSecondary)
        .frame(minWidth: 72)
    }
}
