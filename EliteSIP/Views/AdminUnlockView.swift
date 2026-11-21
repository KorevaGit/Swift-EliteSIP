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

    /// Зачем спрашивают пароль.
    ///
    /// Окно одно на обе дороги: пароль, журнал неудачных попыток и
    /// предупреждение до входа — общие, а разъехавшись, две копии однажды
    /// разошлись бы и в том, кого пускать.
    enum Purpose {
        /// Открыть окно «Управление».
        case administration
        /// Снять закрепление формата работы в разделе «Работа». Режим
        /// остаётся открытым до закрытия настроек — как у «Управления».
        case workplace
    }

    var purpose: Purpose = .administration

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
        .frame(width: GraphiteDialog.width)
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
            switch purpose {
            case .administration:
                DialogHeader(
                    icon: "shield-check",
                    title: "Управление настройками",
                    subtitle: "Аккаунты, клавиши, защита от автокликеров и диагностика."
                )
            case .workplace:
                DialogHeader(
                    icon: "lock-keyhole",
                    title: "Формат работы закреплён",
                    subtitle: "Сменить офис или дом можно только с паролем администратора."
                )
            }

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
            DialogHeader(
                icon: "triangle-alert",
                title: "Машина ещё не настроена",
                subtitle: "Пока не пройдена первоначальная настройка, «Управление» не открывается."
            )

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
    @ViewBuilder
    private var warningStep: some View {
        switch purpose {
        case .administration: administrationWarning
        case .workplace: workplaceWarning
        }
    }

    private var administrationWarning: some View {
        Group {
            DialogHeader(icon: "triangle-alert", title: "Прежде чем открыть «Управление»")

            // Текст заказчика, слово в слово, с одной поправкой по существу:
            // «любая смена настроек» сужена до тех, которыми управляет панель.
            // Административный пароль, срок хранения истории и словарь очередей
            // связку не рвут — панель ими не управляет вовсе, и обрывать связь
            // из-за смены пароля значило бы наказывать за неё потерей адресов
            // АТС. Список полей — `differsInPanelManagedFields`.
            Text("""
                Правка настроек, которыми управляет EliteSupport, переводит машину \
                в оффлайн: обновления конфигураций, новые клавиши и новые адреса \
                АТС перестают приходить, и управление клиентом переходит к вам.

                Вернуться можно кнопкой «Вернуться в онлайн» в «Техподдержке» или \
                в «Аккаунте» — местные правки тогда заменит панель.

                Все настройки применяются после нажатия «Сохранить».
                """)
            .font(.callout)
            .compatForeground(Theme.Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(Theme.Metrics.sectionSpacing + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .graphiteSurface(.control)

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

    /// Предупреждение перед снятием закрепления.
    ///
    /// Последствия те же, что у «Управления», и названы теми же словами: смена
    /// закреплённого формата — правка управляемой настройки. Отличие одно —
    /// уходит машина в оффлайн не на «Сохранить», а на само переключение:
    /// черновика у раздела «Работа» нет, переезд происходит сразу.
    private var workplaceWarning: some View {
        Group {
            DialogHeader(icon: "triangle-alert", title: "Прежде чем снять закрепление")

            Text("""
                Формат работы закрепил EliteSupport. Переключение офиса и дома переводит \
                машину в оффлайн: обновления конфигураций, новые клавиши и новые адреса \
                АТС перестают приходить, и управление клиентом переходит к вам.

                Вернуться можно кнопкой «Вернуться в онлайн» в «Техподдержке» или \
                в «Аккаунте» — местные правки тогда заменит панель.

                Пока настройки открыты, переключатель доступен. Машина уходит в оффлайн \
                только если его действительно переключить.
                """)
            .font(.callout)
            .compatForeground(Theme.Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(Theme.Metrics.sectionSpacing + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .graphiteSurface(.control)

            HStack {
                Spacer()
                Button("Отмена") {
                    model.lockAdministration()
                    isPresented = false
                }
                Button("Снять закрепление") { isPresented = false }
                    .compatProminentButtonStyle()
                    .compatKeyboardShortcut("\r", modifiers: [])
            }
        }
    }
}
