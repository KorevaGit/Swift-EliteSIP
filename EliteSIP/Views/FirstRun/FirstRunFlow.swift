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
        /// Разбор и цена отмены — в elitesupport/docs/DECISIONS.md.
        case activationKey

        /// Всё руками — для машины, до которой сервер не достаёт. Тумблера
        /// площадки нет: стук решает сам адрес.
        ///
        /// Веток осталось две. Ушли обе прежние, и по одной причине: они несли
        /// конторские настройки мимо панели. Заводская предустановка держала
        /// адреса, макросы и очереди прямо в бандле; файл конфигурации был тем
        /// же самым, только гуляющим по мессенджерам, — и сброшенная машина
        /// восстанавливалась из слепка месячной давности, о чём панель не
        /// узнавала никогда. Разбор — elitesupport/docs/DECISIONS.md.
        case manual
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

    /// Пара адресов одной и той же АТС — только для ручной ветки.
    ///
    /// Двумя полями, а не одним «Адрес АТС», с 27 августа 2026. Одно поле
    /// заводило машину так, будто у АТС один адрес, а их два — изнутри сети и
    /// снаружи, — и вторая половина пары оставалась заводской. Переключатель
    /// «Работа» у менеджера после такой настройки уводил его на чужой адрес
    /// либо не делал ничего, и починить это можно было только через
    /// «Управление», куда менеджера не пускают.
    ///
    /// Заполнены заводской парой, а не пусты: у ручной ветки половина машин —
    /// наши же, и стирать известный адрес ради того, чтобы его вписали заново,
    /// незачем.
    @Published var officeHost = SIPSiteAddresses.production.office
    @Published var remoteHost = SIPSiteAddresses.production.remote

    /// Адрес, на который машина зарегистрируется прямо сейчас.
    ///
    /// Офисный, если он вписан, иначе домашний: у удалённого места офисной
    /// половины может не быть вовсе. Площадка при этом остаётся `.automatic` —
    /// стучать или нет решает сам адрес.
    var host: String {
        let office = officeHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return office.isEmpty ? remoteHost.trimmingCharacters(in: .whitespacesAndNewlines) : office
    }

    /// Помашинный доступ, забранный тем же заходом, что и пакет.
    ///
    /// Административный пароль лежит здесь, а не в пакете: он поле
    /// предустановки, и панель везёт его отдельным подписанным объектом. Без
    /// него мастер не закончится — иначе машина встала бы с «Управлением»,
    /// открытым всякому.
    @Published var openedAccess: MachineAccess?

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

    /// Чем кончилась последняя проверка ключа — отдельно от общего `notice`.
    ///
    /// Общая строка живёт внизу окна, под чертой, а ключ вводят посреди экрана:
    /// отказ появлялся в добрых двухстах точках от поля, которое его вызвало, и
    /// человек, глядящий на ключ, его попросту не видел. Своё поле — своя
    /// надпись под ним, и она же красит рамку поля.
    @Published var keyFailure: String?

    /// Что сказать про последнюю попытку — отказ пропуска, отказ файла, исход
    /// живой проверки. Живёт до следующего действия.
    @Published var notice: String?

    init(isPreview: Bool = false) {
        self.isPreview = isPreview
        // Ветка по умолчанию — ключ из панели: это основной путь, и стажёров
        // каждую неделю заводят именно им. «Вручную» остаётся дорогой для
        // машины, до которой сервер не достаёт.
        route = .activationKey
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
            case .manual:
                // Хотя бы одна половина пары: место бывает и чисто офисным,
                // и чисто удалённым, а без обеих регистрироваться некуда.
                return !trimmedNumber.isEmpty && !password.isEmpty && !host.isEmpty
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
        keyFailure = nil
        openedPackage = nil
        openedAccess = nil

        let parsed: ActivationKey
        do {
            parsed = try ActivationKey(input: key)
        } catch {
            keyFailure = (error as? LocalizedError)?.errorDescription
                ?? PanelLinkError.malformedKey.errorDescription
            return
        }

        isOpeningKey = true
        defer { isOpeningKey = false }

        do {
            let package = try await ActivationService.fetch(key: parsed)

            // Свой административный пароль забирается тем же заходом, а не
            // потом по таймеру: между концом мастера и первым опросом канала
            // «Управление» стояло бы открытым для всякого, а машина выглядела
            // бы настроенной. Ключ к этому моменту уже сгорел, поэтому отказ
            // здесь — это отказ всей активации, и сказать о нём надо сразу.
            openedAccess = try await MachineService.fetchAccess(
                installationID: package.installationID,
                channelKey: package.channelKey
            )
            openedPackage = package
        } catch {
            keyFailure = (error as? LocalizedError)?.errorDescription
                ?? PanelLinkError.keyDidNotOpen.errorDescription
        }
    }

    func goBack() {
        guard canGoBack, let index = steps.firstIndex(of: step), index > 0 else { return }
        notice = nil
        keyFailure = nil
        step = steps[index - 1]
    }

    /// Переводит на следующий экран. Проверки, которым нужно время, делает
    /// вызывающая сторона — здесь только шаг.
    func advance() {
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return }
        notice = nil
        keyFailure = nil
        step = steps[index + 1]
    }

    /// Номер шага и сколько их всего — для точек внизу.
    var progress: (index: Int, total: Int) {
        (steps.firstIndex(of: step) ?? 0, steps.count)
    }
}
