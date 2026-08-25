import AppKit
import Foundation
import Sparkle

/// Автообновление рабочего места (M7h).
///
/// **Почему свой драйвер, а не готовый `SPUStandardUserDriver`.** Стандартный
/// показывает окно с тремя кнопками, среди которых «Пропустить эту версию», и
/// отдельно спрашивает разрешение на перезапуск. Обе вещи запрещены решением
/// 20 августа 2026: пропускать версию нельзя вовсе, а момент установки выбирает
/// оператор одной кнопкой, а не диалогом из трёх шагов.
///
/// **Что здесь происходит по порядку.**
///
/// 1. Раз в полчаса приложение спрашивает канал и, если там новее, молча
///    качает архив в фоне. Оператор об этом не знает и знать не должен: качать
///    нечего решать. Интервал короткий не из любви к частым проверкам, а
///    потому что нет ещё синхронизации настроек через `elitesip.vip` (M9) —
///    без неё это единственная ручка, доступная всем сразу; кнопка «Проверить
///    сейчас» в «Диагностике» существует по той же причине, для одной машины.
/// 2. Скачанное Sparkle проверяет сам — подписью EdDSA и совпадением подписи
///    кода с установленной копией. До нас доходит только то, что обе проверки
///    прошло.
/// 3. И только теперь появляется предложение: две кнопки, «Обновить» и
///    «Отложить». Нажатие «Обновить» ничего не начинает, а завершает — файл уже
///    лежит проверенный, поэтому и выглядит мгновенным.
///
/// **Отсрочка — ровно полчаса, и предела ей нет.** Так решено сознательно:
/// частота в полчаса заменяет принуждение, а рабочее место, которое неделю
/// жмёт «Отложить», — это вопрос настойчивости, а не политики.
///
/// **Предложение не показывается в разговоре.** Проверка та же, что запрещает
/// отключение профиля (M6b): непустой список линий. Входящий звонок закрывает
/// уже открытое предложение — окно вызова стоит в случайной позиции (M3), и
/// перекрывать его чем бы то ни было нельзя.
///
/// **Регистрация снимается до подмены бандла.** Sparkle про АТС ничего не знает
/// и просто завершит процесс; станция будет держать привязку к мёртвому клиенту
/// до истечения таймера. На обязательном обновлении это умножилось бы на все
/// рабочие места разом.
/// Класс живёт на главном акторе целиком, как и `AppModel`. Это не осторожность:
/// оба протокола Sparkle — `SPUUserDriver` и `SPUUpdaterDelegate` — помечены
/// `NS_SWIFT_UI_ACTOR`, то есть их методы и так зовутся только оттуда.
@MainActor
final class UpdateService: NSObject, ObservableObject {

    /// Через сколько предложение возвращается после «Отложить».
    private static let reminderInterval: TimeInterval = 30 * 60

    /// Как часто спрашивать канал — **и обновления, и предустановки**.
    ///
    /// Один интервал на обе линии, и это требование, а не удобство: канал у них
    /// общий, и два независимых будильника на нём — это два места, где можно
    /// ошибиться со сроком. Отсюда же и то, что таймер здесь один и заводится
    /// ниже вручную, а Sparkle своим расписанием больше не пользуется.
    ///
    /// Совпадает с `reminderInterval` не по совпадению, а по нужде: пока нет
    /// инструмента синхронизации настроек через `elitesip.vip` (M9), этот
    /// интервал один на все рабочие места и меняется только новой сборкой —
    /// значит держать его коротким дешевле, чем потом объяснять, почему выпуск
    /// не доехал за несколько часов. appcast сам по себе неделями не меняется,
    /// так что 30 минут — это не «нужная частота», а верхняя граница ожидания,
    /// которую можно себе позволить, пока настройка не стала гибкой.
    ///
    /// Константы разные и это осознанно, хотя значения сегодня совпадают: одна
    /// решает, когда Sparkle дёргает канал, другая — когда наш драйвер
    /// напоминает про уже найденное. Дальше они могут снова разойтись, и
    /// синонимизировать их значило бы завязать два разных решения на одно имя.
    private static let checkInterval: TimeInterval = 30 * 60

    /// Версия, которая скачана, проверена и ждёт решения. Пока она не `nil`,
    /// в панели видна кнопка «Обновить» — иначе состояние «готово к установке»
    /// существовало бы только в момент показа окна.
    @Published private(set) var readyVersion: String? {
        didSet { announce(readyVersion) }
    }

    /// Идёт ли ручная проверка «сейчас» — кнопка в «Диагностике» → «Сборка».
    ///
    /// Отличается от фоновой проверки не флагом, а самим механизмом: Sparkle
    /// зовёт `showUserInitiatedUpdateCheck` только в ответ на явный вызов
    /// `checkForUpdates()`, а фоновый таймер идёт через другой внутренний
    /// драйвер, который про этот метод протокола вообще не знает. Ложных
    /// срабатываний на автоматической проверке быть не может в принципе, а не
    /// потому, что мы их отфильтровали.
    @Published private(set) var isChecking = false

    /// Итог последней ручной проверки — коротко, для той же кнопки. `nil` и на
    /// старте, и пока проверка идёт: смешивать «ещё не проверяли» с «проверка
    /// сейчас идёт» незачем, за второе отвечает `isChecking`.
    @Published private(set) var lastCheckResult: String?

    private var updater: SPUUpdater?

    /// Ответ Sparkle, который мы держим у себя, пока оператор не решит.
    ///
    /// Именно удержание, а не отказ с повторной проверкой: пока блок не позван,
    /// сессия обновления жива, файл лежит распакованным, и «Обновить» через час
    /// сработает так же мгновенно, как сразу.
    private var installReply: ((SPUUserUpdateChoice) -> Void)?

    private var reminder: Timer?
    private var offerSheet: NSAlert?

    /// Общий цикл проверок: обновления и предустановки одним будильником.
    private var cycle: Timer?

    /// Первая проверка после запуска.
    ///
    /// Не мгновенно, а через несколько секунд: на старте приложение поднимает
    /// регистрацию, звук и окна, и отправлять его при этом ещё и в сеть значит
    /// соревноваться с самим собой за первые секунды, которые человек видит.
    private static let firstCheckDelay: TimeInterval = 5

    /// Идёт ли разговор. Замыкание, а не ссылка на модель: сервису не нужно
    /// ничего о ней знать, кроме одного этого факта.
    private let isBusy: () -> Bool

    /// Снять регистрацию и позвать завершение. Ограничение по времени — на
    /// стороне вызывающего: зависшее снятие регистрации повесило бы установщик.
    private let prepareForRestart: (@escaping () -> Void) -> Void

    private let hostWindow: () -> NSWindow?
    private let log: (String) -> Void

    /// Сообщить приложению, что версия скачана и ждёт, — или что уже не ждёт.
    private let announce: (String?) -> Void

    /// Сообщить приложению об итоге ручной проверки — тем же путём, что и
    /// `announce`: сервис публикует факт, а решает, что с ним делать на
    /// экране, уже вью.
    private let reportCheckState: (Bool, String?) -> Void

    /// Спросить канал ещё и о предустановках.
    ///
    /// Замыкание, а не ссылка на службу предустановок: этому сервису о ней
    /// знать нечего, кроме того, что её надо дёрнуть в том же такте. Линии
    /// разные — код и данные, — а будильник общий.
    private let alsoCheckPresets: () -> Void

    init(isBusy: @escaping () -> Bool,
         prepareForRestart: @escaping (@escaping () -> Void) -> Void,
         hostWindow: @escaping () -> NSWindow?,
         announce: @escaping (String?) -> Void,
         reportCheckState: @escaping (Bool, String?) -> Void,
         alsoCheckPresets: @escaping () -> Void = {},
         log: @escaping (String) -> Void) {
        self.isBusy = isBusy
        self.prepareForRestart = prepareForRestart
        self.hostWindow = hostWindow
        self.announce = announce
        self.reportCheckState = reportCheckState
        self.alsoCheckPresets = alsoCheckPresets
        self.log = log
        super.init()
    }

    private func setCheckState(checking: Bool, result: String?) {
        isChecking = checking
        lastCheckResult = result
        reportCheckState(checking, result)
    }

    // MARK: - Запуск

    /// Поднять обновление. Без канала в провижининге не делает ничего и
    /// говорит об этом в журнал: отладочная сборка на машине без конфига должна
    /// работать, просто без обновлений.
    func start() {
        guard let channel = Provisioning.secrets?.updates, let feed = channel.feedURL else {
            // не переводится: строка журнала
            log("обновления выключены: в провижининге нет канала")
            return
        }

        // Пара авторизации кладётся в хранилище учётных данных заранее.
        // Проверено вживую 20 августа 2026: `URLSession` подставляет её только
        // при **точном** совпадении realm — с другим значением приложение
        // получит молчаливый 401 и решит, что обновлений нет.
        if let host = feed.host {
            let space = URLProtectionSpace(
                host: host,
                port: feed.port ?? 443,
                protocol: "https",
                realm: "restricted",
                authenticationMethod: NSURLAuthenticationMethodHTTPBasic
            )
            URLCredentialStorage.shared.setDefaultCredential(
                URLCredential(user: channel.user, password: channel.password, persistence: .forSession),
                for: space
            )
        }

        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        // Расписанием Sparkle больше не пользуется, и это осознанная замена.
        //
        // Своё расписание у него было бы вторым будильником на том же канале —
        // рядом с нашим, который обязан дёргать ещё и предустановки. Два
        // независимых срока на одной линии расходятся не сразу, а через
        // полгода, когда один поменяли, а про другой забыли.
        //
        // Взамен цикл ниже сам зовёт `checkForUpdatesInBackground()` — тот же
        // путь, которым Sparkle ходил по своему таймеру, только позванный нами.
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = true

        do {
            try updater.start()
            self.updater = updater
            startCycle()
            // не переводится: строка журнала
            log("обновления включены, канал \(feed.absoluteString)")
        } catch {
            // Не поднялось — приложение работает дальше без обновлений. Падать
            // из-за этого нельзя: софтфон нужен для звонков, а не для того,
            // чтобы обновляться.
            // не переводится: строка журнала
            log("обновления не поднялись: \(error.localizedDescription)")
        }
    }

    // MARK: - Общий цикл

    /// Заводит единый будильник и делает первую проверку.
    ///
    /// **Проверка на каждом старте — требование, а не оптимизация.** Машину
    /// выключают на ночь и включают утром; без проверки при запуске выпуск,
    /// вышедший вечером, доезжает не утром, а через полчаса после начала
    /// рабочего дня — и то же самое с правкой макроса, сделанной вчера.
    private func startCycle() {
        cycle?.invalidate()
        cycle = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            // не переводится: строка журнала
            Task { @MainActor in self?.runCycle(reason: "по таймеру") }
        }

        Timer.scheduledTimer(withTimeInterval: Self.firstCheckDelay, repeats: false) { [weak self] _ in
            // не переводится: строка журнала
            Task { @MainActor in self?.runCycle(reason: "при запуске") }
        }
    }

    /// Один такт: спросить канал об обновлении и о предустановках.
    ///
    /// Обе линии дёргаются всегда вместе, даже если одна из них только что
    /// отвечала: раздельные условия — это тот самый второй будильник, только
    /// спрятанный в `if`.
    private func runCycle(reason: String) {
        // не переводится: строка журнала
        log("проверка канала \(reason)")

        if let updater, updater.canCheckForUpdates {
            updater.checkForUpdatesInBackground()
        }
        alsoCheckPresets()
    }

    // MARK: - Что зовёт приложение

    /// Начался разговор.
    func hostBecameBusy() {
        guard offerSheet != nil else { return }
        dismissOffer()
        // не переводится: строка журнала
        log("обновление: предложение убрано на время разговора")
        // Полчаса, а не «сразу»: вернуть предложение должен конец разговора
        // (`hostBecameIdle`), а этот таймер — запасной путь на случай, если тот
        // сигнал потеряется. Ноль здесь давал срабатывание вхолостую через
        // секунду, пока разговор ещё идёт.
        scheduleReminder(after: Self.reminderInterval)
    }

    /// Разговоров больше нет.
    func hostBecameIdle() {
        guard installReply != nil, offerSheet == nil, reminder != nil else { return }
        offerIfPossible()
    }

    /// Кнопка «Обновить» в панели, между предложениями.
    func installNow() {
        offerIfPossible(force: true)
    }

    /// Кнопка «Проверить сейчас» в «Диагностике» → «Сборка».
    ///
    /// Не подменяет обычный цикл — тот идёт своим чередом, эта проверка
    /// просто не ждёт `checkInterval`. Нужна ровно на то время, пока нет
    /// синхронизации настроек через `elitesip.vip`: разбирая жалобу на
    /// конкретном рабочем месте, ждать до получаса, чтобы увидеть, дошёл ли
    /// канал вообще, — не дело.
    func checkNow() {
        // Предустановки спрашиваются всегда, даже если канал обновлений не
        // настроен: это разные линии, и молчание одной не повод молчать обеим.
        alsoCheckPresets()

        guard let updater else {
            setCheckState(checking: false, result: NSLocalizedString(
                "Канал обновлений не настроен",
                comment: "результат ручной проверки обновлений"
            ))
            return
        }
        // Уже идёт проверка — своя или фоновая по таймеру. Кнопка блокируется
        // только на свою (`isChecking` отражает лишь ручной путь), поэтому
        // фоновую нельзя различить заранее — отвечаем текстом, а не молчанием:
        // клик без всякой видимой реакции читался бы как поломка.
        guard updater.canCheckForUpdates else {
            setCheckState(checking: false, result: NSLocalizedString(
                "Проверка уже идёт — подождите",
                comment: "результат ручной проверки обновлений"
            ))
            return
        }
        updater.checkForUpdates()
    }

    // MARK: - Предложение

    private func offerIfPossible(force: Bool = false) {
        guard let reply = installReply, let version = readyVersion else { return }
        guard offerSheet == nil else { return }

        // Между показом окна и нажатием мог прийти входящий: проверяем в
        // момент действия, а не только при показе.
        guard !isBusy() else {
            // не переводится: строка журнала
            if force { log("обновление: не сейчас — идёт разговор") }
            scheduleReminder(after: Self.reminderInterval)
            return
        }

        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString("Доступна версия %@", comment: "предложение обновиться"),
            version
        )
        alert.informativeText = NSLocalizedString(
            "Обновление уже загружено и проверено. Установка займёт несколько секунд, приложение перезапустится само.",
            comment: "предложение обновиться"
        )
        alert.addButton(withTitle: NSLocalizedString("Обновить", comment: "кнопка в предложении обновиться"))
        alert.addButton(withTitle: NSLocalizedString("Отложить", comment: "кнопка в предложении обновиться"))
        offerSheet = alert

        let decide: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            self.offerSheet = nil
            if response == .alertFirstButtonReturn {
                guard !self.isBusy() else {
                    // Разговор начался, пока окно стояло открытым.
                    // не переводится: строка журнала
                    self.log("обновление: отложено, начался разговор")
                    self.scheduleReminder(after: Self.reminderInterval)
                    return
                }
                // не переводится: строка журнала
                self.log("обновление: устанавливаем")
                self.reminder?.invalidate()
                self.reminder = nil
                self.installReply = nil
                reply(.install)
            } else {
                // не переводится: строка журнала
                self.log("обновление: отложено на полчаса")
                self.scheduleReminder(after: Self.reminderInterval)
            }
        }

        if let window = hostWindow() {
            alert.beginSheetModal(for: window, completionHandler: decide)
        } else {
            decide(alert.runModal())
        }
    }

    private func dismissOffer() {
        guard let alert = offerSheet else { return }
        offerSheet = nil
        if let window = alert.window as NSWindow?, let sheetParent = window.sheetParent {
            sheetParent.endSheet(window, returnCode: .alertSecondButtonReturn)
        }
    }

    private func scheduleReminder(after delay: TimeInterval) {
        reminder?.invalidate()
        guard installReply != nil else { return }
        // Цель и селектор, а не замыкание: замыкание таймера помечено
        // `@Sendable`, и захват `self` в нём — предупреждение на ровном месте.
        // Класс и так `NSObject`, так что старый способ здесь дешевле.
        let timer = Timer(timeInterval: max(delay, 1),
                          target: self,
                          selector: #selector(reminderFired),
                          userInfo: nil,
                          repeats: false)
        // Предложение обязано всплывать и когда оператор держит открытым меню
        // или тащит окно: в общем режиме таймер в это время не срабатывает.
        RunLoop.main.add(timer, forMode: .common)
        reminder = timer
    }

    @objc private func reminderFired() {
        offerIfPossible()
    }
}

// MARK: - SPUUpdaterDelegate

extension UpdateService: SPUUpdaterDelegate {

    /// Канал — по срезу, из провижининга. В `Info.plist` его нет намеренно:
    /// там одно значение на оба среза universal-бандла.
    func feedURLString(for updater: SPUUpdater) -> String? {
        Provisioning.secrets?.updates?.feedURL?.absoluteString
    }

    /// Снять регистрацию до того, как процесс завершат.
    ///
    /// Возвращаем `true` и зовём `installHandler` сами — это единственное
    /// место в жизненном цикле Sparkle, где можно сделать что-то асинхронное
    /// перед подменой бандла.
    func updater(_ updater: SPUUpdater,
                 shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        // не переводится: строка журнала
        log("обновление: снимаем регистрацию перед установкой")
        prepareForRestart(installHandler)
        return true
    }
}

// MARK: - SPUUserDriver

extension UpdateService: SPUUserDriver {

    /// Разрешение спрашивать не у кого: политику обновлений задаёт не оператор.
    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    /// Sparkle зовёт это только для проверки, начатой явным
    /// `checkForUpdates()`, — то есть только для нашей кнопки «Проверить
    /// сейчас». Фоновый цикл идёт другим внутренним драйвером и сюда не
    /// попадает вовсе.
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        setCheckState(checking: true, result: nil)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem,
                         state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // Единая точка снятия «идёт проверка», одна на все стадии: если
        // проверка была ручной, к этому месту она уже нашла что искала.
        if isChecking {
            let text: String
            switch state.stage {
            case .installing:
                text = String(format: NSLocalizedString(
                    "Обновление готово: %@",
                    comment: "результат ручной проверки обновлений"
                ), appcastItem.displayVersionString)
            default:
                text = NSLocalizedString(
                    "Обновление найдено, скачивается…",
                    comment: "результат ручной проверки обновлений"
                )
            }
            setCheckState(checking: false, result: text)
        }

        switch state.stage {
        case .notDownloaded, .downloaded:
            // Качать нечего решать: файл едет в фоне, оператор об этом не знает.
            reply(.install)
        case .installing:
            // А вот это уже готовое к установке — спрашиваем.
            readyVersion = appcastItem.displayVersionString
            installReply = reply
            offerIfPossible()
        @unknown default:
            reply(.dismiss)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFound(acknowledgement: @escaping () -> Void) { acknowledgement() }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        if isChecking {
            setCheckState(checking: false, result: NSLocalizedString(
                "Обновлений нет",
                comment: "результат ручной проверки обновлений"
            ))
        }
        acknowledgement()
    }

    /// Ошибку канала оператору не показываем: недоступный сайт — не его дело и
    /// не его забота. В журнал — обязательно: рабочее место, которое месяц не
    /// может достучаться до канала, иначе выглядит как обычное.
    ///
    /// В «Диагностику» текст ошибки всё же попадает, но только как итог
    /// **ручной** проверки: администратор, разбирающий жалобу и нажавший
    /// «Проверить сейчас», должен увидеть, что именно не так, а не только
    /// строку в журнале.
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        // не переводится: строка журнала
        log("обновление: ошибка канала — \(error.localizedDescription)")
        if isChecking {
            setCheckState(checking: false, result: String(format: NSLocalizedString(
                "Ошибка: %@",
                comment: "результат ручной проверки обновлений"
            ), error.localizedDescription))
        }
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {}
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}

    /// Всё проверено и распаковано. Отсюда начинается видимая часть.
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        installReply = reply
        if readyVersion == nil { readyVersion = NSLocalizedString("новая", comment: "версия обновления неизвестна") }
        // не переводится: строка журнала
        log("обновление готово к установке")
        offerIfPossible()
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {}

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        reminder?.invalidate()
        reminder = nil
        installReply = nil
        readyVersion = nil
        dismissOffer()
        // Подстраховка: если сессия оборвалась, не дойдя ни до одного из мест
        // выше, «идёт проверка» не должно застрять навсегда и запереть кнопку.
        if isChecking { setCheckState(checking: false, result: nil) }
    }
}
