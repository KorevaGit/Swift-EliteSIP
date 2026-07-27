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
        hasStoredPassword = storedPassword != nil
    }

    // MARK: - Учётная запись

    private var keychainKey: String {
        KeychainStore.key(for: settings.account.username, domain: settings.account.domain)
    }

    /// Двойная развёртка: `try?` над функцией, возвращающей `String?`, даёт
    /// `String??` — «ошибки не было» и «записи не было» здесь разные случаи.
    private var storedPassword: String? {
        (try? KeychainStore.password(for: keychainKey)) ?? nil
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

    // MARK: - Набор номера

    /// Звонить пока некуда: медиа и исходящий INVITE появляются в M2.
    var canPlaceCall: Bool { false }

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
