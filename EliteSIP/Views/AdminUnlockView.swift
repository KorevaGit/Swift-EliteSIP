import AdminAccess
import AppKit
import SwiftUI

/// Вход в административный режим.
///
/// Две дороги в одном окне, потому что вторая нужна ровно тогда, когда первая
/// не сработала, — и отправлять человека искать её в меню в этот момент значит
/// не найти её вовсе.
struct AdminUnlockView: View {

    @EnvironmentObject private var model: AppModel
    @Binding var isPresented: Bool

    private enum Step {
        /// Обычный вход.
        case password
        /// Пароль принят: предупреждение до того, как окно откроется.
        case warning
    }

    @State private var step: Step = .password
    @State private var passwordDraft = ""
    @State private var newPasswordDraft = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
            switch step {
            case .password: passwordStep
            case .warning: warningStep
            }

            if let problem {
                CompatLabel(verbatim: problem, symbol: "exclamationmark.triangle")
                    .font(.footnote)
                    .compatForeground(Theme.Palette.failure)
            }
        }
        .padding(Theme.Metrics.contentPadding)
        .frame(width: Theme.Metrics.dialogWidth)
        // Пароль не задан — спрашивать нечего, но предупреждение показать надо:
        // открытые настройки не делают правку менее последствийной.
        .onAppear {
            guard !model.isAdministrationProtected else { return }
            try? model.unlockAdministration(password: "")
            step = .warning
        }
    }

    // MARK: - Пароль

    private var passwordStep: some View {
        Group {
            Text("Управление настройками")
                .font(.headline)
            Text("Аккаунты, клавиши, защита от автокликеров и диагностика.")
                .font(.footnote)
                .compatForeground(.secondary)

            // `onSubmit` появился в macOS 12, поэтому ввод завершает не поле, а
            // Enter на кнопке «Войти» — см. `compatKeyboardShortcut` ниже.
            SecureField("Пароль администратора", text: $passwordDraft)

            // Кнопки «Ввести код восстановления» здесь больше нет.
            //
            // Код лежал в бандле открытым текстом, то есть открывал «Управление»
            // всякому, кто вскрыл `.app`. Забывший пароль администратор смотрит
            // теперь в панель — оттуда пароль и приезжает на машину.
            HStack {
                Spacer()

                Button("Отмена") { isPresented = false }
                Button("Войти") { submitPassword() }
                    .compatProminentButtonStyle()
                    .disabled(passwordDraft.isEmpty)
                    // Enter входит.
                    //
                    // Прежде не входил ничего: `borderedProminent` красит кнопку
                    // акцентом, но кнопкой по умолчанию её не назначает, — а
                    // пароль здесь набирают с клавиатуры и тянуться мышью после
                    // него противоестественно. То же и у двух кнопок ниже.
                    .compatKeyboardShortcut("\r", modifiers: [])
            }
        }
    }

    private func submitPassword() {
        guard !passwordDraft.isEmpty else { return }
        do {
            try model.unlockAdministration(password: passwordDraft)
            passwordDraft = ""
            problem = nil
            step = .warning
        } catch {
            problem = error.localizedDescription
            passwordDraft = ""
        }
    }

    // MARK: - Предупреждение до входа

    /// То же, что скажет подтверждение при сохранении.
    ///
    /// Дублирование намеренное. На входе человек ещё не знает, что будет
    /// менять, и предупреждение читается как формальность; на сохранении он уже
    /// час как забыл, что читал на входе. Один раз мало в обоих случаях.
    private var warningStep: some View {
        Group {
            CompatLabel(title: "Прежде чем открыть «Управление»", symbol: "exclamationmark.triangle")
                .font(.headline)
                .compatForeground(.orange)

            Text("""
                Здесь правки не применяются на ходу: они копятся, пока вы не нажмёте \
                «Сохранить». Закрыть окно без сохранения можно в любой момент.

                Сохранение объявит настройки этой машины локальными — их задаёт \
                администратор, а не файл конфигурации, — и запишет это в журнал.
                """)
            .font(.footnote)
            .compatForeground(.secondary)

            HStack {
                Spacer()
                Button("Отмена") {
                    model.lockAdministration()
                    isPresented = false
                }
                Button("Открыть «Управление»") {
                    isPresented = false
                    NSApp.sendAction(
                        #selector(AppDelegate.showAdministrationWindow(_:)), to: nil, from: nil
                    )
                }
                .compatProminentButtonStyle()
                .compatKeyboardShortcut("\r", modifiers: [])
            }
        }
    }
}
