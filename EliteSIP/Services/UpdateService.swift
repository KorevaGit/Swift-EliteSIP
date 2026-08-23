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
/// 1. Раз в несколько часов приложение спрашивает канал и, если там новее,
///    молча качает архив в фоне. Оператор об этом не знает и знать не должен:
///    качать нечего решать.
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

    /// Как часто спрашивать канал. Это **не** частота напоминаний: appcast
    /// неделями не меняется, и дёргать его раз в полчаса незачем. Таймеры
    /// разные намеренно.
    private static let checkInterval: TimeInterval = 4 * 60 * 60

    /// Версия, которая скачана, проверена и ждёт решения. Пока она не `nil`,
    /// в панели видна кнопка «Обновить» — иначе состояние «готово к установке»
    /// существовало бы только в момент показа окна.
    @Published private(set) var readyVersion: String? {
        didSet { announce(readyVersion) }
    }

    private var updater: SPUUpdater?

    /// Ответ Sparkle, который мы держим у себя, пока оператор не решит.
    ///
    /// Именно удержание, а не отказ с повторной проверкой: пока блок не позван,
    /// сессия обновления жива, файл лежит распакованным, и «Обновить» через час
    /// сработает так же мгновенно, как сразу.
    private var installReply: ((SPUUserUpdateChoice) -> Void)?

    private var reminder: Timer?
    private var offerSheet: NSAlert?

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

    init(isBusy: @escaping () -> Bool,
         prepareForRestart: @escaping (@escaping () -> Void) -> Void,
         hostWindow: @escaping () -> NSWindow?,
         announce: @escaping (String?) -> Void,
         log: @escaping (String) -> Void) {
        self.isBusy = isBusy
        self.prepareForRestart = prepareForRestart
        self.hostWindow = hostWindow
        self.announce = announce
        self.log = log
        super.init()
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
        updater.automaticallyChecksForUpdates = true
        updater.automaticallyDownloadsUpdates = true
        updater.updateCheckInterval = Self.checkInterval

        do {
            try updater.start()
            self.updater = updater
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

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    func showUpdateFound(with appcastItem: SUAppcastItem,
                         state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
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
        acknowledgement()
    }

    /// Ошибку канала оператору не показываем: недоступный сайт — не его дело и
    /// не его забота. В журнал — обязательно: рабочее место, которое месяц не
    /// может достучаться до канала, иначе выглядит как обычное.
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        // не переводится: строка журнала
        log("обновление: ошибка канала — \(error.localizedDescription)")
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
    }
}
