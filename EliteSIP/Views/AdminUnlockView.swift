import AdminAccess
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
    }

    @State private var step: Step = .password
    @State private var passwordDraft = ""
    @State private var recoveryDraft = ""
    @State private var newPasswordDraft = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch step {
            case .password: passwordStep
            case .recovery: recoveryStep
            case .revealed(let password): revealedStep(password)
            }

            if let problem {
                CompatLabel(title: problem, symbol: "exclamationmark.triangle")
                    .font(.footnote)
                    .compatForeground(Theme.Palette.failure)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    // MARK: - Пароль

    private var passwordStep: some View {
        Group {
            Text("Управление настройками")
                .font(.headline)
            Text("Аккаунты, макросы, защита от автокликеров и диагностика.")
                .font(.footnote)
                .compatForeground(.secondary)

            // `onSubmit` появился в macOS 12; ввод завершает кнопка «Войти».
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
            }
        }
    }

    private func submitPassword() {
        guard !passwordDraft.isEmpty else { return }
        do {
            try model.unlockAdministration(password: passwordDraft)
            passwordDraft = ""
            isPresented = false
        } catch {
            problem = error.localizedDescription
            passwordDraft = ""
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
                он не сбрасывается, потому что совпадает с паролем в EliteDash.
                """)
            .font(.footnote)
            .compatForeground(.secondary)

            ZStack {
                HStack(spacing: 8) {
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
        RoundedRectangle(cornerRadius: 6)
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
                Обычно он совпадает с паролем в EliteDash. Меняйте его здесь только \
                если знаете, что делаете: до появления синхронизации (M8) смена \
                разведёт эту машину с системой.
                """)
            .font(.footnote)
            .compatForeground(.secondary)

            SecureField("Новый пароль — необязательно", text: $newPasswordDraft)

            HStack {
                Spacer()
                Button("Оставить как есть") { isPresented = false }
                Button("Сменить пароль") { changePassword() }
                    .compatProminentButtonStyle()
                    .disabled(newPasswordDraft.isEmpty)
            }
        }
    }

    private func changePassword() {
        do {
            try model.setAdminPassword(newPasswordDraft)
            newPasswordDraft = ""
            isPresented = false
        } catch {
            problem = error.localizedDescription
        }
    }
}
