import CallGuard
import MediaCore
import Observation
import SIPCore
import SwiftUI

/// Состояние приложения и владелец SIP-агента.
///
/// Единственный @Observable, на который смотрят вьюхи. Агент — actor, поэтому
/// вся связь с ним асинхронная, а состояние сюда приезжает потоком событий.
@MainActor
@Observable
final class AppModel {

    struct LogEntry: Identifiable, Sendable {
        let id = UUID()
        let date: Date
        let level: SIPLogLevel
        let message: String
    }

    /// Сколько строк лога держим в памяти. Больше не нужно: подробная история
    /// поедет в файл в M7, а здесь она только для быстрой диагностики.
    private static let logCapacity = 500

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            persistSettings()
        }
    }

    /// Пароль, введённый в настройках. Хранится в Keychain, здесь живёт только
    /// до нажатия «Сохранить» и обратно из Keychain не читается.
    var passwordDraft: String = ""

    private(set) var registration: SIPRegistrationState = .idle
    private(set) var hasStoredPassword = false
    private(set) var log: [LogEntry] = []

    var dialedNumber: String = ""

    private var agent: SIPUserAgent?
    private var eventPump: Task<Void, Never>?

    init() {
        settings = SettingsStore.load()
        hasStoredPassword = loadStoredPassword(quiet: true) != nil
    }

    // MARK: - Учётная запись

    private var keychainKey: String {
        KeychainStore.key(for: settings.account.username, domain: settings.account.domain)
    }

    /// Пароль из Keychain.
    ///
    /// Ошибку не глушим: «записи нет» и «Keychain отказал» — совершенно разные
    /// случаи, а выглядят одинаково. Отказ случается буднично: подпись
    /// приложения меняется при каждой пересборке, и macOS спрашивает
    /// разрешение на доступ к записи, созданной прежней сборкой. Без этого
    /// сообщения такая ситуация выглядит как «пароль не задан», и пользователь
    /// вводит его заново вместо того, чтобы нажать «Разрешить».
    private func loadStoredPassword(quiet: Bool = false) -> String? {
        do {
            return try KeychainStore.password(for: keychainKey)
        } catch {
            if !quiet {
                append(level: .error, message: "Keychain не отдал пароль: \(error.localizedDescription)")
            }
            return nil
        }
    }

    private var storedPassword: String? {
        loadStoredPassword()
    }

    var isConnected: Bool { registration.isRegistered }

    var isBusy: Bool {
        switch registration {
        case .registering, .unregistering: true
        default: false
        }
    }

    var canConnect: Bool {
        settings.account.isUsable && (hasStoredPassword || !passwordDraft.isEmpty) && agent == nil
    }

    var registrationTitle: String {
        switch registration {
        case .idle: "Не подключено"
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
            "до \(expiresAt.formatted(date: .omitted, time: .shortened))"
        case .failed(_, let retryAt):
            retryAt.map { "повтор в \($0.formatted(date: .omitted, time: .shortened))" }
        default:
            nil
        }
    }

    func savePassword() {
        do {
            try KeychainStore.save(password: passwordDraft, for: keychainKey)
            hasStoredPassword = !passwordDraft.isEmpty
            passwordDraft = ""
            append(level: .info, message: hasStoredPassword ? "пароль сохранён в Keychain" : "пароль удалён")
        } catch {
            append(level: .error, message: "не удалось сохранить пароль: \(error.localizedDescription)")
        }
    }

    func forgetPassword() {
        try? KeychainStore.delete(for: keychainKey)
        hasStoredPassword = false
        passwordDraft = ""
        append(level: .info, message: "пароль удалён из Keychain")
    }

    // MARK: - Подключение

    func connect() async {
        guard agent == nil else { return }

        let account = settings.account
        guard account.isUsable else {
            append(level: .error, message: "не заданы номер или домен")
            return
        }

        // Черновик пароля имеет приоритет: пользователь мог только что его
        // ввести и нажать «Подключить», не нажимая «Сохранить».
        let password: String
        if !passwordDraft.isEmpty {
            password = passwordDraft
        } else if let stored = storedPassword {
            password = stored
        } else {
            append(level: .error, message: "пароль не задан")
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

        let agent = SIPUserAgent(
            account: account,
            credentials: DigestAuthentication.Credentials(
                username: account.effectiveAuthUsername,
                password: password
            ),
            channel: channel
        )
        self.agent = agent

        append(
            level: .info,
            message: "подключение к \(account.signalingEndpoint) по \(account.transport.protocolName)"
        )

        // Разрешение на микрофон спрашиваем заранее, при выходе на линию.
        //
        // Иначе системный диалог впервые появляется под звонок: окно входящего
        // уже скрыто, оператор считает, что принял лид, а мы вместо ответа
        // показываем ему запрос доступа. Здесь же он всплывает в спокойный
        // момент и больше не мешает никогда.
        Task { _ = await VoiceAudioEngine.requestMicrophoneAccess() }

        let events = agent.events
        eventPump = Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
        }

        await agent.start()
    }

    func disconnect() async {
        guard let agent else { return }
        self.agent = nil
        await agent.stop()
        eventPump?.cancel()
        eventPump = nil
        registration = .idle
        append(level: .info, message: "отключено")
    }

    func reconnect() async {
        await disconnect()
        await connect()
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

    // MARK: - Звонок

    enum CallPhase: Equatable {
        case idle
        case dialing
        case ringing
        /// Нам звонят, окно на экране, решение за оператором.
        case incoming
        case active
        case ending
    }

    private(set) var callPhase: CallPhase = .idle
    private(set) var callStatus: String = ""
    private(set) var callPeer: String = ""

    /// Окно входящего вызова вместе с защитой. Живёт здесь, а не в сцене:
    /// показывает его приезд INVITE, а не действие пользователя.
    let incomingCallPanel = IncomingCallPanel()
    private let ringtone = Ringtone()

    private var media: MediaSession?
    private var callTask: Task<Void, Never>?

    var isInCall: Bool { callPhase != .idle }

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

    func placeCall() async {
        guard let agent, canPlaceCall, hasDialedNumber else { return }

        // Спрашиваем микрофон до набора: разрешение приходит асинхронно, и
        // просить его посреди установленного звонка поздно — в линию уже уйдёт
        // тишина, а причину по звуку не понять.
        guard await VoiceAudioEngine.requestMicrophoneAccess() else {
            append(level: .error, message: "нет доступа к микрофону — разрешите его в настройках системы")
            callStatus = "Нет доступа к микрофону"
            return
        }

        guard let address = await agent.mediaAddress else {
            append(level: .error, message: "неизвестен внешний адрес — нечего указать в SDP")
            return
        }

        let prepared: (offer: SessionDescription, port: UInt16)
        do {
            prepared = try MediaSession.makeOffer(
                localAddress: address,
                codecs: preferredCodecs,
                security: mediaSecurityPolicy
            )
        } catch {
            append(level: .error, message: "не удалось занять порт RTP: \(error.localizedDescription)")
            return
        }

        let number = dialedNumber
        callPeer = number
        callPhase = .dialing
        callStatus = "Набор…"
        append(level: .info, message: "звоню на \(number), RTP-порт \(prepared.port)")

        let events = await agent.placeCall(to: number, offer: prepared.offer.encodedData)
        callTask = Task { [weak self] in
            for await event in events {
                await self?.handle(call: event, offer: prepared.offer, localPort: prepared.port)
            }
        }
    }

    func hangUp() async {
        guard let agent, isInCall else { return }
        callPhase = .ending
        callStatus = "Завершение…"
        await agent.hangUp()
    }

    private func handle(call event: SIPCallEvent, offer: SessionDescription, localPort: UInt16) async {
        switch event {
        case .state(let state):
            switch state {
            case .dialing: callPhase = .dialing; callStatus = "Набор…"
            case .ringing: callPhase = .ringing; callStatus = "Гудки"
            case .answered: callPhase = .active
            case .ending: callPhase = .ending; callStatus = "Завершение…"
            // Исходящий звонок входящим не бывает: это состояние принадлежит
            // другому потоку событий.
            case .incoming, .ended: break
            }

        case .answered(let body, _):
            startMedia(answerBody: body, offer: offer, localPort: localPort)

        case .failed(_, let reason):
            append(level: .info, message: "звонок не состоялся: \(reason)")
            callStatus = reason
            teardownCall()

        case .ended(let reason):
            append(level: .info, message: "звонок завершён: \(reason)")
            if let media {
                append(level: .debug, message: "медиа: \(media.summary)")
            }
            callStatus = reason
            teardownCall()
        }
    }

    private func startMedia(answerBody: Data, offer: SessionDescription, localPort: UInt16) {
        do {
            let answer = try SessionDescription(parsing: answerBody)
            let negotiated = try SDPNegotiator.resolveAnswer(
                answer, toOffer: offer, supported: preferredCodecs
            )
            startMedia(negotiated: negotiated, localPort: localPort)
        } catch {
            append(level: .error, message: "медиа не поднялось: \(error.localizedDescription)")
            callStatus = "Ошибка звука"
            Task { await hangUp() }
        }
    }

    /// Поднимает разговор по уже согласованным параметрам.
    ///
    /// Общая для обоих направлений часть: чем звонок кончился — нашим
    /// предложением или нашим ответом — звуку безразлично.
    private func startMedia(negotiated: NegotiatedMedia, localPort: UInt16) {
        do {
            append(
                level: .info,
                message: "медиа: \(negotiated.security.isEncrypted ? "SRTP" : "RTP") \(negotiated.codec.sdpName) на \(negotiated.remoteAddress):\(negotiated.remotePort)"
            )

            let session = try MediaSession(
                negotiated: negotiated,
                localPort: localPort,
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
                    self?.remoteAudioView = view
                    if view.fractionLost > 0.05 {
                        self?.append(
                            level: .warning,
                            message: "собеседник теряет наш звук: \(view.summary)"
                        )
                    }
                }
            }
            session.onAudioEvent = { [weak self] event in
                Task { @MainActor in self?.handle(audio: event) }
            }
            try session.start()
            media = session
            audioRoute = session.route
            negotiatedCodec = negotiated.codec
            startLevelPolling()

            callPhase = .active
            callStatus = "Разговор"
        } catch {
            append(level: .error, message: "медиа не поднялось: \(error.localizedDescription)")
            callStatus = "Ошибка звука"
            Task { await hangUp() }
        }
    }

    private func teardownCall() {
        callTask?.cancel()
        callTask = nil
        ringtone.stop()
        incomingCallPanel.hide()
        logGuardReport()
        incomingCall = nil
        media?.stop()
        media = nil
        callPhase = .idle
        callPeer = ""
        audioRoute = nil
        negotiatedCodec = nil
        remoteAudioView = nil
        levelTask?.cancel()
        levelTask = nil
        inputLevel = 0
        outputLevel = 0
    }

    // MARK: - Входящий звонок

    private(set) var incomingCall: SIPIncomingCall?

    /// Отчёт защиты по последнему входящему. Нужен вкладке диагностики и в M8
    /// уедет в EliteDash целиком.
    private(set) var lastGuardReport: CallGuardReport?

    private func handle(incoming call: SIPIncomingCall) {
        // Линию агент держит сам и второй вызов отклоняет 486 ещё до события.
        // Проверка здесь — на случай рассогласования, а не на нормальный ход.
        guard callPhase == .idle else { return }

        incomingCall = call
        callPhase = .incoming
        callPeer = call.displayNumber
        callStatus = "Входящий"
        didLogGuardReport = false

        if !settings.incomingCall.isEnabled {
            // Выключить защиту можно, скрыть факт — нет. В M8 эта же запись
            // уедет в EliteDash с отметкой времени.
            append(level: .warning, message: "защита от автокликеров выключена на этом вызове")
        }

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

        callTask = Task { [weak self] in
            for await event in call.events {
                self?.handle(incomingEvent: event)
            }
        }
    }

    private func handle(incomingEvent event: SIPCallEvent) {
        switch event {
        case .state(let state):
            switch state {
            case .incoming: callPhase = .incoming; callStatus = "Входящий"
            case .answered: callPhase = .active
            case .ending: callPhase = .ending; callStatus = "Завершение…"
            case .dialing, .ringing, .ended: break
            }

        case .answered:
            // Для входящего звонка ответ — это наш собственный 200 OK, и медиа
            // поднимается там же, где он отправляется.
            break

        case .failed(_, let reason):
            append(level: .info, message: "входящий не состоялся: \(reason)")
            callStatus = reason
            teardownCall()

        case .ended(let reason):
            append(level: .info, message: "входящий завершён: \(reason)")
            if let media {
                append(level: .debug, message: "медиа: \(media.summary)")
            }
            callStatus = reason
            teardownCall()
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

        ringtone.stop()
        callStatus = "Соединение…"

        guard await VoiceAudioEngine.requestMicrophoneAccess() else {
            append(level: .error, message: "нет доступа к микрофону — вызов отклонён")
            callStatus = "Нет доступа к микрофону"
            await agent.rejectIncomingCall(status: 486)
            return
        }

        guard let address = await agent.mediaAddress else {
            append(level: .error, message: "неизвестен внешний адрес — нечего указать в SDP")
            await agent.rejectIncomingCall(status: 500)
            return
        }

        let prepared: (answer: SessionDescription, media: NegotiatedMedia, port: UInt16)
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
            callStatus = "Несовместимое медиа"
            await agent.rejectIncomingCall(status: 488)
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
        startMedia(negotiated: prepared.media, localPort: prepared.port)
        guard media != nil else { return }

        guard await agent.answerIncomingCall(answer: prepared.answer.encodedData) else {
            append(level: .warning, message: "ответить не удалось: вызова уже нет")
            teardownCall()
            return
        }

        logGuardReport()
    }

    private func declineIncomingCall() async {
        guard let agent, callPhase == .incoming else { return }
        ringtone.stop()
        callStatus = "Отклонение…"
        await agent.rejectIncomingCall(status: 486)
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

    /// Куда идёт звук текущего разговора. nil вне звонка.
    private(set) var audioRoute: AudioRoute?

    /// Кодек, о котором договорились. nil вне звонка.
    private(set) var negotiatedCodec: AudioCodec?

    /// Что собеседник сообщает про наш поток по RTCP. Обновляется раз в пять
    /// секунд, пока идёт разговор.
    private(set) var remoteAudioView: RTCPSession.RemoteView?

    /// Уровни для индикатора: микрофон и приём, от 0 до 1.
    private(set) var inputLevel: Float = 0
    private(set) var outputLevel: Float = 0

    private var levelTask: Task<Void, Never>?

    /// Опрос уровней для индикатора.
    ///
    /// Опрос, а не поток событий: индикатор рисуется двадцать раз в секунду, а
    /// кадры приходят пятьдесят, и гнать через главный поток вдвое больше
    /// обновлений, чем видно глазу, незачем.
    private func startLevelPolling() {
        levelTask?.cancel()
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let media else { return }
                inputLevel = media.inputLevel
                outputLevel = media.outputLevel
            }
        }
    }

    /// Гарнитура в двустороннем режиме: у всей системы приглушён звук, и
    /// пользователю стоит про это сказать, пока он не решил, что сломались мы.
    var isHeadsetModeActive: Bool { audioRoute?.isHeadsetMode ?? false }

    private func handle(audio event: VoiceAudioEngine.Event) {
        switch event {
        case .routeChanged(let route):
            audioRoute = route
            append(level: .info, message: "звук: \(route.summary)")

        case .restarted(let reason):
            // Пересборка занимает около сотой доли секунды и слышна как
            // короткий провал. Сообщение нужно затем, чтобы жалобу «звук
            // дёрнулся» можно было связать с подключением наушников.
            append(level: .info, message: "звук: тракт пересобран (\(reason))")

        case .broken(let reason):
            // Звука больше нет, и молчащий разговор хуже, чем завершённый:
            // оператор будет говорить в пустоту, а лид — слушать тишину.
            append(level: .error, message: "звук пропал: \(reason)")
            callStatus = "Звук пропал"
            Task { await hangUp() }
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

    var canPlaceCall: Bool {
        registration.isRegistered && callPhase == .idle
    }

    var hasDialedNumber: Bool { !dialedNumber.isEmpty }

    func append(_ digit: Character) {
        guard dialedNumber.count < 32 else { return }
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

    private func append(level: SIPLogLevel, message: String) {
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
            let time = entry.date.formatted(date: .omitted, time: .standard)
            return "\(time) [\(entry.level.rawValue)] \(entry.message)"
        }
        .joined(separator: "\n")
    }

    // MARK: - Настройки

    private func persistSettings() {
        do {
            try SettingsStore.save(settings)
        } catch {
            append(level: .error, message: "не удалось сохранить настройки: \(error.localizedDescription)")
        }
    }

    func applyLabPreset(_ preset: AppSettings) {
        settings = preset
        hasStoredPassword = storedPassword != nil
        append(level: .info, message: "применены настройки лаборатории: \(preset.account.username)")
    }
}
