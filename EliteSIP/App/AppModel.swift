import AdminAccess
import Compat
import CallGuard
import CallHistory
import Diagnostics
import MediaCore
import Network
import SIPCore
import SwiftUI

/// Состояние приложения и владелец SIP-агента.
///
/// Единственная модель, на которую смотрят вьюхи. Агент — actor, поэтому вся
/// связь с ним асинхронная, а состояние сюда приезжает потоком событий.
///
/// `ObservableObject`, а не `@Observable`: макрос Observation появился только в
/// macOS 14, а срез x86_64 обязан работать на Catalina. Разница в цене — не
/// адресная перерисовка, а полная: `objectWillChange` не различает, какое
/// свойство изменилось. Для панели 280×500 это незаметно.
@MainActor
final class AppModel: ObservableObject {

    struct LogEntry: Identifiable, Sendable {
        let id = UUID()
        let date: Date
        let level: SIPLogLevel
        let message: String
    }

    /// Сколько строк лога держим в памяти. Больше не нужно: подробное живёт в
    /// файле (M7a), а здесь журнал только для быстрого взгляда на панели.
    private static let logCapacity = 500

    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            // Тема применяется ко всему приложению разом: окон несколько, и
            // расходиться по оформлению им нельзя.
            if settings.appearance != oldValue.appearance {
                NSApp.appearance = settings.appearance.appKitAppearance
            }
            // Журнал пересобирается только при смене его собственных настроек:
            // переоткрывать файл на каждое движение ползунка громкости незачем.
            if settings.logFile != oldValue.logFile {
                openLogFileIfNeeded()
            }
            // Срок хранения меняет администратор, и уменьшение срока обязано
            // сработать сразу, а не при следующем запуске: это удаление
            // персональных данных, а не настройка отображения.
            //
            // Но не в открытом черновике. Придержка в «Управлении» вообще-то
            // держит только запись на диск, а правки в памяти живые — для
            // громкости это и нужно. Здесь исключение, и оно единственное:
            // «Отменить» не вернёт удалённые записи. Срок применяется по
            // «Сохранить», см. `commitAdministration`.
            if settings.history != oldValue.history, !isHoldingSettingsWrites {
                openHistoryIfNeeded()
            }
            persistSettings()
        }
    }

    /// Что показать под кнопкой «Исправить сеть». Живёт до следующего нажатия:
    /// человек нажал её потому, что что-то не работает, и ответ «сделано» ему
    /// нужен на экране, а не в журнале.
    @Published var networkRepairStatus: String?

    /// Административный режим.
    ///
    /// Проверочное значение пароля живёт в настройках и переживает перезапуск,
    /// а открытость режима — только здесь и только до закрытия окна настроек.
    /// Поэтому состояние целиком в модели, а не половина в файле: единственное
    /// место, где можно спросить «закрытая часть видна?», — это оно.
    ///
    /// Сеттер открыт ради `AppModel+Admin`, и это ничего не ослабляет:
    /// `AdminAccessState` не даёт создать себя открытым, а `isUnlocked` внутри
    /// него закрыт на запись. Открыть режим можно только предъявив пароль.
    @Published var adminAccess = AdminAccessState()

    /// Настройки, какими они были при входе в «Управление». nil — черновика нет.
    /// Живёт здесь, а логика — в `AppModel+Administration`.
    var administrationSnapshot: AppSettings?

    /// Придержка записи на диск, пока открыт черновик.
    @Published var isHoldingSettingsWrites = false

    // Отдельного черновика для пароля SIP здесь нет: он обычное поле настроек,
    // а придержку записи на диск делает `isHoldingSettingsWrites` — та же, что
    // и для всего остального в окне «Управление».

    /// Административный пароль в черновике.
    @Published var pendingAdminPassword: String?

    /// В черновике нажато «Снять пароль».
    @Published var pendingAdminPasswordRemoval = false

    /// Этап самопроверки звука. Крутит менеджерскую страницу настроек.
    @Published var selfTestPhase: VoiceSelfTest.Phase = .idle

    // MARK: - История звонков

    /// Хранилище истории. nil — история выключена настройками или база не
    /// открылась; в обоих случаях остальной код продолжает работать.
    /// Устройство и решения — `AppModel+History`.
    var historyStore: CallHistoryStore?

    /// Какой записи истории соответствует живая линия.
    ///
    /// Отдельным словарём, а не полем в `CallLine`: линия — это состояние
    /// разговора, а не бухгалтерия, и завязывать одно на другое пришлось бы во
    /// всех местах, где линия заводится.
    var historyRecordIDs: [String: UUID] = [:]

    /// Ежесуточная уборка просроченного.
    var historyPruneTask: Task<Void, Never>?

    /// Что показывает окно истории.
    @Published var historyFilter: CallHistoryStore.Filter = .all {
        didSet {
            guard historyFilter != oldValue else { return }
            reloadHistory()
        }
    }

    /// Показанная страница истории и общее число записей под фильтром.
    @Published var historyRecords: [CallRecord] = []
    @Published var historyTotalCount: Int = 0

    /// Живая проверка. Держится здесь, потому что её нельзя терять на
    /// перерисовке формы: `deinit` останавливает движок, и запись оборвалась бы
    /// от любого движения интерфейса.
    var selfTest: VoiceSelfTest?

    /// Общий аудиотракт. Заводится при первом звонке или первой самопроверке —
    /// см. `voiceBus()`.
    private var sharedVoiceBus: VoiceAudioBus?

    @Published private(set) var registration: SIPRegistrationState = .idle {
        didSet { noteRegistrationChanged() }
    }

    /// Затянулось ли подключение.
    ///
    /// Слот беды молчит про обычную регистрацию: она занимает доли секунды и
    /// текстом только мигала бы — при каждом запуске, смене сети и пробуждении.
    /// Говорить стоит о затянувшейся, и признак этого взводится по таймеру.
    @Published private(set) var isRegistrationSlow = false

    /// Ушёл ли оператор с линии сам.
    ///
    /// Только в памяти: в настройки не пишется намеренно, см. `goOffline()`.
    @Published var isOfflineByChoice = false

    private var registrationSlowTask: Task<Void, Never>?

    /// Сколько ждать, прежде чем сказать «Подключение…».
    private static let slowRegistrationDelay: Interval = .seconds(2)

    /// Наблюдатель за сетью и признак её последнего состояния.
    ///
    /// Не `private`: логика автоподключения живёт в `AppModel+AutoConnect`,
    /// а хранимые свойства расширению добавить нельзя.
    var networkMonitor: NWPathMonitor?
    /// `@Published`, потому что от него зависит слот беды: пропавшая сеть
    /// обязана появляться в строке состояния, а не только в журнале.
    @Published var lastNetworkPathIsSatisfied = false
    var lastNetworkInterfaces: Set<String> = []
    var wakeObserver: NSObjectProtocol?
    @Published private(set) var log: [LogEntry] = []

    /// Набранный номер — всегда в том виде, в котором он уйдёт на сервер.
    ///
    /// Нормализация стоит в `didSet`, а не в момент звонка, и это принципиально:
    /// оператор должен видеть в поле ровно то, что уйдёт в INVITE. Номер
    /// приезжает из CRM человеческим — `+7 (918) 000-11-22`, — и если чистить
    /// его молча при отправке, в поле останется одно, а позвонит другое.
    ///
    /// Ограничение на длину тоже здесь: 32 знака — это больше любого реального
    /// добавочного и международного номера вместе с плюсом, а вставка целой
    /// страницы в поле набора не должна превращаться в попытку позвонить.
    @Published var dialedNumber: String = "" {
        didSet {
            let normalized = String(DialedNumber.normalized(dialedNumber).prefix(32))
            // Присваиваем только когда есть что менять: `didSet` сработает
            // повторно, и без проверки это был бы бесконечный цикл.
            if normalized != dialedNumber { dialedNumber = normalized }
        }
    }

    /// Где мы сейчас в истории набора. `nil` — не в ней.
    var dialHistoryIndex: Int?
    /// Что было набрано до того, как оператор полез стрелкой в историю.
    var dialHistoryDraft: String = ""

    @Published private var agent: SIPUserAgent?
    private var eventPump: Task<Void, Never>?

    init() {
        let storedVersion = SettingsStore.storedSchemaVersion()
        settings = SettingsStore.load()
        openLogFileIfNeeded()
        // После журнала: открытие истории пишет в него свой исход, включая
        // «база была повреждена».
        openHistoryIfNeeded()

        // Запуск всегда начинается с закрытого режима, чем бы ни закончился
        // предыдущий: открытость нигде не сохраняется, и это решение, а не
        // упущение.
        adminAccess.restore(
            credential: settings.admin.credential,
            management: settings.admin.management
        )

        // Наблюдатель `settings` в `init` не срабатывает, поэтому мигрированный
        // файл сам собой не перезапишется. Записываем сразу: иначе профиль,
        // полученный из старой учётки, получал бы при каждом запуске новый
        // идентификатор — и «активный профиль» указывал бы каждый раз на другой.
        if let storedVersion, storedVersion < AppSettings.currentSchemaVersion {
            persistSettings()
            // Что именно произошло, зависит от файла: старая единственная
            // учётка становится профилем, а файл, у которого профили уже были,
            // просто получает новый номер схемы. Обещать первое в обоих случаях
            // нельзя — журнал читают как свидетельство, а не как приветствие.
            append(
                level: .info,
                message: settings.profiles.profiles.count == 1
                    ? "настройки переведены в схему \(AppSettings.currentSchemaVersion): учётка стала профилем"
                    : "настройки переведены в схему \(AppSettings.currentSchemaVersion): профилей \(settings.profiles.profiles.count)"
            )
        }
    }

    // MARK: - Файловый журнал

    /// Журнал в файле. nil, когда выключен настройками.
    ///
    /// Живёт рядом с журналом в памяти, а не вместо него: на панели нужен
    /// короткий взгляд на последние строки, а в файле — подробности, по которым
    /// потом разбирают жалобу.
    private(set) var logFile: LogFile?

    private func openLogFileIfNeeded() {
        guard settings.logFile.isEnabled else {
            logFile = nil
            return
        }
        logFile = LogFile(settings: settings.logFile.storage)
    }

    /// Каталог журнала — для кнопки «Показать в Finder».
    var logDirectory: URL { AppSettings.LogFileSettings.directory }

    /// Собирает архив для поддержки: журнал плюс сведения о сборке и системе.
    ///
    /// Возвращает путь готового файла. Секреты в справку не попадают: маскирование
    /// журнала на неё не распространяется, и класть туда лишнее нельзя.
    func makeSupportArchive() throws -> URL {
        logFile?.flush()
        let destination = logDirectory.appendingPathComponent(SupportArchive.suggestedName())
        return try SupportArchive.make(
            logs: logFile?.files() ?? [],
            summary: supportSummary,
            destination: destination
        )
    }

    private var supportSummary: String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        let codecs = settings.audio.prefersWideband ? "широкая полоса" : "только G.711"
        return [
            "EliteSIP \(version) (\(build))",
            system,
            "транспорт: \(settings.account.transport.protocolName)",
            "кодеки: \(codecs)",
            "уровень на экране: \(settings.minimumLogLevel.rawValue)",
            "уровень в файле: \(settings.logFile.minimumLevel.rawValue)",
            "линий сейчас: \(lines.count)",
        ].joined(separator: "\n")
    }

    // MARK: - Учётная запись

    var isConnected: Bool { registration.isRegistered }

    /// Поднят ли агент. Нужен автоподключению: сам `agent` приватный, и знать о
    /// нём снаружи надо ровно одно — существует он или нет.
    var isAgentRunning: Bool { agent != nil }

    var isBusy: Bool {
        switch registration {
        case .registering, .unregistering: true
        default: false
        }
    }

    var canConnect: Bool {
        settings.account.isUsable && !settings.sipPassword.isEmpty && agent == nil
    }

    /// Чего не хватает, чтобы подключиться.
    ///
    /// `nil` — не хватает не человеку, а обстоятельствам: сети, серверу,
    /// времени. Такое чинится само, и говорить об этом оператору нечего.
    ///
    /// Появилось вместе с автоподключением: пока в панели была кнопка
    /// «Подключить», её неактивность сама была сообщением. Кнопки нет, и
    /// «Не подключено» без причины оставляет человека гадать.
    ///
    /// Обе подписи — про настройку, а не про действие оператора. Пароль от
    /// добавочного вписывает администратор в «Управлении», и просить его у
    /// того, кто сел за машину, приложение не должно: он его не знает.
    var setupHint: String? {
        guard case .idle = registration else { return nil }
        if !settings.account.isUsable { return "Нет учётной записи" }
        if settings.sipPassword.isEmpty { return "Профиль без пароля" }
        return nil
    }

    var registrationTitle: String {
        switch registration {
        case .idle: setupHint ?? "Не подключено"
        case .registering: "Подключение…"
        case .registered: "На линии"
        case .unregistering: "Отключение…"
        case .failed(let reason, _): reason
        }
    }

    /// Вторая строка в бейдже. Держится короткой: панель узкая, и Contact
    /// целиком всё равно виден в диагностике и в журнале.
    var registrationDetail: String? {
        switch registration {
        case .registered(let expiresAt, _):
            "до \(TimeText.short.string(from: expiresAt))"
        case .failed(_, let retryAt):
            retryAt.map { "повтор в \(TimeText.short.string(from: $0))" }
        default:
            nil
        }
    }

    // MARK: - Подключение

    func connect() async {
        guard agent == nil else { return }

        let account = settings.account
        guard account.isUsable else {
            append(level: .error, message: "не заданы номер или домен")
            return
        }

        // Пароль лежит в самом профиле, рядом с номером и доменом: брать его
        // больше неоткуда, и ждать его появления не нужно.
        let password = settings.sipPassword
        guard !password.isEmpty else {
            append(level: .error, message: "у профиля не задан пароль")
            return
        }

        if account.transport == .tls && settings.acceptsAnyTLSCertificate {
            append(
                level: .warning,
                message: "TLS без проверки сертификата — только для лаборатории"
            )
        }

        let channel = NetworkSIPTransport(
            remote: account.signalingEndpoint,
            transport: account.transport,
            tlsTrust: settings.acceptsAnyTLSCertificate ? .acceptAnyCertificateInsecurely : .system,
            serverName: account.domain
        )

        // Стук нужен только удалённому рабочему месту, и решает это профиль:
        // поле «Рабочее место», а если оно оставлено на «по адресу сервера» —
        // сам адрес. Подробности и почему это не защита — docs/remote-access.md.
        let site = settings.profiles.active.site
        let knocker = PortKnocker.forServer(
            account.signalingEndpoint.host,
            site: site,
            sequence: settings.portKnock
        ) { [weak self] level, message in
            Task { @MainActor in self?.append(level: level, message: message) }
        }

        let agent = SIPUserAgent(
            account: account,
            credentials: DigestAuthentication.Credentials(
                username: account.effectiveAuthUsername,
                password: password
            ),
            channel: channel,
            pathOpener: knocker
        )
        self.agent = agent

        append(
            level: .info,
            message: "подключение к \(account.signalingEndpoint) по \(account.transport.protocolName)"
        )
        // Одна строка в журнале, не в интерфейсе: сотруднику про стук знать не
        // надо, а тому, кто разбирает жалобу «не регистрируется», надо в первую
        // очередь. Пишется и отсутствие стука тоже: «почему не стучим» —
        // ровно тот же вопрос, и раньше ответом на него было молчание.
        let because = PortKnockPolicy.explanation(
            serverHost: account.signalingEndpoint.host,
            site: site
        )
        if knocker != nil {
            append(
                level: .info,
                message: "стук перед регистрацией (\(because)), "
                    + "первая попытка через \(Int(settings.portKnock.estimatedDuration.seconds)) с"
            )
        } else if PortKnockPolicy.needsKnocking(
            serverHost: account.signalingEndpoint.host, site: site
        ) {
            // Стучать надо, а нечем: последовательность пуста. Это осознанное
            // выключение из файла настроек, и выглядеть оно должно именно так,
            // а не как «профиль офисный».
            append(level: .warning, message: "стук выключен настройкой, хотя \(because)")
        } else {
            append(level: .debug, message: "стука нет (\(because))")
        }

        // Ответ на чужой повторный INVITE собирает приложение: это удержание с
        // той стороны, смена кодека или переброс медиа на другой адрес — всё
        // то, о чём SIPCore не знает и знать не должен.
        await agent.setMediaRenegotiator { [weak self] callID, offer in
            guard let self else { return nil }
            return await renegotiateMedia(on: callID, offer: offer)
        }

        let events = agent.events
        eventPump = Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }

        await agent.start()
    }

    /// Отключаться в разговоре нельзя.
    ///
    /// Снятие регистрации закрывает диалоги: кнопка «Отключить» рядом с бейджем
    /// кладёт трубку клиенту, и отменить это нечем. Соседство с индикатором
    /// делает промах особенно дешёвым, а последствия — нет. Требование M6b.
    ///
    /// Выйти из приложения это не мешает: выход спрашивает подтверждение и
    /// отключается принудительно, то есть вслух.
    var canDisconnect: Bool { lines.isEmpty }

    func disconnect(force: Bool = false) async {
        guard force || canDisconnect else {
            append(level: .warning, message: "отключение недоступно: идёт разговор")
            callStatus = "Сначала завершите разговор"
            return
        }

        guard let agent else {
            teardownAllLines()
            return
        }
        self.agent = nil
        // Агент сначала кладёт трубку на КАЖДОЙ линии, пока транспорт ещё жив,
        // и только потом снимает регистрацию. Порядок важен ровно так же, как
        // в M6b, только линий теперь до трёх.
        await agent.stop()
        eventPump?.cancel()
        eventPump = nil
        teardownAllLines()
        registration = .idle
        append(level: .info, message: "отключено")
    }

    func reconnect() async {
        guard canDisconnect else {
            append(level: .warning, message: "переподключение недоступно: идёт разговор")
            callStatus = "Сначала завершите разговор"
            return
        }
        await disconnect()
        await connect()
    }

    /// Взводит и снимает признак затянувшегося подключения.
    ///
    /// Задача пересоздаётся на каждой смене состояния, а не заводится один раз:
    /// регистрация повторяется с backoff, и вторая попытка обязана отсчитывать
    /// свои две секунды заново — иначе после первого же долгого подключения
    /// надпись висела бы до конца сеанса.
    private func noteRegistrationChanged() {
        registrationSlowTask?.cancel()
        registrationSlowTask = nil

        guard case .registering = registration else {
            isRegistrationSlow = false
            return
        }

        isRegistrationSlow = false
        registrationSlowTask = Task { [weak self] in
            try? await Task.sleep(Self.slowRegistrationDelay)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, case .registering = registration else { return }
                isRegistrationSlow = true
            }
        }
    }

    private func handle(_ event: SIPUserAgent.Event) {
        switch event {
        case .registration(let state):
            registration = state

        case .log(let level, let message):
            append(level: level, message: message)

        case .incomingCall(let call):
            handle(incoming: call)

        case .unsupportedRequest(let method):
            append(level: .info, message: "запрос \(method.rawValue) отклонён: ещё не поддерживается")
        }
    }

    // MARK: - Линии

    enum CallPhase: Equatable {
        case idle
        case dialing
        case ringing
        /// Нам звонят, окно на экране, решение за оператором.
        case incoming
        case active
        case ending
    }

    /// Одна линия оператора: сигнализация, медиа и всё, что про неё видно.
    ///
    /// Структура, а не класс, и ровно по той же причине, по которой модель
    /// осталась `ObservableObject`: панель перерисовывается по изменению
    /// опубликованного свойства, а класс внутри массива менялся бы молча —
    /// линия уехала бы на удержание, а кнопки остались прежними.
    struct CallLine: Identifiable {

        /// Call-ID. Им линия адресуется в `SIPCore`, и другого ключа у неё нет.
        let id: String
        let isOutgoing: Bool
        var peer: String

        /// Имя собеседника, как его прислал сервер. В шапке панели оно идёт
        /// крупным планом, а номер — мелким: оператор работает с человеком, а
        /// не с цифрами.
        var displayName: String?

        /// Момент соединения. Ставится сам при переходе в разговор — иначе
        /// пришлось бы помнить об этом в трёх местах, откуда фаза меняется.
        var connectedAt: Date?

        var phase: CallPhase {
            didSet {
                if phase == .active, connectedAt == nil { connectedAt = Date() }
            }
        }

        var status: String = ""

        /// Линия, ради которой заведена эта консультация. У обычной — nil.
        var consultsLine: String?

        var media: MediaSession?

        /// Последнее описание медиа, которое мы отправили по этой линии —
        /// предложение или ответ. Из него строится повторное предложение: порт,
        /// кодеки и ключ SRTP обязаны в нём остаться прежними.
        var localDescription: SessionDescription?

        var isOnHold = false
        var isRemotelyHeld = false
        var isMicrophoneMuted = false
        var isRenegotiating = false
        var sentDTMF = ""
        var isTransferring = false

        /// Чем закончился перевод, если он закончился успехом.
        ///
        /// Наша нога после успешного REFER завершается сразу, и обычная причина
        /// окончания («завершён») стёрла бы единственное подтверждение оператору.
        var transferOutcome: String?

        var isConferenceCommandPending = false
        var isConferenceCommandSent = false

        var negotiatedCodec: AudioCodec?
        var audioRoute: AudioRoute?
        var echoCancellationActive: Bool?
        var remoteAudioView: RTCPSession.RemoteView?

        /// Короткая подпись для списка линий.
        var title: String { peer.isEmpty ? "линия" : peer }
    }

    /// Линии в порядке появления. Первая — разговор, дальше консультация и
    /// третий участник конференции.
    @Published private(set) var lines: [CallLine] = []

    /// Линия, которой принадлежит звук. Остальные стоят на удержании и
    /// аудиотракта не держат: микрофон, выход и обработка голоса у оператора
    /// одни на всех.
    @Published private(set) var activeLineID: String?

    @Published private(set) var callStatus: String = ""

    private var callTasks: [String: Task<Void, Never>] = [:]

    var activeLine: CallLine? {
        guard let activeLineID else { return nil }
        return lines.first { $0.id == activeLineID }
    }

    private func index(of lineID: String) -> Int? {
        lines.firstIndex { $0.id == lineID }
    }

    private func line(_ lineID: String) -> CallLine? {
        index(of: lineID).map { lines[$0] }
    }

    /// Единственное место, где меняется линия.
    ///
    /// Отсюда же история узнаёт про ответ, перевод и конференцию — сравнением
    /// состояния до и после. Тот же приём, что у маскирования секретов в
    /// журнале: пока путь один, забыть отметить событие можно только вместе с
    /// самим событием.
    private func mutate(_ lineID: String, _ body: (inout CallLine) -> Void) {
        guard let index = index(of: lineID) else { return }
        let before = lines[index]
        body(&lines[index])
        noteHistory(before: before, after: lines[index])
    }

    /// Строка состояния показывает активную линию.
    ///
    /// Отдельным хранимым свойством, а не вычисляемым по линии: последняя
    /// причина («занято», «переведён на 601») обязана пережить саму линию —
    /// иначе оператор не увидит, чем кончился звонок.
    ///
    /// `echo` нужен консультационному переводу: REFER уходит по исходной линии,
    /// а оператор в этот момент слушает консультационную, и без него нажатие
    /// «Соединить» не отвечает ничем.
    private func setStatus(_ text: String, on lineID: String, echo: Bool = false) {
        mutate(lineID) { $0.status = text }
        if echo || lineID == activeLineID { callStatus = text }
    }

    // Что видно про активную линию. Панель узкая и показывает одну линию
    // целиком; список остальных — отдельной полосой.
    var callPhase: CallPhase { activeLine?.phase ?? .idle }
    var callPeer: String { activeLine?.peer ?? "" }
    var isInCall: Bool { !lines.isEmpty }
    var isOnHold: Bool { activeLine?.isOnHold ?? false }
    var isRemotelyHeld: Bool { activeLine?.isRemotelyHeld ?? false }
    var isMicrophoneMuted: Bool { activeLine?.isMicrophoneMuted ?? false }
    var isRenegotiating: Bool { activeLine?.isRenegotiating ?? false }
    var isTransferring: Bool { lines.contains { $0.isTransferring } }
    var isConferenceCommandSent: Bool { activeLine?.isConferenceCommandSent ?? false }
    var sentDTMF: String { activeLine?.sentDTMF ?? "" }
    var negotiatedCodec: AudioCodec? { activeLine?.negotiatedCodec }
    var audioRoute: AudioRoute? { activeLine?.audioRoute }
    var echoCancellationActive: Bool? { activeLine?.echoCancellationActive }
    var remoteAudioView: RTCPSession.RemoteView? { activeLine?.remoteAudioView }

    private var media: MediaSession? { activeLine?.media }

    /// Окно входящего вызова вместе с защитой. Живёт здесь, а не в сцене:
    /// показывает его приезд INVITE, а не действие пользователя.
    let incomingCallPanel = IncomingCallPanel()
    private let ringtone = Ringtone()

    /// Играет ли рингтон по кнопке «Прослушать» в настройках.
    ///
    /// Отдельно от `ringtone.isPlaying`: тот не публикуется, а кнопке нужно
    /// перерисоваться в «Остановить» сразу.
    @Published private(set) var isRingtonePreviewPlaying = false

    /// Проиграть рингтон в настройках — тем же кодом и в то же устройство, что
    /// и на настоящем входящем.
    ///
    /// В разговоре и на живом входящем не работает: рингтон там занят делом,
    /// и предпрослушивание либо оборвало бы его, либо наложилось поверх.
    func startRingtonePreview() {
        guard !isInCall, incomingCall == nil else { return }
        ringtone.start(
            settings: settings.ringtone,
            outputDeviceUID: settings.audio.outputDeviceUID
        )
        isRingtonePreviewPlaying = ringtone.isPlaying
    }

    func stopRingtonePreview() {
        guard isRingtonePreviewPlaying else { return }
        ringtone.stop()
        isRingtonePreviewPlaying = false
    }

    var canTransfer: Bool {
        callPhase == .active && !isRenegotiating && !isTransferring
    }

    /// Можно ли завести консультационную линию.
    var canConsult: Bool {
        canTransfer && lines.count < SIPUserAgent.maximumLines && consultationLine == nil
    }

    /// Консультация, заведённая для какой-то из линий.
    var consultationLine: CallLine? {
        lines.first { $0.consultsLine != nil }
    }

    /// Готова ли консультация к соединению: обе линии на месте и разговор с
    /// адресатом уже идёт.
    var canCompleteConsultation: Bool {
        guard let consultation = consultationLine,
              consultation.phase == .active,
              let origin = consultation.consultsLine,
              let source = line(origin)
        else { return false }
        return source.phase == .active && !source.isTransferring
    }

    var hasTransferNumber: Bool { !normalizedTransferTarget.isEmpty }

    /// Номер перевода, приведённый к тому же виду, что и набранный.
    ///
    /// Раньше здесь вырезались только пробелы, и это закрывало половину беды:
    /// номер копируют из CRM вместе со скобками и дефисами, а они ломают
    /// разбор Request-URI так же. Правило одно на оба поля — иначе одна и та же
    /// вставка в панель работала бы, а в перевод нет.
    ///
    /// В отличие от набранного, это поле нормализуется при отправке, а не при
    /// вводе: оператор набирает номер перевода на слух под диктовку клиента, и
    /// цифры, исчезающие из-под курсора, сбивают сильнее, чем помогают.
    private var normalizedTransferTarget: String {
        DialedNumber.normalized(transferNumber)
    }

    var canStartConference: Bool {
        callPhase == .active
            && !isTransferring
            && !(activeLine?.isConferenceCommandPending ?? false)
            && !(activeLine?.isConferenceCommandSent ?? false)
            && settings.conference.isUsable
            && (media?.supportsTelephoneEvents ?? false)
    }

    /// Кодеки, которые предлагаем и на которые соглашаемся.
    ///
    /// Одно место на оба направления: разные списки в предложении и в ответе
    /// означали бы, что исходящий и входящий звонки звучат по-разному, а
    /// объяснить это оператору нечем.
    private var preferredCodecs: [AudioCodec] {
        settings.audio.prefersWideband ? SDPNegotiator.defaultCodecs : SDPNegotiator.narrowbandCodecs
    }

    private var mediaSecurityPolicy: MediaSecurityPolicy {
        settings.account.transport == .tls ? .sdesRequired : .none
    }

    // MARK: - Звонок

    func placeCall() async {
        guard canPlaceCall, hasDialedNumber else { return }
        await startOutgoingCall(to: dialedNumber, consultingFor: nil)
    }

    /// Общий путь исходящего звонка: и первого, и консультационного.
    @discardableResult
    private func startOutgoingCall(to number: String, consultingFor origin: String?) async -> Bool {
        guard let agent else { return false }

        // Спрашиваем у агента, а не считаем свои линии: место под линию он
        // занимает у себя, и решать, есть ли оно, тоже ему. Иначе под заведомо
        // отклонённый звонок успевает занять пару портов RTP.
        guard await agent.hasFreeLine else {
            append(level: .warning, message: "все линии заняты — новую не завести")
            callStatus = "Заняты все линии"
            return false
        }

        // Спрашиваем микрофон до набора: разрешение приходит асинхронно, и
        // просить его посреди установленного звонка поздно — в линию уже уйдёт
        // тишина, а причину по звуку не понять.
        guard await VoiceAudioEngine.requestMicrophoneAccess() else {
            append(level: .error, message: "нет доступа к микрофону — разрешите его в настройках системы")
            callStatus = "Нет доступа к микрофону"
            return false
        }

        await claimHeadset()

        guard let address = await agent.mediaAddress else {
            append(level: .error, message: "неизвестен внешний адрес — нечего указать в SDP")
            return false
        }

        let prepared: (
            offer: SessionDescription,
            port: UInt16,
            reservation: RTPPortReservation
        )
        do {
            prepared = try MediaSession.makeOffer(
                localAddress: address,
                codecs: preferredCodecs,
                security: mediaSecurityPolicy
            )
        } catch {
            append(level: .error, message: "не удалось занять порт RTP: \(error.localizedDescription)")
            return false
        }

        let call = await agent.placeCall(to: number, offer: prepared.offer.encodedData)

        lines.append(CallLine(
            id: call.callID,
            isOutgoing: true,
            peer: number,
            phase: .dialing,
            status: "Набор…",
            consultsLine: origin,
            localDescription: prepared.offer
        ))
        activeLineID = call.callID
        callStatus = "Набор…"
        applyAudioOwnership()
        append(level: .info, message: "звоню на \(number), RTP-порт \(prepared.port)")

        // Запись заводится на первом гудке, а не по факту разговора: звонок,
        // на который не ответили, — тоже история, и именно её чаще всего
        // ищут, когда вспоминают «я же ему набирал».
        //
        // SIP-логин исходящего остаётся пустым, и это не упущение. Мы набрали
        // номер; как называется этот extension на стороне FreePBX, из нашей
        // сигнализации не видно вовсе — 200 OK приходит без имени. Заполнит
        // поле синхронизация с EliteDash в M9, а до тех пор пусто честнее.
        beginHistory(
            lineID: call.callID,
            direction: .outgoing,
            number: number,
            role: origin == nil ? .primary : .consultation
        )

        callTasks[call.callID] = Task { [weak self] in
            for await event in call.events {
                await self?.handle(
                    call: event,
                    on: call.callID,
                    offer: prepared.offer,
                    reservation: prepared.reservation
                )
            }
        }
        return true
    }

    /// Кладёт трубку на активной линии.
    func hangUp() async {
        guard let activeLineID else { return }
        await hangUp(lineID: activeLineID)
    }

    func hangUp(lineID: String) async {
        guard let agent, line(lineID) != nil else { return }
        setStatus("Завершение…", on: lineID)
        mutate(lineID) { $0.phase = .ending }
        await agent.hangUp(callID: lineID)
    }

    /// Переключает звук на другую линию.
    ///
    /// Порядок обязателен: сначала активной становится новая линия и звук
    /// переезжает на неё, и только потом уходят оба повторных INVITE. Ждать
    /// ответа сервера, чтобы отдать звук, значит оставить оператора без обеих
    /// линий на время обмена.
    func switchLine(to lineID: String) async {
        guard !isSwitchingLines, lineID != activeLineID, let target = line(lineID) else { return }
        isSwitchingLines = true
        defer { isSwitchingLines = false }

        let previous = activeLineID
        activeLineID = lineID
        callStatus = target.status
        applyAudioOwnership()
        startLevelPolling()

        if let previous, line(previous)?.phase == .active {
            await setHold(true, on: previous)
        }
        if target.phase == .active {
            await setHold(false, on: lineID)
        }
    }

    /// Переключение уже идёт.
    ///
    /// Второе нажатие в этот момент — это два встречных повторных INVITE по
    /// одной линии, то есть 491 и застрявшее удержание. Оператор при быстром
    /// клике по полосе линий получал бы клиента, который остался в музыке
    /// ожидания, хотя на экране «Разговор».
    @Published private(set) var isSwitchingLines = false

    private func handle(
        call event: SIPCallEvent,
        on lineID: String,
        offer: SessionDescription,
        reservation: RTPPortReservation
    ) async {
        switch event {
        case .state(let state):
            switch state {
            case .dialing:
                mutate(lineID) { $0.phase = .dialing }
                setStatus("Набор…", on: lineID)
            case .ringing:
                mutate(lineID) { $0.phase = .ringing }
                setStatus("Гудки", on: lineID)
            case .answered:
                mutate(lineID) { $0.phase = .active }
            case .ending:
                mutate(lineID) { $0.phase = .ending }
                setStatus("Завершение…", on: lineID)
            // Исходящий звонок входящим не бывает: это состояние принадлежит
            // другому потоку событий.
            case .incoming, .ended: break
            }

        case .answered(let body, _):
            startMedia(answerBody: body, offer: offer, reservation: reservation, on: lineID)

        case .failed(_, let reason):
            reservation.release()
            append(level: .info, message: "звонок не состоялся: \(reason)")
            setStatus(reason, on: lineID)
            teardown(lineID: lineID, status: reason)

        case .ended(let reason):
            reservation.release()
            append(level: .info, message: "звонок завершён: \(reason)")
            if let media = line(lineID)?.media {
                append(level: .debug, message: "медиа: \(media.summary)")
            }
            teardown(lineID: lineID, status: line(lineID)?.transferOutcome ?? reason)
        }
    }

    private func startMedia(
        answerBody: Data,
        offer: SessionDescription,
        reservation: RTPPortReservation,
        on lineID: String
    ) {
        do {
            let answer = try SessionDescription(parsing: answerBody)
            let negotiated = try SDPNegotiator.resolveAnswer(
                answer, toOffer: offer, supported: preferredCodecs
            )
            startMedia(negotiated: negotiated, reservation: reservation, on: lineID)
        } catch {
            append(level: .error, message: "медиа не поднялось: \(error.localizedDescription)")
            setStatus("Ошибка звука", on: lineID)
            Task { await hangUp(lineID: lineID) }
        }
    }

    /// Поднимает разговор по уже согласованным параметрам.
    ///
    /// Общая для обоих направлений часть: чем звонок кончился — нашим
    /// предложением или нашим ответом — звуку безразлично.
    private func startMedia(
        negotiated: NegotiatedMedia,
        reservation: RTPPortReservation,
        on lineID: String
    ) {
        do {
            append(
                level: .info,
                message: "медиа: \(negotiated.security.isEncrypted ? "SRTP" : "RTP") \(negotiated.codec.sdpName) на \(negotiated.remoteAddress):\(negotiated.remotePort)"
            )

            let session = try MediaSession(
                negotiated: negotiated,
                reservation: reservation,
                bus: voiceBus(),
                inputDeviceUID: settings.audio.inputDeviceUID,
                outputDeviceUID: settings.audio.outputDeviceUID,
                releasesDeviceWhenIdle: settings.audio.releasesDeviceWhenIdle,
                automaticGainControl: settings.audio.automaticGainControl
            )
            session.onDiagnostic = { [weak self] text in
                Task { @MainActor in self?.append(level: .debug, message: "звук: \(text)") }
            }
            // Что собеседник видит про НАШ поток. Своя статистика на этот
            // вопрос не отвечает: собственный голос мы не слышим, и жалоба
            // «меня плохо слышно» иначе не проверяется ничем.
            session.onRemoteView = { [weak self] view in
                Task { @MainActor in
                    self?.mutate(lineID) { $0.remoteAudioView = view }
                    if view.fractionLost > 0.05 {
                        self?.append(
                            level: .warning,
                            message: "собеседник теряет наш звук: \(view.summary)"
                        )
                    }
                }
            }
            session.onAudioEvent = { [weak self] event in
                Task { @MainActor in self?.handle(audio: event, on: lineID) }
            }
            try session.start()

            // Линия могла уйти, пока поднимался звук: BYE или CANCEL
            // расходится с 200 OK на сети, и `teardown` успевает раньше.
            // Молча выйти нельзя — `mutate` по несуществующей линии не делает
            // ничего, и сессия с открытым микрофоном, включённой обработкой
            // голоса и занятой парой портов осталась бы висеть до выхода из
            // приложения. На Bluetooth-гарнитуре это ещё и режим связи у всей
            // системы.
            guard line(lineID) != nil else {
                append(level: .warning, message: "линия снялась, пока поднимался звук — сессия закрыта")
                retire(session)
                return
            }
            // Прежняя сессия на этой же линии — повторный ответ по одному
            // Call-ID. Заменить её ссылкой значит потерять единственного, кто
            // мог бы её остановить.
            if let previous = line(lineID)?.media, previous !== session {
                append(level: .warning, message: "на линии уже был звук — прежняя сессия закрыта")
                retire(previous)
            }

            mutate(lineID) {
                $0.media = session
                $0.audioRoute = session.route
                $0.echoCancellationActive = session.usesEchoCancellation
                $0.negotiatedCodec = negotiated.codec
                $0.phase = .active
            }
            if !session.usesEchoCancellation {
                append(level: .warning, message: "звук без эхоподавления — через колонки собеседник услышит себя")
            }
            applyAudioOwnership()
            startLevelPolling()
            setStatus("Разговор", on: lineID)
        } catch {
            append(level: .error, message: "медиа не поднялось: \(error.localizedDescription)")
            setStatus("Ошибка звука", on: lineID)
            Task { await hangUp(lineID: lineID) }
        }
    }

    // MARK: - Перевод

    /// Номер, на который переводим текущий разговор. Не переиспользуем
    /// `dialedNumber`: тот остаётся историей исходного набора и DTMF.
    @Published var transferNumber: String = ""
    @Published private(set) var isTransferEntryVisible = false

    /// Зачем открыто поле номера: слепой перевод или консультация.
    enum NumberEntry: Equatable {
        case blindTransfer
        case consultation
    }

    @Published private(set) var numberEntry: NumberEntry = .blindTransfer

    func showTransferEntry() {
        guard canTransfer else { return }
        numberEntry = .blindTransfer
        transferNumber = ""
        isTransferEntryVisible = true
    }

    func showConsultationEntry() {
        guard canConsult else { return }
        numberEntry = .consultation
        transferNumber = ""
        isTransferEntryVisible = true
    }

    func cancelTransferEntry() {
        guard !isTransferring else { return }
        isTransferEntryVisible = false
        transferNumber = ""
    }

    /// Слепой перевод: текущий собеседник сразу уходит на указанный номер.
    ///
    /// Успехом считаем не 202 на REFER, а только финальный NOTIFY с 2xx
    /// созданного сервером INVITE. Иначе кнопка могла бы показать «готово»,
    /// хотя адресат занят или номера не существует.
    func blindTransfer() async {
        guard let agent, canTransfer, hasTransferNumber, let lineID = activeLineID else { return }
        let target = normalizedTransferTarget

        mutate(lineID) { $0.isTransferring = true }
        setStatus("Перевод…", on: lineID)
        append(level: .info, message: "слепой перевод на \(target)")

        let events = await agent.transfer(callID: lineID, to: target)
        await consume(transfer: events, on: lineID, to: target, endsConsultation: nil)
    }

    /// Консультационный звонок: текущий собеседник уходит на удержание, а
    /// оператор набирает того, с кем хочет посоветоваться.
    func startConsultation() async {
        guard canConsult, hasTransferNumber, let origin = activeLineID else { return }
        let target = normalizedTransferTarget

        await setHold(true, on: origin)
        guard line(origin)?.isOnHold == true else {
            // Без удержания консультация означает разговор с двумя сразу:
            // клиент услышит и вопрос коллеге, и ответ.
            append(level: .warning, message: "консультация отменена: удержание не сработало")
            return
        }

        isTransferEntryVisible = false
        transferNumber = ""
        guard await startOutgoingCall(to: target, consultingFor: origin) else {
            await setHold(false, on: origin)
            return
        }
        append(level: .info, message: "консультация с \(target), клиент на удержании")
    }

    /// Соединяет собеседников после консультации: REFER с Replaces по исходной
    /// линии, ссылающийся на консультационный диалог.
    func completeConsultation() async {
        guard let agent,
              canCompleteConsultation,
              let consultation = consultationLine,
              let origin = consultation.consultsLine
        else { return }

        guard let replaces = await agent.dialogIdentifier(of: consultation.id) else {
            append(level: .error, message: "консультационный диалог ещё не установлен")
            return
        }

        mutate(origin) { $0.isTransferring = true }
        setStatus("Соединение…", on: origin, echo: true)
        append(level: .info, message: "консультационный перевод на \(consultation.peer)")

        let events = await agent.transfer(
            callID: origin,
            to: consultation.peer,
            replacing: replaces
        )
        await consume(
            transfer: events,
            on: origin,
            to: consultation.peer,
            endsConsultation: consultation.id
        )
    }

    /// Отменяет консультацию: коллега получает отбой, клиент возвращается.
    ///
    /// Возвращает клиента не эта кнопка, а общий разбор конца линии: та же
    /// дорога отрабатывает и когда коллега бросил трубку первым.
    func cancelConsultation() async {
        guard let consultation = consultationLine else { return }
        await hangUp(lineID: consultation.id)
    }

    /// Общий разбор хода перевода. Слепой и консультационный отличаются только
    /// тем, надо ли после успеха класть трубку на второй линии.
    private func consume(
        transfer events: AsyncStream<SIPTransferEvent>,
        on lineID: String,
        to target: String,
        endsConsultation consultationID: String?
    ) async {
        let echo = consultationID != nil

        for await event in events {
            switch event {
            case .accepted:
                setStatus("Сервер переводит…", on: lineID, echo: echo)

            case .succeeded:
                append(level: .info, message: "разговор переведён на \(target)")
                let outcome = "Переведён на \(target)"
                mutate(lineID) {
                    $0.isTransferring = false
                    $0.transferOutcome = outcome
                }
                // Подтверждение помечает обе ноги: какая из них завершится
                // последней, заранее неизвестно, а обычное «завершён» стёрло бы
                // единственный ответ оператору на нажатие «Соединить».
                if let consultationID {
                    mutate(consultationID) { $0.transferOutcome = outcome }
                }
                setStatus(outcome, on: lineID, echo: echo)
                isTransferEntryVisible = false
                transferNumber = ""
                // После успешного REFER обе наши ноги больше не нужны. Если
                // Asterisk уже прислал BYE, hangUp станет безопасным no-op.
                //
                // Исходная линия кладётся первой: она в этот момент на
                // удержании, и её конец не поднимет разбор «оператор остался с
                // линией» — иначе консультационная получила бы повторный INVITE
                // на снятие удержания одновременно с собственным BYE.
                await hangUp(lineID: lineID)
                if let consultationID { await hangUp(lineID: consultationID) }
                return

            case .failed(_, let reason):
                // Причину показываем в строке состояния, а не только в журнале:
                // журнала на панели нет, и «не удался» без «занято» не говорит
                // оператору, звонить ли ему снова.
                append(level: .error, message: "перевод не удался: \(reason)")
                mutate(lineID) { $0.isTransferring = false }
                // «Не переведён» говорим только там, где говорить есть кому:
                // разговор уцелел и оператор решает, звонить ли снова. Если же
                // подписку закрыл конец самого разговора — а BYE от Asterisk
                // может обогнать финальный NOTIFY, — судьба перевода нам
                // неизвестна, и объявлять отказ было бы неправдой. На экране в
                // этом случае остаётся причина окончания звонка.
                if line(lineID)?.phase == .active {
                    setStatus("Не переведён: \(reason)", on: lineID)
                }
                return
            }
        }

        // Поток закончился, не назвав исхода. Оставлять «Перевод…» нельзя:
        // разговор при этом никуда не делся.
        mutate(lineID) { $0.isTransferring = false }
        if let line = line(lineID), line.phase == .active {
            setStatus(line.isOnHold ? "На удержании" : "Разговор", on: lineID)
        }
    }

    // MARK: - Конференция

    /// Отправляет серверный feature-code, который переводит оба плеча
    /// текущего разговора в одну комнату ConfBridge.
    ///
    /// Подтвердить вход отдельным SIP-событием Asterisk 13 не умеет: dynamic
    /// feature выполняется внутри Dial. Поэтому состояние называется именно
    /// «команда отправлена», а не «конференция установлена».
    func startConference() {
        guard let lineID = activeLineID, let media, canStartConference else { return }
        let command = settings.conference.command
        let timing = settings.dtmf.timing

        mutate(lineID) { $0.isConferenceCommandPending = true }
        setStatus("Отправка команды конференции…", on: lineID)

        Task { [weak self, weak media] in
            guard let self, let media else { return }
            let sent = await media.sendAndWait(dtmf: command, timing: timing)

            // Завершившаяся линия уже сброшена; результат её старой очереди не
            // должен изменить состояние другой.
            guard let line = self.line(lineID), line.media === media, line.phase == .active else { return }
            self.mutate(lineID) { $0.isConferenceCommandPending = false }

            guard sent else {
                self.setStatus("Конференция недоступна", on: lineID)
                self.append(
                    level: .warning,
                    message: "конференция: DTMF-команда не вышла в RTP"
                )
                return
            }

            self.mutate(lineID) {
                $0.sentDTMF += command.displayText
                $0.isConferenceCommandSent = true
            }
            self.setStatus("Команда конференции отправлена", on: lineID)
            self.append(
                level: .info,
                message: "конференция: отправлен серверный код \(command.displayText)"
            )
        }
    }

    // MARK: - Удержание

    var canHold: Bool { callPhase == .active && !isRenegotiating }

    func toggleHold() async {
        guard let activeLineID else { return }
        await setHold(!isOnHold, on: activeLineID)
    }

    /// Ставит линию на удержание и снимает с него.
    ///
    /// Отдельной команды в SIP для этого нет: удержание — это повторный INVITE
    /// со сменой направления в SDP. Отказ на него разговор не рвёт (RFC 3261
    /// §14.1), поэтому неудача здесь означает «удержание не сработало», а не
    /// «звонок потерян», и обрабатывается соответственно.
    func setHold(_ hold: Bool, on lineID: String) async {
        guard let agent, let line = line(lineID), line.phase == .active, !line.isRenegotiating else { return }
        guard line.isOnHold != hold else { return }
        guard let media = line.media, let local = line.localDescription else {
            append(level: .error, message: "нет своего описания медиа — удержание собрать не из чего")
            return
        }

        mutate(lineID) { $0.isRenegotiating = true }
        defer { mutate(lineID) { $0.isRenegotiating = false } }

        let reoffer = SDPNegotiator.makeReoffer(from: local, direction: hold ? .sendonly : .sendrecv)
        setStatus(hold ? "Удержание…" : "Возврат…", on: lineID)

        do {
            let answerBody = try await agent.reinvite(callID: lineID, offer: reoffer.encodedData)
            mutate(lineID) {
                $0.localDescription = reoffer
                $0.isOnHold = hold
            }

            // Ответ без тела законен: сервер согласился, не меняя ничего.
            if !answerBody.isEmpty {
                let negotiated = try SDPNegotiator.resolveAnswer(
                    try SessionDescription(parsing: answerBody),
                    toOffer: reoffer,
                    supported: preferredCodecs
                )
                let outcome = try media.renegotiate(to: negotiated)
                if outcome == .streamRebuilt {
                    append(level: .info, message: "медиа переехало на \(negotiated.remoteAddress):\(negotiated.remotePort)")
                }
            }

            applyAudioState(on: lineID)
            setStatus(hold ? "На удержании" : "Разговор", on: lineID)
            append(level: .info, message: hold ? "разговор на удержании" : "возврат с удержания")
        } catch {
            // Разговор продолжается на прежних параметрах — и это надо сказать
            // вслух, иначе оператор решит, что собеседник его не слышит.
            append(level: .error, message: "удержание не удалось: \(describe(error))")
            applyAudioState(on: lineID)
            setStatus(line.isOnHold ? "На удержании" : "Разговор", on: lineID)
        }
    }

    func toggleMicrophone() {
        guard let lineID = activeLineID, callPhase == .active else { return }
        mutate(lineID) { $0.isMicrophoneMuted.toggle() }
        applyAudioState(on: lineID)
        append(level: .info, message: isMicrophoneMuted ? "микрофон выключен" : "микрофон включён")
    }

    /// Раздаёт звуковую карту активной линии и отбирает у остальных.
    ///
    /// Микрофон, выход и обработка голоса у оператора одни, а разговоров до
    /// трёх. Порядок обязателен: сначала фоновые линии отпускают устройство,
    /// и только потом активная его берёт — иначе два `VoiceProcessingIO`
    /// одновременно делят одно устройство, а на Bluetooth-гарнитуре она
    /// остаётся в режиме двусторонней связи.
    private func applyAudioOwnership() {
        for line in lines where line.id != activeLineID {
            line.media?.suspendAudio()
        }
        // Условие «а не запущена ли она уже» убрано намеренно: с общим трактом
        // судить об этом линия должна по владению, а не по своему флагу, и
        // решает это `resumeAudio()`. Иначе линия, у которой тракт отобрала
        // ответившая консультация, считала бы себя звучащей и молчала.
        if let activeLineID, let media = line(activeLineID)?.media {
            do {
                try media.resumeAudio()
            } catch {
                // Сигнализация при этом цела: разговор идёт, а звука нет. Молчать
                // об этом нельзя — оператор будет говорить в пустоту и решит,
                // что собеседник его игнорирует.
                append(level: .error, message: "звук не вернулся на линию: \(describe(error))")
                setStatus("Звук не вернулся", on: activeLineID)
            }
        }
        for line in lines { applyAudioState(on: line.id) }
    }

    /// Сводит все причины молчать в одно состояние звука.
    ///
    /// Причин четыре, и они складываются: линия не активна, своё удержание,
    /// серверное удержание и кнопка микрофона. Раскладывать это по месту каждый
    /// раз — верный способ получить разговор, в котором микрофон остался
    /// выключенным после возврата.
    private func applyAudioState(on lineID: String) {
        guard let line = line(lineID), let media = line.media else { return }
        let isBackground = line.id != activeLineID
        media.isMicrophoneMuted = isBackground
            || line.isOnHold
            || line.isRemotelyHeld
            || line.isMicrophoneMuted
        // Музыку ожидания, которую включил сервер, оператор слышать должен:
        // по ней и понятно, что его поставили на удержание. А вот собственное
        // удержание глушит приём — оператор в это время говорит с другим.
        media.isReceivingAudio = !isBackground && !line.isOnHold
    }

    /// Собирает ответ на чужой повторный INVITE.
    ///
    /// Возврат nil означает 488: предложение не подходит. Так бывает, когда
    /// сервер сменил кодек посреди разговора — пересобрать под него весь тракт
    /// на ходу нельзя, а сделать вид, что всё в порядке, значит получить тишину.
    private func renegotiateMedia(on lineID: String, offer body: Data) async -> Data? {
        guard let agent, let line = line(lineID), let media = line.media else { return nil }
        guard let address = await agent.mediaAddress else {
            append(level: .error, message: "неизвестен внешний адрес — пересогласовать нечем")
            return nil
        }

        do {
            let offer = try SessionDescription(parsing: body)

            // Правило TLS-профиля работает и здесь: молчаливый откат на
            // открытый RTP посреди разговора — та же дыра, что и в начале.
            if mediaSecurityPolicy == .sdesRequired,
               offer.audio?.protocolName.caseInsensitiveCompare("RTP/SAVP") != .orderedSame {
                append(level: .error, message: "пересогласование без SRTP на защищённом профиле отклонено")
                return nil
            }

            let negotiated = try SDPNegotiator.makeAnswer(
                to: offer,
                address: address,
                port: media.localPort,
                supported: preferredCodecs,
                // Ключ повторяем прежний: выпустить новый ради удержания
                // значит пересобрать поток со сменой SSRC — то есть услышать
                // разрыв там, где ничего не менялось.
                localKey: media.negotiated?.security.localKey
            )
            let outcome = try media.renegotiate(to: negotiated.media)

            mutate(lineID) {
                $0.localDescription = negotiated.answer
                $0.isRemotelyHeld = negotiated.media.isHeld
            }
            applyAudioState(on: lineID)

            if negotiated.media.isHeld {
                setStatus("Вас поставили на удержание", on: lineID)
                append(level: .info, message: "собеседник поставил разговор на удержание")
            } else {
                setStatus(line.isOnHold ? "На удержании" : "Разговор", on: lineID)
                append(level: .info, message: "собеседник вернулся к разговору")
            }
            if outcome == .streamRebuilt {
                append(
                    level: .info,
                    message: "медиа переехало на \(negotiated.media.remoteAddress):\(negotiated.media.remotePort)"
                )
            }

            return negotiated.answer.encodedData
        } catch {
            append(level: .error, message: "пересогласование отклонено: \(describe(error))")
            return nil
        }
    }

    // MARK: - DTMF

    /// Умеет ли текущий разговор принимать тоны.
    var canSendDTMF: Bool { callPhase == .active && (media?.supportsTelephoneEvents ?? false) }

    /// Отправляет одну цифру.
    @discardableResult
    func sendDTMF(_ character: Character) -> Bool {
        guard let lineID = activeLineID, let media, callPhase == .active else { return false }
        guard media.send(dtmf: character, timing: settings.dtmf.timing) else {
            // Молча проглотить нельзя: оператор будет думать, что попал в меню,
            // а на той стороне не произошло ничего.
            append(level: .warning, message: "собеседник не подтвердил telephone-event — тоны отправить нечем")
            setStatus("DTMF не поддерживается", on: lineID)
            return false
        }
        mutate(lineID) { $0.sentDTMF.append(character) }
        return true
    }

    /// Отправляет макрос целиком.
    func send(macro: AppSettings.DTMFSettings.Macro) {
        guard let lineID = activeLineID, let media, callPhase == .active else { return }
        let sequence = settings.dtmf.sequence(of: macro)
        guard sequence.hasTones else {
            append(level: .warning, message: "макрос «\(macro.title)» пуст")
            return
        }
        guard media.send(dtmf: sequence, timing: settings.dtmf.timing) else {
            append(level: .warning, message: "собеседник не подтвердил telephone-event — макрос не отправлен")
            setStatus("DTMF не поддерживается", on: lineID)
            return
        }
        mutate(lineID) { $0.sentDTMF += sequence.displayText }
        append(level: .info, message: "макрос «\(macro.title)»: \(sequence.displayText)")
    }

    /// Макросы, годные к отправке.
    var usableMacros: [AppSettings.DTMFSettings.Macro] {
        settings.dtmf.macros.filter(\.isUsable)
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case let error as SIPRenegotiationError: error.description
        case let error as SDPNegotiationError: error.description
        case let error as MediaSession.SessionError: error.description
        default: error.localizedDescription
        }
    }

    /// Общий аудиотракт приложения.
    ///
    /// Один на все линии и на самопроверку: микрофон, выход и обработка голоса
    /// у оператора одни. Заводится лениво и живёт до выхода — движок, который
    /// не деаллоцируется, не может быть разобран под руками у собственного
    /// слушателя свойств, и именно это чинит падение 6 августа 2026.
    ///
    /// Пересоздать его нельзя даже при отказе: пока хоть одна линия помнит
    /// ключ владения, подмена объекта означала бы, что её остановка уходит в
    /// пустоту, а звук остаётся захваченным.
    func voiceBus() throws -> VoiceAudioBus {
        if let sharedVoiceBus { return sharedVoiceBus }
        let bus = try VoiceAudioBus()
        sharedVoiceBus = bus
        return bus
    }

    /// Просит систему перевести звук на беспроводную гарнитуру.
    ///
    /// То, чего клиенту не хватало: FaceTime и другие софтфоны в начале
    /// разговора переключают устройство на AirPods, а мы брали то, что стоит
    /// системным по умолчанию. Само открытие устройства гарнитуру не забирает —
    /// если она слушает iPhone, там и останется.
    ///
    /// Зовётся до подъёма медиа и никого не задерживает: к моменту, когда
    /// придёт 200 OK и начнётся сборка тракта, арбитраж давно закончился, а
    /// секунду ожидания в худшем случае оператор проводит, слушая гудки.
    ///
    /// Не зовётся, когда оба устройства выбраны в настройках явно. Арбитраж
    /// меняет системное умолчание, то есть звук всей машины: оператору, который
    /// сознательно посадил софтфон на USB-гарнитуру, переключение системы на
    /// AirPods — сюрприз, и не его. Когда хоть одна сторона отдана системе,
    /// спрашивать её же, какое устройство лучше, — ровно то, чего от настройки
    /// «системное по умолчанию» и ждут.
    private func claimHeadset() async {
        guard settings.audio.inputDeviceUID == nil || settings.audio.outputDeviceUID == nil else {
            return
        }
        guard let bus = try? voiceBus() else { return }

        let outcome = await bus.beginArbitration()
        // Молчим о самом обычном исходе: гарнитуры рядом нет либо она и так
        // наша. Журнал разговора не место для строки, которая всегда одинакова.
        guard outcome.defaultDeviceChanged || outcome.error != nil || outcome.timedOut else {
            return
        }
        append(level: outcome.error == nil ? .info : .warning, message: "звук: \(outcome.summary)")
    }

    /// Снимает медиа-сессию с линии.
    ///
    /// Отдельным методом, потому что дорог не сам вызов, а то, что его легко не
    /// сделать: сессия, потерянная без остановки, уносит с собой открытый
    /// микрофон, включённую обработку голоса и пару портов.
    ///
    /// Здесь была отсрочка освобождения на секунду — заплатка от падения
    /// 6 августа 2026, когда `AVAudioEngine` разбирался в том же витке, в
    /// котором наша же остановка поставила уведомления на очередь
    /// `AVAudioIOUnit`. Отсрочка снята вместе с причиной: тракт теперь общий и
    /// не деаллоцируется вовсе (`VoiceAudioBus`), а держать снятую сессию
    /// лишнюю секунду стало вредно — звонок, начатый сразу после отбоя, попадал
    /// бы на разбор её узла.
    private func retire(_ media: MediaSession?) {
        media?.stop()
    }

    /// Убирает линию и, если она была последней, всё общее состояние звонка.
    private func teardown(lineID: String, status: String) {
        callTasks.removeValue(forKey: lineID)?.cancel()
        retire(line(lineID)?.media)

        // История закрывается здесь, потому что здесь снимается линия, — и
        // ровно той причиной, которую увидит оператор. Расхождение между
        // подписью под кнопкой и строкой в истории означало бы, что верить
        // будут памяти, а не записи.
        finishHistory(lineID: lineID, reason: status)

        let wasActive = lineID == activeLineID
        lines.removeAll { $0.id == lineID }

        // Консультация без исходной линии консультацией быть перестаёт.
        for index in lines.indices where lines[index].consultsLine == lineID {
            lines[index].consultsLine = nil
        }

        // Причину окончания в строку состояния пишет только та линия, которую
        // оператор слушал. Фоновая линия, положившая трубку, не имеет права
        // затереть «Разговор» у активной: подпись под кнопкой относится к тому,
        // с кем оператор говорит сейчас.
        if wasActive || lines.isEmpty {
            callStatus = status
        }
        append(level: .debug, message: "линия \(lineID) снята: \(status)")

        if wasActive {
            activeLineID = nil
            levelTask?.cancel()
            levelTask = nil
            audioLevels.reset()
        }

        if lines.isEmpty {
            ringtone.stop()
            incomingCallPanel.hide()
            logGuardReport()
            incomingCall = nil
            isTransferEntryVisible = false
            transferNumber = ""
            numberEntry = .blindTransfer
            return
        }

        guard wasActive, let next = lines.first else { return }

        // Оператор остался с линией на удержании — а на ней ждёт живой человек.
        // Возвращать его туда должен клиент, а не память оператора.
        activeLineID = next.id
        callStatus = next.status
        applyAudioOwnership()
        startLevelPolling()
        let nextID = next.id
        Task { [weak self] in
            guard let self, !isSwitchingLines else { return }
            isSwitchingLines = true
            defer { isSwitchingLines = false }
            await setHold(false, on: nextID)
        }
    }

    /// Снимает все линии разом — при отключении от сервера.
    private func teardownAllLines() {
        for line in lines {
            callTasks.removeValue(forKey: line.id)?.cancel()
            retire(line.media)
            // Отключение от сервера рвёт разговор, и назвать это как-то иначе
            // нельзя: линия снимается не потому, что собеседник положил трубку.
            finishHistory(lineID: line.id, reason: "Отключение от сервера")
        }
        callTasks.values.forEach { $0.cancel() }
        callTasks.removeAll()
        lines.removeAll()
        activeLineID = nil
        ringtone.stop()
        incomingCallPanel.hide()
        logGuardReport()
        incomingCall = nil
        isTransferEntryVisible = false
        transferNumber = ""
        numberEntry = .blindTransfer
        levelTask?.cancel()
        levelTask = nil
        audioLevels.reset()
    }

    // MARK: - Входящий звонок

    @Published private(set) var incomingCall: SIPIncomingCall?

    /// Отчёт защиты по последнему входящему. Нужен вкладке диагностики и в M8
    /// уедет в EliteDash целиком.
    @Published private(set) var lastGuardReport: CallGuardReport?

    private func handle(incoming call: SIPIncomingCall) {
        // Занятому оператору агент отвечает 486 ещё до события: раздача лидов
        // должна отдать вызов следующему агенту. Проверка здесь — на случай
        // рассогласования, а не на нормальный ход.
        guard lines.isEmpty else { return }

        incomingCall = call
        lines.append(CallLine(
            id: call.callID,
            isOutgoing: false,
            peer: call.displayNumber,
            displayName: call.callerName,
            phase: .incoming,
            status: "Входящий"
        ))
        activeLineID = call.callID
        callStatus = "Входящий"
        didLogGuardReport = false

        // Номер и SIP-логин пишутся как пришли, без нормализации — решение
        // 30 июля 2026. Оба берутся из From, и сегодня они совпадают: FreePBX
        // кладёт техническое имя extension в тот же user-part, что и номер.
        // Хранятся всё равно порознь — в M9 CDR различает эти две вещи, и
        // тогда колонка уже будет нужного вида, а не заведена задним числом.
        //
        // Имя из From идёт третьим полем, а не поверх номера: в M9 его
        // переопределит EliteDash, и исходное обязано остаться — пересчитать
        // псевдоним заново потом будет не из чего.
        beginHistory(
            lineID: call.callID,
            direction: .incoming,
            number: call.callerNumber,
            sipLogin: call.callerNumber.isEmpty ? nil : call.callerNumber,
            displayName: call.callerName
        )

        if !settings.incomingCall.isEnabled {
            // Выключить защиту можно, скрыть факт — нет. В M8 эта же запись
            // уедет в EliteDash с отметкой времени.
            append(level: .warning, message: "защита от автокликеров выключена на этом вызове")
        }

        // Предпрослушивание держит тот же движок, и `Ringtone.start` на занятом
        // движке молча ничего не делает — то есть настоящий входящий пришёл бы
        // беззвучно. Настройки в этот момент вполне могут быть открыты.
        stopRingtonePreview()
        // Самопроверка держит микрофон и наушники; входящий важнее.
        cancelVoiceSelfTest()

        ringtone.start(
            settings: settings.ringtone,
            outputDeviceUID: settings.audio.outputDeviceUID
        )

        incomingCallPanel.show(
            callerNumber: call.displayNumber,
            callerName: call.callerName,
            policy: settings.incomingCall,
            onAnswer: { [weak self] in
                Task { await self?.answerIncomingCall() }
            },
            onDecline: { [weak self] in
                Task { await self?.declineIncomingCall() }
            }
        )

        callTasks[call.callID] = Task { [weak self] in
            for await event in call.events {
                self?.handle(incomingEvent: event, on: call.callID)
            }
        }
    }

    private func handle(incomingEvent event: SIPCallEvent, on lineID: String) {
        switch event {
        case .state(let state):
            switch state {
            case .incoming:
                mutate(lineID) { $0.phase = .incoming }
                setStatus("Входящий", on: lineID)
            case .answered:
                mutate(lineID) { $0.phase = .active }
            case .ending:
                mutate(lineID) { $0.phase = .ending }
                setStatus("Завершение…", on: lineID)
            case .dialing, .ringing, .ended: break
            }

        case .answered:
            // Для входящего звонка ответ — это наш собственный 200 OK, и медиа
            // поднимается там же, где он отправляется.
            break

        case .failed(_, let reason):
            append(level: .info, message: "входящий не состоялся: \(reason)")
            teardown(lineID: lineID, status: reason)

        case .ended(let reason):
            append(level: .info, message: "входящий завершён: \(reason)")
            if let media = line(lineID)?.media {
                append(level: .debug, message: "медиа: \(media.summary)")
            }
            teardown(lineID: lineID, status: line(lineID)?.transferOutcome ?? reason)
        }
    }

    /// Принимает вызов: SDP-ответ, 200 OK и сразу звук.
    ///
    /// Порядок обязателен именно такой. Микрофон спрашивается до 200 OK: если
    /// разрешение придёт после, в линию уйдёт тишина, а по звуку причину не
    /// понять. И наоборот, медиа поднимается сразу после 200 OK, не дожидаясь
    /// ACK: Asterisk начинает слать RTP по 200-му.
    private func answerIncomingCall() async {
        guard let agent, let call = incomingCall, callPhase == .incoming else { return }
        let lineID = call.callID

        ringtone.stop()
        setStatus("Соединение…", on: lineID)

        guard await VoiceAudioEngine.requestMicrophoneAccess() else {
            append(level: .error, message: "нет доступа к микрофону — вызов отклонён")
            setStatus("Нет доступа к микрофону", on: lineID)
            await agent.rejectIncomingCall(callID: lineID, status: 486)
            return
        }

        await claimHeadset()

        guard let address = await agent.mediaAddress else {
            append(level: .error, message: "неизвестен внешний адрес — нечего указать в SDP")
            await agent.rejectIncomingCall(callID: lineID, status: 500)
            return
        }

        let prepared: (
            answer: SessionDescription,
            media: NegotiatedMedia,
            port: UInt16,
            reservation: RTPPortReservation
        )
        do {
            prepared = try MediaSession.makeAnswer(
                to: try SessionDescription(parsing: call.offer),
                localAddress: address,
                codecs: preferredCodecs,
                security: mediaSecurityPolicy
            )
        } catch {
            // 488 — это «предложение не подходит», ровно наш случай: нет общего
            // кодека или сервер не предложил SRTP на защищённом профиле.
            append(level: .error, message: "не удалось ответить на предложение: \(error.localizedDescription)")
            setStatus("Несовместимое медиа", on: lineID)
            await agent.rejectIncomingCall(callID: lineID, status: 488)
            return
        }

        append(
            level: .info,
            message: "принимаю вызов от \(call.displayNumber), RTP-порт \(prepared.port)"
        )

        // Медиа поднимается ДО 200 OK, а не после.
        //
        // `makeAnswer` порт только примеряет — открывает сокет и тут же
        // закрывает, — поэтому до `startMedia` на нём никто не слушает.
        // Asterisk начинает слать RTP по 200 OK, и в зазоре между ответом и
        // подъёмом тракта первые кадры уходят в закрытый порт, а сам порт в это
        // время может занять кто угодно ещё.
        mutate(lineID) { $0.localDescription = prepared.answer }
        startMedia(negotiated: prepared.media, reservation: prepared.reservation, on: lineID)
        guard line(lineID)?.media != nil else { return }

        guard await agent.answerIncomingCall(
            callID: lineID,
            answer: prepared.answer.encodedData
        ) else {
            append(level: .warning, message: "ответить не удалось: вызова уже нет")
            teardown(lineID: lineID, status: "вызова уже нет")
            return
        }

        logGuardReport()
    }

    private func declineIncomingCall() async {
        guard let agent, let lineID = activeLineID, callPhase == .incoming else { return }
        ringtone.stop()
        setStatus("Отклонение…", on: lineID)
        await agent.rejectIncomingCall(callID: lineID, status: 486)
    }

    /// Писали ли уже отчёт по текущему вызову.
    ///
    /// Флаг, а не сравнение с прошлым отчётом: два подряд одинаково отклонённых
    /// вызова дают одинаковые отчёты, и сравнение проглотило бы второй.
    private var didLogGuardReport = false

    /// Пишет отчёт защиты в журнал ровно один раз за вызов.
    private func logGuardReport() {
        guard !didLogGuardReport, let report = incomingCallPanel.lastReport else { return }
        didLogGuardReport = true
        lastGuardReport = report
        append(
            level: report.looksAutomated ? .warning : .info,
            message: "защита: \(report.summary)"
        )
    }


    // MARK: - Аудиотракт

    // Маршрут, эхоподавление, кодек и отчёт собеседника — свойства линии, а не
    // приложения: линий до трёх, и у каждой свой поток. Наружу отдаётся
    // активная (см. раздел «Линии»).

    /// Уровни для индикатора: микрофон и приём, от 0 до 1.
    /// Уровни живут отдельно — см. `AudioLevels`: они меняются двадцать раз в
    /// секунду, а `ObservableObject` не различает, какое свойство изменилось.
    let audioLevels = AudioLevels()

    private var levelTask: Task<Void, Never>?

    /// Опрос уровней для индикатора.
    ///
    /// Опрос, а не поток событий: индикатор рисуется двадцать раз в секунду, а
    /// кадры приходят пятьдесят, и гнать через главный поток вдвое больше
    /// обновлений, чем видно глазу, незачем.
    private func startLevelPolling() {
        levelTask?.cancel()
        streamWatch = InboundStreamWatch()
        lastStreamState = .flowing
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(.milliseconds(50))
                guard let self, let media else { return }
                audioLevels.update(input: media.inputLevel, output: media.outputLevel)
                reportInboundStream(of: media)
            }
        }
    }

    private var streamWatch = InboundStreamWatch()
    private var lastStreamState = InboundStreamWatch.State.flowing

    /// Говорит вслух, когда от собеседника не идёт поток.
    ///
    /// Разговор без единого принятого пакета снаружи неотличим от сломанного
    /// звука: в трубке тишина. Разница при этом принципиальная — чинить надо
    /// разные вещи, — и молчать о ней значит каждый раз начинать разбор с
    /// неверных гипотез. Ровно это и случилось на стенде 3 августа: 29 секунд
    /// разговора, принято ноль пакетов, и узнать об этом можно было только из
    /// сводки после звонка.
    ///
    /// Сообщение выводится на смене состояния, а не на каждом опросе: опрос идёт
    /// двадцать раз в секунду, и журнал был бы залит одинаковыми строками.
    private func reportInboundStream(of media: MediaSession) {
        guard let lineID = activeLineID else { return }
        let state = streamWatch.update(received: media.statistics.received)
        guard state != lastStreamState else { return }
        let previous = lastStreamState
        lastStreamState = state

        switch state {
        case .neverStarted(let seconds):
            append(
                level: .warning,
                message: "от собеседника не пришло ни одного пакета за \(Int(seconds)) с"
                    + " — звук в трубке будет молчать, и дело не в устройстве"
            )
            setStatus("Нет потока от собеседника", on: lineID)

        case .stalled(let seconds):
            append(level: .warning, message: "поток от собеседника прервался \(Int(seconds)) с назад")
            setStatus("Поток прервался", on: lineID)

        case .flowing:
            guard previous != .flowing else { return }
            append(level: .info, message: "поток от собеседника пошёл")
            if let line = line(lineID), Self.streamWarningStatuses.contains(line.status) {
                setStatus(line.isOnHold ? "На удержании" : "Разговор", on: lineID)
            }
        }
    }

    /// Подписи, которые ставит наблюдение за потоком. Снимает их оно же, и
    /// список нужен затем, чтобы не затереть чужую подпись — например
    /// «Восстанавливаю звук…» от пересборки тракта.
    private static let streamWarningStatuses: Set<String> = [
        "Нет потока от собеседника", "Поток прервался",
    ]

    /// Гарнитура в двустороннем режиме: у всей системы приглушён звук, и
    /// пользователю стоит про это сказать, пока он не решил, что сломались мы.
    var isHeadsetModeActive: Bool { audioRoute?.isHeadsetMode ?? false }

    /// Подпись линии, пока тракт пересобирается после неудачи. Вынесена в
    /// константу, потому что её ставит один обработчик, а снимает другой:
    /// разъехавшиеся строки означали бы надпись, которая никогда не гаснет.
    static let audioRecoveringStatus = "Восстанавливаю звук…"

    private func handle(audio event: VoiceAudioEngine.Event, on lineID: String) {
        switch event {
        case .routeChanged(let route):
            mutate(lineID) { $0.audioRoute = route }
            append(level: .info, message: "звук: \(route.summary)")

        case .restarted(let reason):
            // Пересборка занимает около сотой доли секунды и слышна как
            // короткий провал. Сообщение нужно затем, чтобы жалобу «звук
            // дёрнулся» можно было связать с подключением наушников.
            append(level: .info, message: "звук: тракт пересобран (\(reason))")
            // Если до этого была серия попыток, на линии висит «Восстанавливаю
            // звук…». Снять её обязательно: надпись, которая осталась после
            // того, как всё починилось, врёт ровно так же, как её отсутствие
            // во время поломки.
            if let line = line(lineID), line.status == Self.audioRecoveringStatus {
                setStatus(line.isOnHold ? "На удержании" : "Разговор", on: lineID)
            }

        case .restarting(let reason, let attempt):
            // Трубку НЕ вешаем. Перевод AirPods на телефон и обратно снимает
            // устройство на несколько секунд, и разговор это переживает — а
            // раньше не переживал: любая неудачная пересборка означала обрыв.
            // Оператору надо сказать, что происходит, иначе несколько секунд
            // тишины он прочтёт как «связь пропала» и положит трубку сам.
            append(level: .warning, message: "звук восстанавливается (попытка \(attempt)): \(reason)")
            setStatus(Self.audioRecoveringStatus, on: lineID)

        case .broken(let reason):
            // Попытки исчерпаны. Звука больше не будет, а молчащий разговор
            // хуже, чем завершённый: оператор будет говорить в пустоту, а лид —
            // слушать тишину.
            append(level: .error, message: "звук пропал: \(reason)")
            setStatus("Звук пропал", on: lineID)
            Task { [weak self] in await self?.hangUp(lineID: lineID) }
        }
    }

    /// Микрофоны, доступные для выбора.
    var inputDevices: [AudioDevice] {
        AudioDeviceCatalog.devices()
            .filter(\.isInput)
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// Устройства вывода, доступные для выбора.
    var outputDevices: [AudioDevice] {
        AudioDeviceCatalog.devices()
            .filter(\.isOutput)
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    // MARK: - Набор номера

    /// Кнопка «Позвонить» заводит первую линию. Вторая и третья заводятся
    /// только консультацией: набирать вслепую поверх идущего разговора — это
    /// клиент, который слышит чужой набор.
    var canPlaceCall: Bool {
        registration.isRegistered && lines.isEmpty
    }

    /// Есть ли что набирать. Один плюс номером не считается: он признак
    /// формата, а не адрес.
    var hasDialedNumber: Bool { DialedNumber.isDialable(dialedNumber) }

    /// Нажатие на клавиатуру. В разговоре это тон, вне разговора — цифра номера.
    ///
    /// Одна кнопка на оба смысла — то, как устроен любой телефон: набирать
    /// номер во время разговора незачем, а вот попасть в голосовое меню нужно
    /// ровно теми же клавишами.
    func press(_ digit: Character) {
        if callPhase == .active {
            sendDTMF(digit)
        } else {
            append(digit)
        }
    }

    /// Что показывать в поле номера: набранное или уже отправленные тоны.
    var displayedNumber: String {
        callPhase == .active && !sentDTMF.isEmpty ? sentDTMF : dialedNumber
    }

    func append(_ digit: Character) {
        // Ни длину, ни допустимость символа здесь не проверяем: и то и другое
        // делает `didSet` самого поля, и правило одно на ввод с клавиатуры,
        // вставку из буфера и перезвон из истории.
        dialedNumber.append(digit)
    }

    func removeLastDigit() {
        guard !dialedNumber.isEmpty else { return }
        dialedNumber.removeLast()
    }

    func clearDialedNumber() {
        dialedNumber.removeAll()
    }

    // MARK: - Лог

    /// Не `private`: административный режим и самопроверка звука живут в
    /// расширениях соседними файлами, и своего пути в журнал у них быть не
    /// должно — иначе однажды появится вторая запись, которая не попадает в
    /// файл и не маскируется.
    func append(level: SIPLogLevel, message: String) {
        // В файл — до фильтра экрана и по своему уровню. Иначе «покажите
        // поменьше» на панели молча обрезало бы и то, ради чего журнал заводили.
        if let logFile, level >= settings.logFile.minimumLevel {
            logFile.write(message, level: level.rawValue)
        }

        #if DEBUG
        // Журнал приложения живёт только во вкладке «Диагностика», и при
        // запуске из скрипта его негде посмотреть. Флаг зеркалит его в stderr.
        if ProcessInfo.processInfo.arguments.contains("--log-to-stderr") {
            FileHandle.standardError.write(Data("[\(level.rawValue)] \(message)\n".utf8))
        }
        #endif

        guard level >= settings.minimumLogLevel else { return }
        log.append(LogEntry(date: Date(), level: level, message: message))
        if log.count > Self.logCapacity {
            log.removeFirst(log.count - Self.logCapacity)
        }
    }

    func clearLog() {
        log.removeAll()
    }

    var logText: String {
        log.map { entry in
            let time = TimeText.withSeconds.string(from: entry.date)
            return "\(time) [\(entry.level.rawValue)] \(entry.message)"
        }
        .joined(separator: "\n")
    }

    // MARK: - Настройки

    /// Пока открыто окно «Управление», на диск не пишется ничего.
    ///
    /// Правки живут в памяти и откатываются по «Отменить». Иначе «сохранения на
    /// горячую нет» было бы неправдой: наблюдатель `settings` пишет файл на
    /// каждое движение ползунка, и передумать после этого было бы уже нечем.
    func persistSettings() {
        guard !isHoldingSettingsWrites else { return }
        do {
            try SettingsStore.save(settings)
        } catch {
            append(level: .error, message: "не удалось сохранить настройки: \(error.localizedDescription)")
        }
    }

    func applyLabPreset(_ preset: AppSettings.LabPreset) {
        guard canSwitchProfile else {
            refuseProfileChange()
            return
        }
        settings.profiles.upsert(
            preset.account,
            label: preset.label,
            site: preset.site,
            acceptsAnyTLSCertificate: preset.acceptsAnyTLSCertificate
        )
        settings.minimumLogLevel = preset.minimumLogLevel
        append(level: .info, message: "применены настройки лаборатории: \(preset.account.username)")
    }

    // MARK: - Профили

    var profiles: [SIPProfile] { settings.profiles.profiles }

    var activeProfileID: UUID { settings.profiles.activeID }

    /// Менять профиль в разговоре нельзя — по той же причине, по которой в M6b
    /// запрещено отключение: смена профиля снимает регистрацию и закрывает
    /// диалоги. Кнопка стоит в настройках, а трубка от этого кладётся так же.
    var canSwitchProfile: Bool { lines.isEmpty }

    private func refuseProfileChange() {
        append(level: .warning, message: "смена профиля недоступна: идёт разговор")
        callStatus = "Сначала завершите разговор"
    }

    /// Делает профиль активным: снимает регистрацию со старого и, если у нового
    /// есть пароль, поднимает её заново.
    ///
    /// Молча оставаться отключённым нельзя — оператор нажал на профиль, а не на
    /// «Отключить», — но и подключиться без пароля не получится. Поэтому второй
    /// случай проговаривается вслух, и говорится он про настройку профиля:
    /// вписывать пароль оператору нечем и незачем.
    func selectProfile(_ id: UUID) async {
        guard id != settings.profiles.activeID else { return }
        guard settings.profiles[id] != nil else { return }
        guard canSwitchProfile else {
            refuseProfileChange()
            return
        }

        let wasConnected = agent != nil
        if wasConnected { await disconnect() }

        settings.profiles.activate(id)
        append(level: .info, message: "профиль: \(profileTitle(id))")

        guard wasConnected else { return }
        if !settings.sipPassword.isEmpty {
            await connect()
        } else {
            append(level: .warning, message: "у профиля не задан пароль — подключение не восстановлено")
            callStatus = "Профиль без пароля"
        }
    }

    /// Добавляет пустой профиль и делает его активным: заполнять его всё равно
    /// сразу же. Сервер и транспорт наследуются от текущего — обычно добавляют
    /// второй добавочный на той же АТС.
    func addProfile() {
        guard canSwitchProfile else {
            refuseProfileChange()
            return
        }
        // Рабочее место наследуется от текущего профиля: второй добавочный
        // заводят с того же места, что и первый. Доверие к сертификату — нет,
        // у него безопасное умолчание.
        settings.profiles.add(
            SIPProfile.blank(basedOn: settings.account, site: settings.profiles.active.site)
        )
        append(level: .info, message: "добавлен профиль")
    }

    /// Удаляет профиль вместе с его паролем.
    ///
    /// Пароль уходит с профилем сам: он его поле. Отдельной проверки «не делит
    /// ли эту запись кто-то ещё» больше нет — делить стало нечего.
    func removeProfile(_ id: UUID) async {
        let isActive = id == settings.profiles.activeID
        if isActive {
            guard canSwitchProfile else {
                refuseProfileChange()
                return
            }
            if agent != nil { await disconnect() }
        }

        guard settings.profiles[id] != nil else { return }
        settings.profiles.remove(id)
        append(level: .info, message: "профиль удалён вместе с паролем")
    }

    /// Метка пишется как введена, без подрезки пробелов: подрезать на каждом
    /// нажатии — значит не дать набрать метку из двух слов.
    func renameProfile(_ id: UUID, to label: String) {
        settings.profiles.rename(id, to: label)
    }

    /// Офисное это рабочее место или удалённое.
    ///
    /// Это не пометка, а переезд: вместе с рабочим местом меняется адрес АТС —
    /// изнутри `192.168.1.2`, снаружи внешний домен. Одно без другого
    /// бессмысленно, потому что из дома внутренний адрес недостижим, а из
    /// офиса внешний ведёт на тот же сервер длинной дорогой. Отсюда всё
    /// остальное: перерегистрация и стук перед первой регистрацией снаружи.
    ///
    /// Адрес переписывается только у профиля, который смотрит на нашу пару
    /// адресов: лабораторный `127.0.0.1` и чужую АТС трогать нельзя — пометка
    /// не должна незаметно уводить профиль на другой сервер. Такой профиль
    /// получает только пометку, и об этом сказано в журнале.
    func setProfileSite(_ site: SIPProfileSite, for id: UUID) async {
        guard let profile = settings.profiles[id], profile.site != site else { return }
        // Переезд снимает регистрацию, значит запрет тот же, что у смены
        // профиля и у отключения из M6b.
        guard canSwitchProfile else {
            refuseProfileChange()
            return
        }

        let addresses = settings.siteAddresses
        let currentHost = profile.account.domain
        let newHost = addresses.host(for: site)
        let movesAddress =
            !addresses.isEmpty && addresses.recognizes(currentHost) && newHost != nil
            && newHost != currentHost

        // Перерегистрация нужна ровно из-за адреса: пометка сама по себе решает
        // только, стучать ли перед следующим подключением, и рвать ради неё
        // живую регистрацию незачем. Профилю, которому адрес не переписывают
        // (лаборатория, чужая АТС), достаётся стук на следующем подключении —
        // или кнопка «Исправить сеть», если ждать нельзя.
        let wasConnected = agent != nil
        if movesAddress && wasConnected { await disconnect() }

        settings.profiles.setSite(site, for: id)

        if movesAddress, let newHost {
            // Пароль переносить больше не нужно: он поле профиля и переезжает
            // вместе с ним. Раньше он лежал в связке ключей под «номер@домен»,
            // и смена домена оставляла профиль без пароля.
            var moved = settings.profiles[id]?.account
            moved?.domain = newHost
            if let moved, settings.profiles.setAccount(moved, for: id) {
                append(
                    level: .info,
                    message: "профиль \(profileTitle(id)): \(site.title), адрес АТС \(currentHost) → \(newHost)"
                )
            }
        } else {
            append(
                level: .info,
                message: "профиль \(profileTitle(id)): \(site.title)"
                    + (addresses.recognizes(currentHost) ? "" : ", адрес \(currentHost) оставлен как есть")
            )
        }

        guard wasConnected, movesAddress else { return }
        if !settings.sipPassword.isEmpty {
            await connect()
        } else {
            append(level: .warning, message: "у профиля не задан пароль — подключение не восстановлено")
            callStatus = "Профиль без пароля"
        }
    }

    /// «Исправить сеть»: стук по портам один раз, прямо сейчас.
    ///
    /// Существует на случай, когда доступ потерян не по нашей логике: сменился
    /// публичный адрес, шлюз забыл прежний, а приложение считает себя
    /// подключённым. Пропуск по времени здесь не действует — повод тот же, что
    /// у повтора после отказа, и пропускать его нельзя.
    ///
    /// Стучим независимо от пометки рабочего места: кнопку нажимают тогда, когда
    /// что-то уже не работает, и спорить с человеком в этот момент неуместно.
    func repairNetwork() async {
        guard !settings.portKnock.isEmpty else {
            networkRepairStatus = "Стук выключен в настройках"
            return
        }
        let host = settings.account.signalingEndpoint.host
        let log: PortKnocker.Log = { [weak self] level, message in
            Task { @MainActor in self?.append(level: level, message: message) }
        }
        guard let knocker = PortKnocker.forServer(
            host,
            site: .remote,
            sequence: settings.portKnock,
            log: log
        ) else {
            networkRepairStatus = "Стучать некуда"
            return
        }

        networkRepairStatus = "Открываем дорогу до \(host)…"
        append(level: .info, message: "«Исправить сеть»: стук по требованию, адрес \(host)")
        await knocker.openPath(reason: .retry)
        // Успех здесь недоказуем: правило срабатывает на исходящий пакет, а
        // ответа может не быть вовсе. Единственная настоящая проверка — это
        // прошедшая следом регистрация, и её делает не эта кнопка.
        networkRepairStatus = "Готово. Если не помогло — переподключитесь"
    }

    /// Подпись профиля для списка и журнала.
    func profileTitle(_ id: UUID) -> String {
        guard let profile = settings.profiles[id] else { return "профиль" }
        return profile.title.isEmpty ? "новый профиль" : profile.title
    }
}
