import AppKit
import CoreImage
import Foundation
import PanelLink

/// Привязка машины: сессия в Spark, которую администратор закрывает кодом с
/// экрана (в Spark) или QR (в EliteGuard).
///
/// Ходит **в Spark**, а не на канал раздачи: сессия живёт там, где решают, чья
/// это машина. Spark смотрит наружу (spark.elitesochi.com), так что код
/// работает и у удалённого места.
///
/// Контракт — spark.elitesochi.com/docs/elitesip-qr-pair.md.
enum PairService {

    struct Session: Codable, Equatable {
        let sessionID: String
        let pollSecret: String
        let code: String
        let qr: String

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case pollSecret = "poll_secret"
            case code
            case qr
        }
    }

    struct Poll: Decodable {
        let state: String
        let installationID: String?
        let label: String?
        let extensionNumber: String?

        enum CodingKeys: String, CodingKey {
            case state
            case installationID = "installation_id"
            case label
            case extensionNumber = "extension"
        }
    }

    /// Сессии больше нет: истекла или её не было. Открываем новую — с новым
    /// кодом.
    struct SessionGone: Error {}

    /// Адрес Spark. `ESPairURL` в Info.plist переопределяет его для стенда.
    static var baseURL: URL {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "ESPairURL") as? String,
           let url = URL(string: raw), !raw.isEmpty {
            return url
        }
        return URL(string: "https://spark.elitesochi.com")!
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 40
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }()

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    static var deviceName: String {
        Host.current().localizedName ?? "Mac"
    }

    /// Открывает сессию: открытый ключ машины и хеш её ключа канала. Сам ключ
    /// канала не покидает машину.
    static func start(keyPair: MachineKeyPair, channelKey: String) async throws -> Session {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/pair/sessions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "public_key": keyPair.publicKeyBase64,
            "channel_key_hash": ChannelKey.hash(channelKey),
            "device_name": deviceName,
            "app_version": appVersion,
        ])
        let data = try await send(request, expecting: 201)
        return try JSONDecoder().decode(Session.self, from: data)
    }

    /// Длинный опрос: Spark держит ответ до ~25 секунд, пока машину не
    /// привязали. Каждый опрос продлевает сессию — код остаётся прежним.
    static func poll(_ session: Session) async throws -> Poll {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/pair/sessions/\(session.sessionID)"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "wait", value: "1")]
        var request = URLRequest(url: components.url!)
        request.setValue("Pair \(session.pollSecret)", forHTTPHeaderField: "Authorization")
        do {
            let data = try await send(request, expecting: 200)
            return try JSONDecoder().decode(Poll.self, from: data)
        } catch let error as HTTPStatus where error.code == 404 {
            throw SessionGone()
        }
    }

    /// Конфигурация забрана — сессия закрыта.
    static func ack(_ session: Session) async {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/pair/sessions/\(session.sessionID)/ack"))
        request.httpMethod = "POST"
        request.setValue("Pair \(session.pollSecret)", forHTTPHeaderField: "Authorization")
        _ = try? await send(request, expecting: 204)
    }

    /// Машина, поднятая ещё ключом активации, регистрирует свой открытый ключ.
    /// Вход — её installation_id и ключ канала: их Spark знает по хешу.
    static func registerLegacy(installationID: String, channelKey: String, keyPair: MachineKeyPair) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/pair/machine"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let encoded = "\(installationID):\(channelKey)".data(using: .utf8)?.base64EncodedString() {
            request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "public_key": keyPair.publicKeyBase64,
            "device_name": deviceName,
        ])
        _ = try await send(request, expecting: 200)
    }

    struct HTTPStatus: Error {
        let code: Int
    }

    private static func send(_ request: URLRequest, expecting status: Int) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == status else { throw HTTPStatus(code: code) }
        return data
    }

    /// QR без сглаживания: модули остаются чёткими при любом масштабе.
    static func qrImage(_ text: String, side: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = max(1, floor(side * 2 / output.extent.width))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return image
    }
}

/// То, чем машина представляется панели: ключ машины, ключ канала и
/// открытая сессия с кодом.
///
/// **Лежит на диске, пока машина не настроена**, — иначе перезапуск приложения
/// менял бы код, а стажёру его уже продиктовали. Каталог приложения, файл под
/// 0600. Стирается, когда мастер применил настройку, и при сбросе машины.
struct PairingIdentity: Codable, Equatable {
    var machineKey: String
    var channelKey: String
    var session: PairService.Session?
    /// Машину привязали: идентификатор уже выдан, осталось забрать настройки.
    var installationID: String?
    /// Забранная настройка — переживает закрытый мастер.
    var setup: MachineSetup?
}

/// Что приехало на машину при привязке: её конфигурация и предустановка.
///
/// Предустановку забираем тем же заходом, что и конфигурацию: мастер должен
/// поднять машину целиком, а не «номер сейчас, адрес АТС через два часа».
struct MachineSetup: Codable, Equatable {
    var installationID: String
    var channelKey: String
    var machineKey: String
    var config: MachineConfig
    var preset: Preset?

    struct Preset: Codable, Equatable {
        var id: String
        var name: String
        var revision: Int
        var fields: Data
    }
}

enum PairingStore {

    private static var fileURL: URL {
        SettingsStore.fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("pairing.json")
    }

    static func load() -> PairingIdentity? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let identity = try? decoder.decode(PairingIdentity.self, from: data) else {
            clear()
            return nil
        }
        return identity
    }

    static func save(_ identity: PairingIdentity) {
        do {
            let url = fileURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(identity).write(to: url, options: .atomic)
            // 0600 после каждой записи: `.atomic` пишет новый файл, и права у
            // него каждый раз из umask. Внутри ключ машины и SIP-пароль.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Не сохранилось — код сменится при следующем запуске. Неудобство,
            // а не отказ: текущая сессия в памяти работает.
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// Код машины на экране мастера: открывает (или продолжает) сессию, показывает
/// код и QR и забирает настройки, как только машину привяжут.
@MainActor
final class PairingController: ObservableObject {

    enum Phase: Equatable {
        case starting
        case showing
        /// Привязали — забираем настройки.
        case fetching
        case received
        /// Spark недоступен — код пока не показать.
        case unavailable
    }

    @Published private(set) var phase: Phase = .starting
    @Published private(set) var code: String?
    @Published private(set) var qr: NSImage?
    /// Почему не получилось забрать настройки после привязки.
    @Published private(set) var failure: String?

    private var loop: Task<Void, Never>?

    /// Запускает показ кода. `onSetup` получает настройки привязанной машины.
    func start(onSetup: @escaping @MainActor (MachineSetup) async -> Void) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self else { return }
                var identity = PairingStore.load() ?? PairingIdentity(
                    machineKey: MachineKeyPair().rawPrivateKey.base64EncodedString(),
                    channelKey: ChannelKey.generate())
                if let setup = identity.setup {
                    self.phase = .received
                    self.loop = nil
                    await onSetup(setup)
                    return
                }
                do {
                    guard let raw = Data(base64Encoded: identity.machineKey) else {
                        PairingStore.clear()
                        continue
                    }
                    let keyPair = try MachineKeyPair(rawPrivateKey: raw)

                    // Уже привязана: осталось забрать настройки.
                    if let installationID = identity.installationID {
                        self.phase = .fetching
                        let setup = try await MachineService.fetchSetup(
                            installationID: installationID, channelKey: identity.channelKey, keyPair: keyPair)
                        identity.setup = setup
                        PairingStore.save(identity)
                        if let session = identity.session { await PairService.ack(session) }
                        self.failure = nil
                        self.phase = .received
                        self.loop = nil
                        await onSetup(setup)
                        return
                    }

                    let session: PairService.Session
                    if let saved = identity.session {
                        session = saved
                    } else {
                        if self.phase != .showing { self.phase = .starting }
                        session = try await PairService.start(keyPair: keyPair, channelKey: identity.channelKey)
                        identity.session = session
                        PairingStore.save(identity)
                    }
                    self.show(session)
                    failures = 0

                    while !Task.isCancelled {
                        let poll = try await PairService.poll(session)
                        if poll.state == "claimed" || poll.state == "delivered", let id = poll.installationID {
                            identity.installationID = id
                            PairingStore.save(identity)
                            break
                        }
                        if poll.state != "waiting" { throw PairService.SessionGone() }
                    }
                } catch is PairService.SessionGone {
                    // Сессия истекла: новая сессия — новый код.
                    identity.session = nil
                    PairingStore.save(identity)
                } catch {
                    if Task.isCancelled { return }
                    failures += 1
                    if identity.installationID != nil {
                        self.failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    } else if failures >= 3, self.code == nil {
                        self.phase = .unavailable
                    }
                    // Сеть пропала — пробуем снова, но не долбим сервер.
                    try? await Task.sleep(nanoseconds: UInt64(min(failures, 6)) * 5_000_000_000)
                }
            }
        }
    }

    private func show(_ session: PairService.Session) {
        code = session.code
        qr = PairService.qrImage(session.qr, side: 168)
        phase = .showing
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// «Это не я»: забыть привязку и показать новый код. Ключ машины при этом
    /// новый — прежнюю привязку в Spark отвязывают, а эта машина начинает
    /// заново.
    func startOver(onSetup: @escaping @MainActor (MachineSetup) async -> Void) {
        stop()
        PairingStore.clear()
        code = nil
        qr = nil
        failure = nil
        phase = .starting
        start(onSetup: onSetup)
    }
}
