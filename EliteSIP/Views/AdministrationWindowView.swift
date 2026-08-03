import AdminAccess
import AppKit
import SwiftUI

/// Окно «Управление» — закрытые настройки целиком.
///
/// **Правки не применяются на ходу.** Всё, что меняется внутри, живёт в памяти
/// до нажатия «Сохранить»: на диск не уходит ничего, в связку ключей — тоже.
/// Причина в том, что сохранение здесь означает не «записал громкость», а
/// «объявил машину настроенной вручную», и такое объявление должно быть
/// отдельным действием. Отсюда же «Отменить»: шанс передумать нужен ровно
/// потому, что цена ошибки — чужое рабочее место.
struct AdministrationWindowView: View {

    @EnvironmentObject private var model: AppModel

    @State private var isConfirmingSave = false

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                AccountSettingsTab()
                    .tabItem { CompatLabel(title: "Аккаунт", symbol: "person.crop.circle") }

                AudioSettingsTab()
                    .tabItem { CompatLabel(title: "Звук", symbol: "speaker.wave.2") }

                IncomingCallSettingsTab()
                    .tabItem { CompatLabel(title: "Входящие", symbol: "bell") }

                DTMFSettingsTab()
                    .tabItem { CompatLabel(title: "Тоны", symbol: "square.grid.3x3") }

                DiagnosticsTab()
                    .tabItem { CompatLabel(title: "Диагностика", symbol: "stethoscope") }

                AdministrationTab()
                    .tabItem { CompatLabel(title: "Доступ", symbol: "lock.shield.fill") }
            }
            .padding(20)

            Divider()
            footer
        }
        .frame(minWidth: 700, minHeight: 540)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            CompatSymbol(name: model.hasUnsavedAdministrationChanges ? "exclamationmark.triangle" : "lock.shield.fill")
                .compatForeground(model.hasUnsavedAdministrationChanges ? .orange : .secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.hasUnsavedAdministrationChanges ? "Есть несохранённые изменения" : "Изменений нет")
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
