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
        VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
            HStack(spacing: Theme.Metrics.elementSpacing) {
                CompatSymbol(name: "exclamationmark.triangle.fill", size: Theme.Icon.large)
                    .compatForeground(Theme.Palette.failure)
                Text("Сбросить машину?")
                    .font(Font.subheadline.weight(.semibold))
            }

            Text("""
                Будут стёрты настройки, история звонков и журнал. Профили, пароли, макросы, \
                очереди и последовательность стука исчезнут; пароля администратора на машине \
                не останется, и закрытые настройки будут открыты всем.
                """)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Text("""
                Вернуть это нельзя ни «Отменой», ни из архива для поддержки: он собирается из \
                журнала, а журнал стирается вместе со всем остальным.
                """)
                .font(.footnote)
                .compatForeground(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Theme.Metrics.elementSpacing) {
                Spacer()

                Button("Отмена") { close() }
                    .compatCancelShortcut()

                Button(remaining > 0 ? "Сбросить (\(remaining))" : "Сбросить") {
                    onConfirm()
                    close()
                }
                .disabled(remaining > 0)
                .compatForeground(remaining > 0 ? Theme.Palette.textSecondary : Theme.Palette.failure)
            }
        }
        .padding(Theme.Metrics.contentPadding)
        .frame(width: Theme.Metrics.dialogWidth)
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
