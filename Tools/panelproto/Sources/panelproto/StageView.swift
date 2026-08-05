import SwiftUI

/// Стенд вокруг прототипа: подложка вместо CRM и переключатели состояний.
///
/// Подложка нужна не для красоты. Панель — плавающее окно поверх чужого
/// интерфейса, и материал поверхности читается только на пёстром фоне: на
/// пустой заливке любой макет выглядит одинаково хорошо.
struct StageView: View {

    @EnvironmentObject private var state: PrototypeState

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                backdrop
                PanelView()
                    .environmentObject(state)
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            controls
                .frame(width: 240)
        }
        .frame(minWidth: 760, minHeight: 560)
    }

    private var backdrop: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.16, green: 0.20, blue: 0.28),
                         Color(red: 0.30, green: 0.24, blue: 0.32)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 10) {
                Text("CRM · карточка лида")
                    .font(.system(size: 15, weight: .semibold))
                ForEach(0..<9, id: \.self) { row in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.16))
                        .frame(width: row % 3 == 0 ? 320 : 240, height: 12)
                }
            }
            .foregroundStyle(.white.opacity(0.75))
            .padding(36)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                group("Состояние") {
                    Picker("", selection: $state.phase) {
                        ForEach(PrototypeState.Phase.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                group("Вид панели") {
                    Picker("", selection: $state.size) {
                        ForEach(PrototypeState.Size.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                group("Макросов у сотрудника") {
                    Picker("", selection: $state.macroCount) {
                        Text("3").tag(3)
                        Text("6").tag(6)
                        Text("9").tag(9)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                group("Профиль и связь") {
                    Picker("", selection: $state.trouble) {
                        ForEach(PrototypeState.Trouble.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    Toggle("Отключён вручную", isOn: $state.isOfflineByChoice)
                    Text("Проверка: надпись о беде не двигает ни список, ни шестерёнку.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                group("Поверхность") {
                    Picker("", selection: $state.glass) {
                        ForEach(Tokens.Glass.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    HStack(spacing: 8) {
                        Slider(value: $state.surfaceTint, in: 0...0.9)
                        Text(String(format: "%.2f", state.surfaceTint))
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 34, alignment: .trailing)
                    }
                    Text("Подкраска: 0 — чистое стекло, 0.72 — как сейчас в приложении.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                group("Что двигало вёрстку раньше") {
                    Toggle("Сбой регистрации", isOn: $state.hasRegistrationFailure)
                    Toggle("Вторая линия", isOn: $state.hasSecondLine)
                    Toggle("Поле перевода", isOn: $state.isTransferVisible)
                    Text("Проверка: низ панели не должен сдвинуться ни от одного из них.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                group("Разговор") {
                    Toggle("На удержании", isOn: $state.isOnHold)
                    Toggle("Микрофон выключен", isOn: $state.isMuted)
                    Toggle("Имя звонящего известно", isOn: Binding(
                        get: { state.callerName != nil },
                        set: { state.callerName = $0 ? "Лид · Сочи" : nil }
                    ))
                }

                group("Оформление") {
                    Toggle("Тёмная тема", isOn: $state.isDark)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(16)
        }
    }

    private func group<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}
