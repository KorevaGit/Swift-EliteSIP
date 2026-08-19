import AdminAccess
import AppKit
import SwiftUI

/// Вход в административный режим: пароль или код восстановления.
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
        /// Шесть клеток кода восстановления.
        case recovery
        /// Код подошёл: показываем действующий пароль и предлагаем сменить.
        case revealed(String)
        /// Пароль принят: предупреждение до того, как окно откроется.
        case warning
    }

    @State private var step: Step = .password
    @State private var passwordDraft = ""
    @State private var recoveryDraft = ""
    @State private var newPasswordDraft = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
            switch step {
            case .password: passwordStep
            case .recovery: recoveryStep
            case .revealed(let password): revealedStep(password)
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

            HStack {
                Button("Ввести код восстановления") {
                    problem = nil
                    recoveryDraft = ""
                    step = .recovery
                }
                .buttonStyle(.borderless)
                .compatForeground(.secondary)

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

    // MARK: - Код восстановления

    /// Шесть клеток.
    ///
    /// Ввод вслепую: в клетках стоят точки, а не цифры. Смысл не в защите от
    /// подглядывания — код всё равно набирают на своей машине, — а в том, что
    /// поле ведёт себя как поле пароля везде, где вводится секрет. Одно правило
    /// вместо двух похожих.
    private var recoveryStep: some View {
        Group {
            Text("Код восстановления")
                .font(.headline)
            Text("""
                \(RecoveryCode.length) цифр. Код покажет действующий пароль этой машины — \
                он не сбрасывается, потому что совпадает с паролем в конфигурации.
                """)
            .font(.footnote)
            .compatForeground(.secondary)

            ZStack {
                HStack(spacing: Theme.Metrics.sectionSpacing) {
                    ForEach(0..<RecoveryCode.length, id: \.self) { index in
                        cell(isFilled: index < recoveryDraft.count)
                    }
                }
                // Поле поверх клеток: нажатие на любую из них попадает в него,
                // и дальше человек просто набирает цифры. `@FocusState` появился
                // в macOS 12, а срез x86_64 живёт с Catalina, поэтому фокус
                // ставится нажатием, а не программно.
                SecureField("", text: recoveryBinding)
                    .textFieldStyle(.plain)
                    .opacity(0.02)
            }
            .frame(height: 44)

            HStack {
                Button("Назад") {
                    problem = nil
                    step = .password
                }
                .buttonStyle(.borderless)
                .compatForeground(.secondary)

                Spacer()

                Button("Отмена") { isPresented = false }
                Button("Проверить") { submitRecovery() }
                    .compatProminentButtonStyle()
                    .compatKeyboardShortcut("\r", modifiers: [])
                    .disabled(!RecoveryCode.isWellFormed(recoveryDraft))
            }
        }
    }

    /// Только цифры и не длиннее шести: чистка на записи, а не `onChange`,
    /// которого нет до macOS 11.
    private var recoveryBinding: Binding<String> {
        Binding(
            get: { recoveryDraft },
            set: { entered in
                recoveryDraft = String(RecoveryCode.normalized(entered).prefix(RecoveryCode.length))
                problem = nil
            }
        )
    }

    private func cell(isFilled: Bool) -> some View {
        RoundedRectangle(cornerRadius: Theme.Radius.control)
            .strokeBorder(Color.secondary.opacity(isFilled ? 0.9 : 0.35), lineWidth: 1)
            .frame(width: 36, height: 44)
            .overlay(
                Circle()
                    .frame(width: 8, height: 8)
                    .compatForeground(.primary)
                    .opacity(isFilled ? 1 : 0)
            )
    }

    private func submitRecovery() {
        guard RecoveryCode.isWellFormed(recoveryDraft) else { return }
        do {
            let password = try model.unlockAdministration(recoveryCode: recoveryDraft)
            recoveryDraft = ""
            newPasswordDraft = ""
            problem = nil
            step = .revealed(password)
        } catch {
            problem = error.localizedDescription
            recoveryDraft = ""
        }
    }

    // MARK: - Пароль показан

    private func revealedStep(_ password: String) -> some View {
        Group {
            Text("Действующий пароль")
                .font(.headline)

            // Показывается открытым: администратор уже доказал право его знать,
            // а прятать за «показать» то, ради чего он сюда пришёл, — лишний шаг.
            // Моноширинным: пароль переписывают на бумагу, и «l» рядом с «1»
            // в пропорциональном шрифте однажды перепишут не так.
            // Размер задан в пунктах, а не стилем `.title3`: тот появился в
            // macOS 11, а срез x86_64 живёт с Catalina.
            Text(password)
                .font(.system(size: 18, weight: .regular, design: .monospaced))

            Text("""
                Обычно он совпадает с паролем в конфигурации. Меняйте его здесь только \
                если знаете, что делаете: до появления файла конфигурации (M8) смена \
                разведёт эту машину с остальными.
                """)
            .font(.footnote)
            .compatForeground(.secondary)

            SecureField("Новый пароль — необязательно", text: $newPasswordDraft)

            HStack {
                Spacer()
                Button("Оставить как есть") { step = .warning }
                Button("Сменить пароль") { changePassword() }
                    .compatProminentButtonStyle()
                    .disabled(newPasswordDraft.isEmpty)
            }
        }
    }

    /// Смена пароля по коду восстановления применяется сразу, а не черновиком.
    ///
    /// Черновик живёт в окне «Управление», а сюда человек попал потому, что
    /// пароль забыт: отложить смену до сохранения настроек значило бы, что
    /// закрытие окна без сохранения возвращает забытый пароль обратно.
    private func changePassword() {
        do {
            try model.setAdminPassword(newPasswordDraft)
            newPasswordDraft = ""
            problem = nil
            step = .warning
        } catch {
            problem = error.localizedDescription
        }
    }
}
