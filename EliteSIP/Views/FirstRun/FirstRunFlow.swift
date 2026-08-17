import Foundation
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
        /// Заводская предустановка: техподдержка вписывает добавочный и пароль.
        case preset(name: String)
        /// Всё руками. Тумблера площадки нет: стук решает сам адрес.
        case manual
        /// Готовый слепок машины из файла. Поля прячутся, проверки нет.
        case configFile
    }

    @Published var step: Step = .welcome

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

    /// Что сказать про последнюю попытку — отказ пропуска, отказ файла, исход
    /// живой проверки. Живёт до следующего действия.
    @Published var notice: String?

    init(presets: [Provisioning.FactoryPreset]) {
        self.presets = presets
        // Ветка по умолчанию — первая предустановка, если она есть: типовое
        // рабочее место заводится чаще, чем нетиповое.
        route = presets.first.map { .preset(name: $0.name) } ?? .manual
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
            guard !adminPassword.isEmpty else { return false }
            switch route {
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
