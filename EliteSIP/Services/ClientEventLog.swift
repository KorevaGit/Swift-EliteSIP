import Diagnostics
import Foundation

/// Журнал машины для Spark: регистрация, звонки и критические ошибки.
///
/// Не путать с журналом приложения: тот подробный и живёт на машине, этот —
/// десяток строк в час, которые администратор видит в карточке места в Spark.
/// События копятся в файле рядом с настройками и раз в пять минут уходят
/// пачкой на сервер обновлений (`POST /logs`), откуда их забирает Spark.
/// Номеров телефонов здесь нет намеренно: журнал читает не только тот, кому
/// положено видеть историю звонков.
@MainActor
final class ClientEventLog {

    static let shared = ClientEventLog()

    enum Kind: String, Codable { case registration, call, config, error }
    enum Level: String, Codable { case info, warning, error }

    struct Event: Codable, Equatable {
        var ts: String
        var kind: Kind
        var level: Level
        var message: String
        var line: String?
        var sip_code: Int?
        var direction: String?
        var duration_s: Int?
    }

    /// Сколько событий держим, пока сервер недоступен. Старые вытесняются.
    static let capacity = 1000
    static let sendInterval: TimeInterval = 5 * 60
    /// Событие уходит через несколько секунд, а не с общим тактом: тот, кто
    /// смотрит журнал в Spark, проверяет то, что только что сделал. Пауза
    /// собирает в одну пачку то, что идёт подряд, — снятие и новую регистрацию.
    static let flushDelay: TimeInterval = 10
    /// Одинаковая ошибка чаще раза в минуту — шум, а не новое событие.
    static let errorRepeatWindow: TimeInterval = 60

    private(set) var pending: [Event] = []
    private var settings: (() -> AppSettings)?
    private var timer: Timer?
    private var flushTask: Task<Void, Never>?
    private var sending = false
    private var lastErrors: [String: Date] = [:]
    private var calls: [String: (direction: String, answeredAt: Date?)] = [:]
    private var wasRegistered = false
    private let fileURL: URL?
    private let now: () -> Date

    init(fileURL: URL? = ClientEventLog.defaultFileURL, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Event].self, from: data) {
            pending = saved
        }
    }

    nonisolated static var defaultFileURL: URL? {
        SettingsStore.fileURL.deletingLastPathComponent().appendingPathComponent("client-events.json")
    }

    func start(settings: @escaping () -> AppSettings) {
        self.settings = settings
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.sendInterval, repeats: true) { _ in
            Task { @MainActor in ClientEventLog.shared.send() }
        }
        // Накопленное до запуска (или пока сервер был недоступен) — не ждать такта.
        if !pending.isEmpty { scheduleFlush() }
    }

    // MARK: - События

    func noteRegistration(_ state: SIPRegistrationStateSummary) {
        switch state {
        case .registered:
            guard !wasRegistered else { return }
            wasRegistered = true
            record(.registration, .info, "Регистрация на АТС прошла")
        case .failed(let reason, let code):
            wasRegistered = false
            record(.registration, .error, "Регистрация не прошла: \(reason)", sipCode: code)
        case .unregistered(let byOperator):
            guard wasRegistered else { return }
            wasRegistered = false
            if byOperator {
                record(.registration, .info, "Оператор отключился от АТС")
            } else {
                record(.registration, .warning, "Снята регистрация на АТС")
            }
        }
    }

    func callStarted(lineID: String, incoming: Bool) {
        calls[lineID] = (incoming ? "in" : "out", nil)
    }

    func callAnswered(lineID: String) {
        calls[lineID]?.answeredAt = now()
    }

    func callFinished(lineID: String, reason: String, failed: Bool) {
        guard let call = calls.removeValue(forKey: lineID) else { return }
        let title = call.direction == "in" ? "Входящий звонок" : "Исходящий звонок"
        if let answered = call.answeredAt {
            record(.call, .info, "\(title) завершён", direction: call.direction,
                   duration: max(0, Int(now().timeIntervalSince(answered))))
        } else {
            record(.call, failed ? .warning : .info, "\(title) без ответа: \(reason)",
                   direction: call.direction)
        }
    }

    func noteError(_ message: String) {
        let at = now()
        if let last = lastErrors[message], at.timeIntervalSince(last) < Self.errorRepeatWindow { return }
        lastErrors[message] = at
        if lastErrors.count > 100 {
            lastErrors = lastErrors.filter { at.timeIntervalSince($0.value) < Self.errorRepeatWindow }
        }
        record(.error, .error, message)
    }

    func record(_ kind: Kind, _ level: Level, _ message: String,
                sipCode: Int? = nil, direction: String? = nil, duration: Int? = nil) {
        let text = String(LogRedaction.redact(message).prefix(500))
        pending.append(Event(
            ts: ISO8601DateFormatter().string(from: now()), kind: kind, level: level,
            message: text, line: settings?().profiles.active.title,
            sip_code: sipCode, direction: direction, duration_s: duration))
        if pending.count > Self.capacity {
            pending.removeFirst(pending.count - Self.capacity)
        }
        persist()
        scheduleFlush()
    }

    // MARK: - Отправка

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.flushDelay * 1_000_000_000))
            guard let self else { return }
            self.flushTask = nil
            self.send()
        }
    }

    func send() {
        guard !sending, !pending.isEmpty, let settings else { return }
        let panel = settings().panel
        guard panel.hasChannelKey, !panel.installationID.isEmpty,
              let url = Provisioning.secrets?.updates?.logsURL
        else { return }
        let batch = Array(pending.prefix(500))
        var request = MachineService.machineRequest(url: url, panel: panel)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "app_version": PairService.appVersion,
            "events": batch.compactMap { try? JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) },
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        sending = true
        let sent = batch.count
        // Не async-вариант: он есть только с macOS 12, а клиент живёт и на Catalina.
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode
            Task { @MainActor in ClientEventLog.shared.didSend(count: sent, status: status) }
        }.resume()
    }

    private func didSend(count: Int, status: Int?) {
        sending = false
        defer { if !pending.isEmpty, status == 204 { scheduleFlush() } }
        // 204 — пачка принята. 400 — её не примут никогда, держать незачем.
        // Остальное (сеть, 429, 5xx) — попробуем в следующий раз.
        if status == 204 || status == 400 {
            pending.removeFirst(min(count, pending.count))
            persist()
        }
    }

    private func persist() {
        guard let fileURL else { return }
        try? JSONEncoder().encode(pending).write(to: fileURL, options: .atomic)
    }
}

/// Регистрация, сведённая к тому, что попадает в журнал машины.
enum SIPRegistrationStateSummary: Equatable {
    case registered
    case failed(reason: String, code: Int?)
    /// byOperator — оператор сам ушёл с линии, а не АТС или сеть его сняли.
    case unregistered(byOperator: Bool)
}
