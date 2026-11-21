import SwiftUI

/// Подтверждение полного сброса: десять секунд, прежде чем кнопка оживёт.
///
/// Своим листом, а не `Alert`: системный вопрос не умеет держать кнопку
/// погашенной и считать вслух, а весь смысл здесь в паузе.
///
/// **Таймер только у сброса.** Остальные разрушающие действия раздела —
/// чистка журнала, чистка истории, замена файла настроек — обходятся обычным
/// вопросом. Если ждать заставляет каждая кнопка, ожидание перестают читать и
/// пережидают, глядя в сторону; редкое — замечают.
struct ResetConfirmation: View {

    @Binding var isPresented: Bool
    let onConfirm: () -> Void

    /// Столько секунд кнопка погашена.
    private static let delay = 10

    @State private var remaining = ResetConfirmation.delay

    var body: some View {
        // Носитель нулевой высоты: лист вешается на него, а не на строку
        // раздела, — иначе он делил бы место с двумя другими подтверждениями,
        // и SwiftUI показывал бы только последнее.
        Color.clear
            .frame(height: 0)
            .sheet(isPresented: $isPresented) { sheet }
    }

    private var sheet: some View {
        GraphiteDialog(
            icon: "triangle-alert",
            title: Text("Сбросить машину?"),
            message: Text("""
                Будут стёрты настройки, история звонков и журнал. Профили, пароли, клавиши, \
                очереди и последовательность стука исчезнут; пароля администратора на машине \
                не останется, и закрытые настройки будут открыты всем.
                """),
            footnote: Text("""
                Вернуть это нельзя ни «Отменой», ни из архива для поддержки: он собирается из \
                журнала, а журнал стирается вместе со всем остальным.
                """),
            actions: [
                .init(Text("Отмена"), role: .cancel) { close() },
                .init(
                    Text(remaining > 0 ? "Сбросить (\(remaining))" : "Сбросить"),
                    role: .destructive,
                    isDisabled: remaining > 0
                ) {
                    onConfirm()
                    close()
                },
            ]
        )
        .onAppear { countDown() }
    }

    /// Отсчёт своим таймером, а не `Timer.publish`: тот тянет Combine и
    /// `onReceive`, а нужен один тик в секунду, который умеет остановиться
    /// вместе с закрытым листом.
    private func countDown() {
        remaining = Self.delay
        tick()
    }

    private func tick() {
        guard isPresented, remaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard isPresented else { return }
            remaining -= 1
            tick()
        }
    }

    private func close() {
        isPresented = false
        remaining = Self.delay
    }
}
