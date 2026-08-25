import Foundation
import PanelLink
import SIPCore
import SwiftUI

/// Черновик мастера первоначальной настройки (этап 9).
///
/// **Черновик, а не правка на месте** — то же устройство, что у «Управления», и
/// по той же причине: у мастера есть «Назад», и шаг назад с уже применённым
/// снимком означал бы откат записанного. Здесь на диск не уходит ничего до
/// самого конца; всё применяется одним махом в `AppModel.completeFirstRun`.
///
/// Порядок экранов и то, что каждый решает, разобрано в `docs/ui-plan.md`,
/// раздел «Этап 9». Коротко: язык первым, потому что всё после него читается на
/// выбранном; тема и стекло последними, потому что ради них приложение
/// перезапускается — обе настройки берутся при старте процесса и на лету не
/// применяются.
@MainActor
final class FirstRunFlow: ObservableObject {

    /// Экран мастера. Порядок объявления — порядок показа.
    ///
    /// Тема и стекло стоят на одном экране — «Оформление», по решению
    /// 17 августа 2026. Двумя они были потому, что применяются по-разному (тема
    /// живьём, корпус только при сборке окон), но человеку это различие ничего не
    /// говорит: он отвечает на один вопрос «как приложение должно выглядеть», и
    /// делить его на два экрана — считать своей реализацией чужие шаги.
    enum Step: Int, CaseIterable, Comparable {
        case welcome
        case firstUser
        case appearance
        case finale

        static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }

        #if DEBUG
            /// Имя экрана для отладочного ключа `--first-run <экран>`.
            ///
            /// Своё, а не `rawValue`: тот число, и запоминать «третий экран — это
            /// 2» проверяющему незачем.
            init?(debugName: String) {
                switch debugName {
                case "welcome": self = .welcome
                case "user", "firstUser": self = .firstUser
                case "appearance": self = .appearance
                case "finale": self = .finale
                default: return nil
                }
            }
        #endif
    }

    /// Как заводится первое рабочее место.
    ///
    /// `Hashable` ради `Picker`: выбор ветки — системная группа радиокнопок, и
    /// теги в ней сравниваются по хэшу.
    enum Route: Hashable {
        /// Ключ из панели EliteSIP — основной путь с M9.
        ///
        /// Номер, пароль SIP, административный пароль и предустановка приезжают
        /// одним пакетом; сотрудник вводит только ключ. **Административного
        /// пропуска этот путь не требует** — он и есть в пакете, — и это
        /// осознанная отмена решения этапа 9 «мастер проходит техподдержка».
        /// Разбор и цена отмены — в elitesip-site/docs/DECISIONS.md.
        case activationKey
        /// Заводская предустановка: техподдержка вписывает добавочный и пароль.
        case preset(name: String)
        /// Всё руками. Тумблера площадки нет: стук решает сам адрес.
        case manual
        /// Готовый слепок машины из файла. Поля прячутся, проверки нет.
        case configFile
    }

    @Published var step: Step = .welcome

    /// Мастер открыт на посмотреть, а не на настроить.
    ///
    /// Ставится только отладочным ключом `--first-run` и запрещает **применять
    /// что-либо**: последняя кнопка закрывает окно и всё.
    ///
    /// Появилось после того, как ключ стёр настройки на рабочей машине. Он был
    /// заявлен безобидным — «показывает окно и ничего не применяет само», — и это
    /// было неправдой: `--first-run finale` открывает мастер сразу на последнем
    /// экране, а там кнопка ровно и применяет черновик. Черновик при этом пустой,
    /// потому что предыдущие экраны никто не проходил, — и предустановка легла на
    /// машину с пустым добавочным и пустым паролем SIP. 17 августа 2026.
    let isPreview: Bool

    // MARK: - Что набрано

    @Published var language: LanguageSetting = LanguageSetting.current
    @Published var appearance: AppearanceSetting = .system
    @Published var plainChrome = false

    @Published var route: Route
    @Published var number = ""
    @Published var password = ""
    @Published var adminPassword = ""

    /// Площадка. Только для ветки предустановки: она выбирает и признак стука, и
    /// адрес из пары. В ручной ветке остаётся `.automatic` — адрес там вписан
    /// руками, и спрашивать про площадку значило бы спрашивать дважды об одном.
    @Published var site: SIPProfileSite = .office

    /// Адрес АТС — только для ручной ветки.
    @Published var host = ""

    /// Прочитанный файл конфигурации и его имя для показа.
    @Published var loadedConfig: AppSettings?
    @Published var loadedConfigName = ""

    // MARK: - Ключ активации

    /// То, что ввёл сотрудник. Терпимо к разделителям и регистру — разбирает
    /// его `ActivationKey`, а не это поле.
    @Published var key = ""

    /// Распечатанный пакет. Пока он `nil`, применять нечего.
    ///
    /// **Показывается человеку до того, как что-либо применится.** Он должен
    /// увидеть, чьё рабочее место поднимает, прежде чем машина зарегистрируется
    /// на АТС под чужим номером. Дешёвая защита от перепутанного ключа.
    @Published var openedPackage: ActivationPackage?

    /// Идёт ли обращение к каналу. Пока идёт, кнопку жать второй раз незачем.
    @Published var isOpeningKey = false

    /// Что сказать про последнюю попытку — отказ пропуска, отказ файла, исход
    /// живой проверки. Живёт до следующего действия.
    @Published var notice: String?

    init(presets: [Provisioning.FactoryPreset], isPreview: Bool = false) {
        self.presets = presets
        self.isPreview = isPreview
        // Ветка по умолчанию — ключ из панели: с M9 это основной путь, и
        // стажёров каждую неделю заводят именно им. Прежние три остаются
        // дорогой для машины, до которой панель не достаёт.
        route = .activationKey
    }

    /// Заводские предустановки этой сборки.
    let presets: [Provisioning.FactoryPreset]

    /// Выбранная предустановка, если ветка предустановочная.
    var selectedPreset: Provisioning.FactoryPreset? {
        guard case .preset(let name) = route else { return nil }
        return presets.first { $0.name == name }
    }

    // `showsPresetPicker` убран 17 августа 2026 вместе с радиокнопками. Он
    // прятал список из одного пункта — правило «выбор из одного пункта не выбор»,
    // взятое из «Аккаунта». У выпадающего списка этой беды нет: «Вручную» стоит в
    // нём всегда, то есть пунктов минимум два, и прятать нечего.

    // MARK: - Навигация

    /// Экраны, по которым идёт мастер на этой машине.
    ///
    /// Все четыре и всегда. Стекло выпадает не экраном, а тумблером внутри
    /// «Оформления»: там, где стекла нет в самой системе, выбирать не из чего, —
    /// но тема есть везде, и экран остаётся.
    var steps: [Step] { Step.allCases }

    var canGoBack: Bool { step != .welcome && step != .finale }

    /// Готов ли текущий экран к «Далее».
    ///
    /// Пропуск проверяется не здесь, а при переходе: `matches` — это PBKDF2 со
    /// 150 000 итерациями, и гонять его на каждое нажатие клавиши в поле нельзя.
    var canGoForward: Bool {
        switch step {
        case .welcome, .appearance, .finale:
            return true
        case .firstUser:
            // Ключевой путь пропуска не требует: административный пароль
            // приезжает в самом пакете. Проверка стоит до общей, а не внутри
            // switch ниже, потому что снимает условие целиком, а не уточняет.
            if case .activationKey = route {
                return openedPackage != nil
            }
            guard !adminPassword.isEmpty else { return false }
            switch route {
            case .activationKey:
                // Разобран выше; сюда не доходит.
                return openedPackage != nil
            case .preset:
                return !trimmedNumber.isEmpty && !password.isEmpty
            case .manual:
                return !trimmedNumber.isEmpty && !password.isEmpty
                    && !host.trimmingCharacters(in: .whitespaces).isEmpty
            case .configFile:
                return loadedConfig != nil
            }
        }
    }

    var trimmedNumber: String { number.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Забирает пакет по введённому ключу и показывает, что в нём.
    ///
    /// Ничего не применяет: применение — дело последнего экрана. Здесь только
    /// «чей это ключ», и человек это видит до того, как машина зарегистрируется
    /// на АТС под чужим номером.
    @MainActor
    func openKey() async {
        guard !isOpeningKey else { return }
        notice = nil
        openedPackage = nil

        let parsed: ActivationKey
        do {
            parsed = try ActivationKey(input: key)
        } catch {
            notice = (error as? LocalizedError)?.errorDescription
                ?? PanelLinkError.malformedKey.errorDescription
            return
        }

        isOpeningKey = true
        defer { isOpeningKey = false }

        do {
            openedPackage = try await ActivationService.fetch(key: parsed)
        } catch {
            notice = (error as? LocalizedError)?.errorDescription
                ?? PanelLinkError.keyDidNotOpen.errorDescription
        }
    }

    func goBack() {
        guard canGoBack, let index = steps.firstIndex(of: step), index > 0 else { return }
        notice = nil
        step = steps[index - 1]
    }

    /// Переводит на следующий экран. Проверки, которым нужно время, делает
    /// вызывающая сторона — здесь только шаг.
    func advance() {
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return }
        notice = nil
        step = steps[index + 1]
    }

    /// Номер шага и сколько их всего — для точек внизу.
    var progress: (index: Int, total: Int) {
        (steps.firstIndex(of: step) ?? 0, steps.count)
    }
}
