import AdminAccess
import AppKit
import SwiftUI

/// Окно «Управление» — закрытые настройки целиком.
///
/// **Правки не применяются на ходу.** Всё, что меняется внутри, живёт в памяти
/// до нажатия «Сохранить»: на диск не уходит ничего, включая пароли.
/// Причина в том, что сохранение здесь означает не «записал громкость», а
/// «объявил машину настроенной вручную», и такое объявление должно быть
/// отдельным действием. Отсюда же «Отменить»: шанс передумать нужен ровно
/// потому, что цена ошибки — чужое рабочее место.
struct AdministrationWindowView: View {

    @EnvironmentObject private var model: AppModel

    /// Разделы окна.
    ///
    /// Свой набор кнопок, а не `TabView`, и это не вкусовщина. Системная
    /// панель вкладок при нехватке ширины схлопывает лишние в шеврон «»» —
    /// и на окне 700 pt с шестью разделами схлопывались почти все. Раздел,
    /// спрятанный за раскрывашкой, на чужом рабочем месте просто не находят:
    /// администратор ищет «Доступ», не видит его и решает, что пароль задать
    /// негде.
    private enum Section: String, CaseIterable, Identifiable {
        case account, audio, incoming, tones, history, diagnostics, access

        var id: String { rawValue }

        var title: String {
            switch self {
            case .account: "Аккаунт"
            case .audio: "Звук"
            case .incoming: "Входящие"
            case .tones: "Тоны"
            case .history: "История"
            case .diagnostics: "Диагностика"
            case .access: "Доступ"
            }
        }

        var symbol: String {
            switch self {
            case .account: "person.crop.circle"
            case .audio: "speaker.wave.2"
            case .incoming: "bell"
            case .tones: "square.grid.3x3"
            case .history: "clock"
            case .diagnostics: "stethoscope"
            case .access: "lock.shield.fill"
            }
        }
    }

    @State private var section: Section = .account
    @State private var isConfirmingSave = false

    var body: some View {
        VStack(spacing: 0) {
            sectionBar
            Divider()

            content
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 560)
    }

    /// Кнопки разделов сверху. Все шесть видны всегда.
    private var sectionBar: some View {
        HStack(spacing: 6) {
            ForEach(Section.allCases) { item in
                Button {
                    section = item
                } label: {
                    HStack(spacing: 5) {
                        // Иконка выбранного меняется на галочку, а не только
                        // стиль кнопки. На macOS ниже 12 акцентного стиля нет
                        // вовсе — `compatProminentButtonStyle` там честно
                        // говорит, что разницы не будет, — и на Catalina
                        // выбранный раздел иначе ничем бы не отличался. Тот же
                        // приём, что у кнопок рабочего места.
                        CompatSymbol(name: section == item ? "checkmark.circle" : item.symbol)
                        Text(item.title)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                }
                .compatProminentButtonStyle(section == item)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .account: AccountSettingsTab()
        case .audio: AudioSettingsTab()
        case .incoming: IncomingCallSettingsTab()
        case .tones: DTMFSettingsTab()
        case .history: CallHistorySettingsTab()
        case .diagnostics: DiagnosticsTab()
        case .access: AdministrationTab()
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            CompatSymbol(
                name: model.hasUnsavedAdministrationChanges
                    ? "exclamationmark.triangle" : "lock.shield.fill"
            )
            .compatForeground(model.hasUnsavedAdministrationChanges ? .orange : .secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(
                    model.hasUnsavedAdministrationChanges
                        ? "Есть несохранённые изменения" : "Изменений нет"
                )
                Text(
                    model.hasUnsavedAdministrationChanges
                        ? "Пока не нажато «Сохранить», на диск не записано ничего."
                        : "Настройки этой машины: \(model.adminAccess.management.title.lowercased())."
                )
                .font(.footnote)
                .compatForeground(.secondary)
            }

            Spacer()

            Button("Отменить") {
                model.cancelAdministration()
                closeWindow()
            }
            .compatHelp("Вернуть настройки к тому, что было при входе")

            Button("Сохранить") { isConfirmingSave = true }
                .compatProminentButtonStyle()
                .disabled(!model.hasUnsavedAdministrationChanges)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        // Предупреждение дублируется на сохранении — того же содержания, что и
        // на входе. Намеренно: между входом и нажатием проходит вся настройка
        // рабочего места, и к этому моменту прочитанное на входе уже забыто.
        .alert(isPresented: $isConfirmingSave) {
            Alert(
                title: Text("Сохранить настройки?"),
                message: Text("""
                    Настройки этой машины станут локальными: их задаёт администратор, \
                    а не файл конфигурации. Сохранение будет записано в журнал.
                    """),
                primaryButton: .default(Text("Сохранить")) {
                    model.commitAdministration()
                    closeWindow()
                },
                secondaryButton: .cancel(Text("Не сохранять"))
            )
        }
    }

    /// Закрытие через цепочку ответчиков — тем же кодом, что открывал окно.
    /// Второго места, умеющего его закрывать, в приложении нет.
    private func closeWindow() {
        NSApp.sendAction(#selector(AppDelegate.closeAdministrationWindow(_:)), to: nil, from: nil)
    }
}
