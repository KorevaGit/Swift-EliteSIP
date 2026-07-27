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

        case .unsupportedRequest(let method):
            append(level: .info, message: "запрос \(method.rawValue) отклонён: ещё не поддерживается")
        }
    }

    // MARK: - Звонок

    enum CallPhase: Equatable {
        case idle
        case dialing
        case ringing
        case active
        case ending
    }

    private(set) var callPhase: CallPhase = .idle
    private(set) var callStatus: String = ""
    private(set) var callPeer: String = ""

    private var media: MediaSession?
    private var callTask: Task<Void, Never>?

    var isInCall: Bool { callPhase != .idle }

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
            prepared = try MediaSession.makeOffer(localAddress: address)
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
            case .ended: break
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
            let negotiated = try SDPNegotiator.resolveAnswer(answer, toOffer: offer)

            append(
                level: .info,
                message: "медиа: \(negotiated.codec.sdpName) на \(negotiated.remoteAddress):\(negotiated.remotePort)"
            )

            let session = try MediaSession(negotiated: negotiated, localPort: localPort)
            try session.start()
            media = session

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
        media?.stop()
        media = nil
        callPhase = .idle
        callPeer = ""
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
