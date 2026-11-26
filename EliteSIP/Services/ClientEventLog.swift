import Diagnostics
import Foundation
import SIPCore

/// Журнал машины для Spark: регистрация, звонки, подключение и критические ошибки.
///
/// Не путать с журналом приложения: тот подробный и живёт на машине, этот —
/// десяток строк в час, которые администратор видит в карточке места в Spark.
/// События копятся в файле рядом с настройками и раз в пять минут уходят
/// пачкой на сервер обновлений (`POST /logs`), откуда их забирает Spark.
///
/// С Windows-клиентом 1.0.2 события звонка несут номер и имя собеседника
/// (`peer_number`, `peer_name`) — по запросу поддержки, из той же записи, что
/// история. Spark принимает их с миграции 0063 и показывает только тем, кому
/// положено видеть историю звонков.
@MainActor
final class ClientEventLog {

    static let shared = ClientEventLog()

    enum Kind: String, Codable { case registration, call, config, error, connection, update }
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
        var peer_number: String?
        var peer_name: String?
        /// Входящий-раздача. Только `true` или нет поля: по нему Spark собирает
        /// пойманные имена раздач для вкладки «Очереди».
        var distribution: Bool?
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
    /// Не даёт App Nap усыпить ожидание отправки. Оператор нажимает
    /// «Отключён» и уходит в браузер — окно скрыто, и без этого десять секунд
    /// растягивались до его возвращения в приложение (16 октября 2026: событие
    /// 08:51:45 ушло в 08:53:30).
    private var activity: NSObjectProtocol?
    /// Пауза перед повтором после неудачной отправки; растёт до такта.
    private var retryDelay: TimeInterval = 0

    /// Больше событий в пачке сервер не примет (`maxLogEvents`).
    static let maxBatchEvents = 500
    /// Предел пачки по объёму — с запасом под сервер (`maxLogBatch`, 256 КБ).
    ///
    /// Счёта событий мало: сообщение до 500 знаков кириллицы — около
    /// килобайта, и пятьсот таких дают пачку вдвое больше предела. До
    /// 17 октября 2026 сервер отвечал на неё 413, а клиент повторял ту же
    /// пачку без конца — журнал машины вставал навсегда.
    static let maxBatchBytes = 200 << 10
    /// Сколько событий пробовать в следующей пачке. Делится пополам на 413 и
    /// возвращается к полному после удачной отправки.
    private var batchLimit = ClientEventLog.maxBatchEvents
    /// Куда писать исход отправки — в журнал приложения.
    private var log: ((SIPLogLevel, String) -> Void)?
    private var sending = false
    private var lastErrors: [String: Date] = [:]
    private var calls: [String: (direction: String, number: String?, name: String?, answeredAt: Date?, distribution: Bool)] = [:]
    private var wasRegistered = false
    /// Почему приложение само снимает регистрацию: обновление или выход.
    /// Без подписи такое снятие выглядело в Spark как сбой.
    private var shutdownReason: String?

    func noteShutdown(_ reason: String) {
        shutdownReason = reason
    }
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

    func start(settings: @escaping () -> AppSettings, log: @escaping (SIPLogLevel, String) -> Void) {
        self.settings = settings
        self.log = log
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
            if let reason = shutdownReason {
                record(.registration, .info, "Регистрация снята: \(reason)")
            } else if byOperator {
                record(.registration, .info, "Оператор отключился от АТС")
            } else {
                record(.registration, .warning, "Снята регистрация на АТС")
            }
        }
    }

    func callStarted(lineID: String, incoming: Bool, number: String? = nil, name: String? = nil,
                     distribution: Bool = false) {
        calls[lineID] = (incoming ? "in" : "out", Self.cleanPeer(number, limit: 128), Self.cleanPeer(name, limit: 256),
                         nil, incoming && distribution)
    }

    private static func cleanPeer(_ value: String?, limit: Int) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        let text = LogRedaction.redact(value)
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return String(text.prefix(limit))
    }

    func callAnswered(lineID: String) {
        calls[lineID]?.answeredAt = now()
    }

    func callFinished(lineID: String, reason: String, failed: Bool) {
        guard let call = calls.removeValue(forKey: lineID) else { return }
        let title = call.direction == "in" ? "Входящий звонок" : "Исходящий звонок"
        if let answered = call.answeredAt {
            record(.call, .info, "\(title) завершён", direction: call.direction,
                   duration: max(0, Int(now().timeIntervalSince(answered))),
                   peerNumber: call.number, peerName: call.name, distribution: call.distribution)
        } else {
            record(.call, failed ? .warning : .info, "\(title) без ответа: \(reason)",
                   direction: call.direction, peerNumber: call.number, peerName: call.name,
                   distribution: call.distribution)
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

    /// Переподключение и его причина — то, что раньше было видно только в
    /// журнале приложения на самой машине.
    func noteConnection(_ reason: String) {
        record(.connection, .warning, reason)
    }

    /// Звуковые устройства: появились, пропали, сменились по умолчанию или в
    /// EliteSIP. Видом `config`, как в Windows и Linux.
    func noteAudio(_ message: String, warning: Bool) {
        record(.config, warning ? .warning : .info, message)
    }

    // MARK: - Сеанс

    private var isSessionStarted = false
    private var isForgotten = false
    private var isFinishing = false

    private var sessionMarker: URL? {
        fileURL.map { URL(fileURLWithPath: $0.path + ".session") }
    }

    /// Маркер сеанса переживает принудительное завершение, при котором
    /// обработчики не выполняются. Это свидетельство, не диагноз.
    func beginSession() {
        guard !isSessionStarted, !isForgotten else { return }
        isSessionStarted = true
        if let marker = sessionMarker {
            if FileManager.default.fileExists(atPath: marker.path) {
                // не переводится: событие журнала машины Spark
                record(.connection, .warning,
                       "Предыдущий запуск завершился без штатного выхода: возможны сбой, принудительное закрытие или выключение компьютера")
            }
            try? Data(ISO8601DateFormatter().string(from: now()).utf8).write(to: marker)
        }
        // не переводится: событие журнала машины Spark
        record(.connection, .info, "Приложение запущено")
    }

    /// Штатный выход: событие о нём и отправка не дольше 750 мс. Не успело —
    /// буфер на диске, уйдёт при следующем запуске.
    func finishSession() async {
        guard !isFinishing else { return }
        isFinishing = true
        if isSessionStarted, !isForgotten {
            isSessionStarted = false
            // не переводится: событие журнала машины Spark
            record(.connection, .info, "Приложение закрыто: \(shutdownReason ?? "штатный выход")")
            if let marker = sessionMarker { try? FileManager.default.removeItem(at: marker) }
        }
        flushTask?.cancel()
        flushTask = nil
        send()
        for _ in 0..<15 where sending {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        // На выходе — сразу и до конца: отложенная запись не дождалась бы exit.
        if let fileURL, !isForgotten {
            let snapshot = pending
            Self.diskQueue.sync {
                try? JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
            }
        }
    }

    /// Сброс машины: забыть всё и больше не писать файл — иначе события
    /// прежней машины ушли бы от имени новой.
    func forget() {
        timer?.invalidate()
        timer = nil
        flushTask?.cancel()
        flushTask = nil
        endActivity()
        pending.removeAll()
        calls.removeAll()
        settings = nil
        isForgotten = true
        // Начатая запись иначе вернула бы файл уже после удаления.
        waitForDisk()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        if let marker = sessionMarker { try? FileManager.default.removeItem(at: marker) }
    }

    func record(_ kind: Kind, _ level: Level, _ message: String,
                sipCode: Int? = nil, direction: String? = nil, duration: Int? = nil,
                peerNumber: String? = nil, peerName: String? = nil, distribution: Bool = false) {
        guard !isForgotten else { return }
        let text = String(LogRedaction.redact(message).prefix(500))
        pending.append(Event(
            ts: ISO8601DateFormatter().string(from: now()), kind: kind, level: level,
            message: text, line: settings?().profiles.active.title,
            sip_code: sipCode, direction: direction, duration_s: duration,
            peer_number: peerNumber, peer_name: peerName, distribution: distribution ? true : nil))
        if pending.count > Self.capacity {
            pending.removeFirst(pending.count - Self.capacity)
        }
        persist()
        scheduleFlush()
    }

    // MARK: - Отправка

    private func scheduleFlush(after delay: TimeInterval = ClientEventLog.flushDelay) {
        guard flushTask == nil, !isFinishing else { return }
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "отправка журнала машины")
        }
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self else { return }
            self.flushTask = nil
            self.send()
        }
    }

    func send() {
        guard !sending else { return }
        guard !pending.isEmpty, let settings else { endActivity(); return }
        let panel = settings().panel
        guard panel.hasChannelKey, !panel.installationID.isEmpty,
              let url = Provisioning.secrets?.updates?.logsURL
        else { endActivity(); return }
        let batch = Self.batch(from: pending, limit: batchLimit, maxBytes: Self.maxBatchBytes)
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
            let http = response as? HTTPURLResponse
            let status = http?.statusCode
            let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            Task { @MainActor in
                ClientEventLog.shared.didSend(count: sent, status: status, retryAfter: retryAfter)
            }
        }.resume()
    }

    /// Начало буфера, которое влезает в пачку и по числу, и по объёму.
    ///
    /// Объём считается по тем же байтам, что уйдут в теле, плюс запятая на
    /// событие. Первое событие берётся всегда: пустая пачка не продвинула бы
    /// буфер, а одно событие предела не превысит — сообщение обрезано до 500
    /// знаков ещё в `record`.
    static func batch(from pending: [Event], limit: Int, maxBytes: Int) -> [Event] {
        var out: [Event] = []
        var bytes = 0
        let encoder = JSONEncoder()
        for event in pending.prefix(max(1, limit)) {
            let size = ((try? encoder.encode(event).count) ?? 0) + 1
            if !out.isEmpty, bytes + size > maxBytes { break }
            out.append(event)
            bytes += size
        }
        return out
    }

    private func didSend(count: Int, status: Int?, retryAfter: TimeInterval? = nil) {
        sending = false
        // 413 — пачка велика. Делим пополам и шлём сразу, без паузы: сеть
        // жива, сервер ответил. Одно событие, которое всё равно не влезло,
        // держать незачем — оно не пройдёт никогда.
        if status == 413 {
            if count > 1 {
                batchLimit = max(1, count / 2)
                log?(.warning, "журнал машины: пачка из \(count) велика (413), следующая — \(batchLimit)")
                scheduleFlush(after: 1)
                return
            }
            pending.removeFirst(min(count, pending.count))
            persist()
            log?(.warning, "журнал машины: событие не влезает в пачку (413) и выброшено")
            if pending.isEmpty { endActivity() } else { scheduleFlush(after: 1) }
            return
        }
        // 204 — пачка принята. 400 — её не примут никогда, держать незачем.
        if status == 204 || status == 400 {
            pending.removeFirst(min(count, pending.count))
            persist()
            retryDelay = 0
            batchLimit = Self.maxBatchEvents
            if status == 400 {
                log?(.warning, "журнал машины: сервер отверг пачку (400), событий выброшено: \(count)")
            } else {
                log?(.debug, "журнал машины: отправлено событий \(count)")
            }
            // Пока шла отправка, могли прийти новые.
            if pending.isEmpty { endActivity() } else { scheduleFlush() }
            return
        }
        // Сеть, 429, 5xx — повтор с нарастающей паузой, а не через пять минут.
        retryDelay = min(max(retryDelay * 2, 30), Self.sendInterval)
        // Сервер сам говорит, когда приходить (429 при переполненной очереди
        // сайта — 900 с). Раньше этого срока повтор только тратит трафик.
        if let retryAfter, retryAfter > retryDelay { retryDelay = min(retryAfter, 3600) }
        log?(.warning, "журнал машины: отправка не прошла (\(status.map(String.init) ?? "нет ответа")), "
            + "повтор через \(Int(retryDelay)) с, в буфере \(pending.count)")
        endActivity()
        scheduleFlush(after: retryDelay)
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    /// Очередь пишется на диск пачкой и в фоне, как в Windows и Linux 1.0.8:
    /// раньше каждое событие кодировало до тысячи записей прямо на главном
    /// потоке. Снимок берётся здесь, запись — на своей очереди, а подряд идущие
    /// события сливаются в одну запись.
    private func persist() {
        guard fileURL != nil, !isForgotten else { return }
        guard !isPersistScheduled else { return }
        isPersistScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.isPersistScheduled = false
            guard let fileURL = self.fileURL, !self.isForgotten else { return }
            let snapshot = self.pending
            Self.diskQueue.async {
                try? JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
            }
        }
    }

    private var isPersistScheduled = false
    private static let diskQueue = DispatchQueue(label: "com.elite.EliteSIP.client-events", qos: .utility)

    /// Дождаться уже начатой записи — перед выходом и перед стиранием.
    func waitForDisk() {
        Self.diskQueue.sync {}
    }
}

/// Регистрация, сведённая к тому, что попадает в журнал машины.
enum SIPRegistrationStateSummary: Equatable {
    case registered
    case failed(reason: String, code: Int?)
    /// byOperator — оператор сам ушёл с линии, а не АТС или сеть его сняли.
    case unregistered(byOperator: Bool)
}
