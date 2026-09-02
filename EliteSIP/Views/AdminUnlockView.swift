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
        /// Машина не настроена: пускать некуда и не во что.
        case unconfigured
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
            case .unconfigured: unconfiguredStep
            }

            if let problem {
                CompatLabel(verbatim: problem, symbol: "exclamationmark.triangle")
                    .font(.footnote)
                    .compatForeground(Theme.Palette.failure)
            }
        }
        .padding(Theme.Metrics.contentPadding)
        .frame(width: Theme.Metrics.dialogWidth)
        // Порядок проверок здесь и есть решение о том, кого пускать.
        //
        // **Непройденный мастер запирает «Управление» раньше пароля.** Сброс
        // машины уносит пароль вместе со всем остальным и зовёт мастер, но окно
        // мастера закрывается крестиком: сбросить машину и уйти было можно, и
        // оставалась она с пустыми настройками и «Управлением», открытым
        // всякому, — ровно тем состоянием, ради лечения которого мастер и
        // заведён. Найдено аудитом 27 августа 2026.
        //
        // Пароль после этого проверяется как раньше: незащищённая, но
        // настроенная машина — это законное состояние (пароль снимают руками),
        // и предупреждение ей всё равно показывается: открытые настройки не
        // делают правку менее последствийной.
        .onAppear {
            guard model.firstRun == .passed else {
                step = .unconfigured
                return
            }
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

    // MARK: - Машина не настроена

    /// Тупик с одним выходом — в мастер.
    ///
    /// Не «пароль не подошёл» и не пустое окно: человек здесь не ошибся, он
    /// пришёл в настройки машины, которой ещё нет. Единственное осмысленное
    /// действие — закончить настройку, и кнопка делает ровно его.
    private var unconfiguredStep: some View {
        Group {
            CompatLabel(title: "Машина ещё не настроена", symbol: "exclamationmark.triangle")
                .font(.headline)
                .compatForeground(.orange)

            Text("""
                Первоначальная настройка не пройдена: у машины нет ни рабочего места, ни                 административного пароля. Пока это так, «Управление» не открывается — иначе                 настройки ненастроенной машины правил бы кто угодно.
                """)
            .font(.footnote)
            .compatForeground(.secondary)

            HStack {
                Spacer()
                Button("Отмена") { isPresented = false }
                Button("Продолжить настройку") {
                    isPresented = false
                    NSApp.sendAction(
                        #selector(AppDelegate.showFirstRunAfterReset(_:)), to: nil, from: nil
                    )
                }
                .compatProminentButtonStyle()
                .compatKeyboardShortcut("\r", modifiers: [])
            }
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

            // Текст заказчика, слово в слово, с одной поправкой по существу:
            // «любая смена настроек» сужена до тех, которыми управляет панель.
            // Административный пароль, срок хранения истории и словарь очередей
            // связку не рвут — панель ими не управляет вовсе, и обрывать связь
            // из-за смены пароля значило бы наказывать за неё потерей адресов
            // АТС. Список полей — `differsInPanelManagedFields`.
            Text("""
                Правка настроек, которыми управляет EliteSupport, полностью ломает \
                синхронизацию с ключом. Чтобы вернуть её, ключ придётся выпускать \
                и привязывать заново.

                Продолжая, вы осознанно рвёте связку с EliteSupport и соглашаетесь \
                не получать обновления конфигураций, новые клавиши и новые адреса \
                АТС — управление клиентом полностью переходит к вам.

                Все настройки применяются после нажатия «Сохранить».
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
