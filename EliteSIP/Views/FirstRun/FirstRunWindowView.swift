import SIPCore
import SwiftUI

/// Окно первоначальной настройки: пять экранов в одной раме.
///
/// **Рама одна и не дышит.** Размер фиксированный, по самому высокому экрану:
/// по «Далее» щёлкают пять раз подряд, и кнопка, переезжающая между шагами,
/// ловит пятый щелчок мимо. Это тот же закон, по которому на панели не двигается
/// «Завершить», — только там цена промаха выше.
///
/// Экраны сменяются сдвигом: следующий приезжает справа, предыдущий уезжает
/// влево. Внизу — точки шагов и неподвижный ряд действий.
struct FirstRunWindowView: View {

    @EnvironmentObject private var model: AppModel
    @ObservedObject var flow: FirstRunFlow

    /// Идёт ли живая проверка регистрации.
    @State private var isChecking = false

    @ObservedObject private var wallpaper = WallpaperStore.shared

    var body: some View {
        VStack(spacing: 0) {
            stepper
                .padding(.top, Theme.Metrics.firstRunTitlebarInset + Theme.Metrics.tightSpacing)

            // Сдвиг обрезается рамкой экранов: без черты под ним, как в
            // Windows 1.0.4, уезжающий экран не должен проходить под шагами и
            // кнопками.
            screens
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()

            footer
        }
        // Ширину вью задаёт, высоту — **нет**: её задаёт окно, а вью её заполняет.
        //
        // С жёсткой высотой `NSHostingController` пересобирал окно следующим
        // проходом раскладки — уже после того, как кадр восстановлен, — и окно
        // подрастало на высоту полосы заголовка, каждый раз сдвигая себя на
        // 32 точки. Замер 17 августа 2026: `restore` дал 470, асинхронный проход
        // 502. Высота у мастера и так одна на все экраны, и держать её в двух
        // местах незачем.
        .frame(width: Theme.Metrics.firstRunWidth)
        .frame(maxHeight: .infinity)
        // Фон — как у остальных окон приложения, и по тому же правилу: материал
        // там, где в системе есть стекло, плоская заливка там, где его нет.
        // Мастер, единственный оставшийся полупрозрачным, читался бы как чужой
        // диалог из другой программы — но полупрозрачный поверх чужого рабочего
        // стола он читается ещё хуже: на Big Sur сквозь него видны обои.
        .compatBackground {
            Group {
                if wallpaper.settings.isEnabled {
                    // Обои рисует `WallpaperHost` под этим вью.
                    Color.clear
                } else if Theme.Chrome.usesLiquidGlass {
                    CompatMaterial(
                        material: .underWindowBackground,
                        blending: .behindWindow,
                        cornerRadius: 0
                    )
                } else {
                    Color(NSColor.windowBackgroundColor)
                }
            }
            .compatIgnoreSafeArea()
        }
    }

    // MARK: - Экраны

    @ViewBuilder
    private var screens: some View {
        ZStack {
            switch flow.step {
            case .welcome:
                FirstRunWelcomeScreen(flow: flow).transition(slide)
            case .firstUser:
                FirstRunUserScreen(flow: flow).transition(slide)
            case .appearance:
                FirstRunAppearanceScreen(flow: flow).transition(slide)
            case .finale:
                FirstRunFinaleScreen().transition(slide)
            }
        }
        .compatAnimation(.easeInOut(duration: 0.22), value: flow.step)
    }

    /// Сдвиг: вперёд приезжает справа, назад — слева.
    ///
    /// Асимметричный, а не `.slide`: тот всегда вставляет справа, и «Назад»
    /// выглядел бы как ещё один шаг вперёд.
    private var slide: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing),
            removal: .move(edge: .leading)
        )
    }

    // MARK: - Низ

    private var footer: some View {
        VStack(spacing: Theme.Metrics.sectionSpacing) {
            if let notice = flow.notice {
                Text(verbatim: notice)
                    .font(.footnote)
                    .compatForeground(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }

            // Точки — наложением, а не третьим элементом ряда.
            //
            // В ряду они стояли между двумя `Spacer`, и центр им доставался не
            // от окна, а от того, что осталось между «Назад» и «Далее»: на
            // первом экране, где «Назад» нет, точки уезжали левее середины на
            // всю ширину кнопки. Видно это только на живом окне — снимок
            // 17 августа 2026 и показал.
            HStack(spacing: Theme.Metrics.elementSpacing) {
                if flow.canGoBack {
                    Button("Назад") { flow.goBack() }
                }

                Spacer()

                if isChecking {
                    CompatSpinner()
                }

                Button(action: forward) {
                    Text(flow.step == .finale ? "Начать работу" : "Далее")
                        // Одинаковая ширина у обеих подписей: иначе кнопка
                        // меняет размер на последнем шаге — том самом, где по
                        // ней и щёлкают не глядя.
                        .frame(minWidth: 96)
                }
                .compatProminentButtonStyle()
                .disabled(!flow.canGoForward || isChecking)
                // Enter ведёт вперёд.
                //
                // Не удобство, а способ работы: на экране «Первый пользователь»
                // техподдержка вводит с клавиатуры четыре поля подряд, и тянуться
                // мышью к кнопке после каждого экрана — лишнее движение пять раз.
                // Прежде Enter не делал ничего: `borderedProminent` красит
                // кнопку акцентом, но кнопкой по умолчанию её не назначает.
                .compatKeyboardShortcut("\r", modifiers: [])
            }
        }
        .padding(Theme.Metrics.contentPadding)
    }

    /// Шаги сверху, как `WizardProgress` в Windows 1.0.4: значок и подпись,
    /// между ними стрелки. Пройденный шаг зелёный, текущий — акцентный.
    private var stepper: some View {
        let progress = flow.progress
        return HStack(spacing: Theme.Metrics.elementSpacing) {
            ForEach(Array(flow.steps.enumerated()), id: \.offset) { index, step in
                if index > 0 {
                    LucideIcon(name: "arrow-right", size: Theme.Icon.small)
                        .compatForeground(Theme.Palette.textTertiary)
                }
                stepItem(step, state: index < progress.index ? .done : index == progress.index ? .current : .upcoming)
            }
        }
        .padding(.horizontal, Theme.Metrics.sectionSpacing)
        .padding(.vertical, Theme.Metrics.elementSpacing)
        .graphiteSurface(.call)
        .frame(maxWidth: .infinity)
        .compatAccessibilityLabel(verbatim: "\(progress.index + 1) / \(progress.total)")
    }

    private enum StepState { case done, current, upcoming }

    private func stepItem(_ step: FirstRunFlow.Step, state: StepState) -> some View {
        let (icon, title): (String, LocalizedStringKey) = {
            switch step {
            case .welcome: return ("languages", "Язык")
            case .firstUser: return ("network", "Подключение")
            case .appearance: return ("panels-top-left", "Оформление")
            case .finale: return ("check", "Готово")
            }
        }()
        let color: Color = {
            switch state {
            case .done: return Theme.Palette.registered
            case .current: return Color.accentColor
            case .upcoming: return Theme.Palette.textTertiary
            }
        }()
        return VStack(spacing: Theme.Metrics.hairSpacing + 2) {
            LucideIcon(name: icon, size: Theme.Icon.medium)
                .frame(width: 30, height: 30)
                .graphiteSurface(state == .current ? .selected : .control, cornerRadius: 15)
                .compatForeground(color)
            Text(title)
                .font(.caption)
                .fontWeight(state == .current ? .semibold : .regular)
                .compatForeground(Theme.Palette.textSecondary)
                .lineLimit(1)
        }
        .frame(minWidth: 72)
    }

    // MARK: - Переход вперёд

    private func forward() {
        switch flow.step {
        case .welcome:
            // Язык применяется перезапуском сразу, а не в конце: иначе всё
            // показанное дальше читалось бы на том языке, который угадала
            // система. Если язык не меняли — перезапускать незачем.
            if flow.language == LanguageSetting.current {
                flow.advance()
            } else {
                model.applyFirstRunLanguage(flow.language)
            }

        case .firstUser:
            Task { await passFirstUser() }

        case .appearance:
            flow.advance()

        case .finale:
            // Окно открыто на посмотреть — ничего не применяем.
            //
            // Иначе отладочный ключ, открывающий мастер сразу на финале, кладёт на
            // машину пустой черновик: предыдущие экраны никто не проходил. Именно
            // так 17 августа 2026 были стёрты добавочный и пароль на рабочей
            // машине.
            guard !flow.isPreview else {
                NSApp.sendAction(#selector(AppDelegate.finishFirstRunWindow(_:)), to: nil, from: nil)
                return
            }

            // Всё набранное применяется и уходит на диск одним махом — здесь, на
            // последнем экране, а не перед ним. Перезапуск нужен только ради
            // корпуса: тот выбирается при сборке окон. Стекло оставили как было —
            // мастер просто откроет панель.
            if model.completeFirstRun(flow: flow) {
                model.relaunchAfterFirstRun()
            } else {
                // Окно закрывает и панель открывает делегат приложения — через
                // цепочку ответчиков, как это делают «Настройки» и «История».
                NSApp.sendAction(#selector(AppDelegate.finishFirstRunWindow(_:)), to: nil, from: nil)
            }
        }
    }

    /// Экран «Первый пользователь»: сперва пропуск, потом живая проверка.
    ///
    /// Пропуск проверяется здесь, а не в `canGoForward`: `matches` — это PBKDF2
    /// со 150 000 итераций, и гонять его на каждое нажатие клавиши нельзя.
    /// Ограничения по числу попыток нет — решение заказчика: пропуск знает только
    /// техподдержка, и запирать её после трёх опечаток значит запирать машину.
    ///
    /// Порядок именно такой: сперва пропуск, потом сеть. Проверка регистрации
    /// стоит секунды и ходит на АТС — гонять её тому, у кого нет пропуска,
    /// незачем.
    private func passFirstUser() async {
        // Путь кода пропуска не требует, и поля для него на экране нет
        // вовсе: административный пароль приезжает из панели, а не вводится
        // руками. Без этой строки «Далее» сверяла пустую строку с вшитым в
        // сборку паролем и отвечала «не подошёл» — то есть основной путь был
        // заперт проверкой, которой на нём не должно быть. Нашлось живым
        // прогоном 26 августа 2026.
        if case .machineCode = flow.route {
            flow.notice = nil
            flow.advance()
            return
        }

        guard model.firstRunPassMatches(flow.adminPassword) else {
            flow.notice = NSLocalizedString(
                "Административный пароль не подошёл.",
                comment: "отказ пропуска в мастере первого запуска"
            )
            return
        }

        isChecking = true
        flow.notice = NSLocalizedString(
            "Проверяем регистрацию на АТС…",
            comment: "ход живой проверки регистрации"
        )
        let outcome = await model.probeFirstRunRegistration(flow: flow)
        isChecking = false

        // `nil` — проверять нечего: это ветка готового слепка, где ничего не
        // вводили руками. Она идёт дальше без проверки, как договорено.
        guard let outcome else {
            flow.notice = nil
            flow.advance()
            return
        }

        guard outcome.isSuccess else {
            flow.notice = outcome.title
            return
        }

        flow.notice = nil
        flow.advance()
    }
}
