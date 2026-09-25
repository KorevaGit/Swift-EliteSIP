import AppKit
import CoreImage
import Foundation
import PanelLink

/// Привязка по QR: сессия в Spark, которую установщик закрывает из EliteGuard.
///
/// В отличие от `ActivationService`, ходит **в Spark**, а не на канал раздачи:
/// сессия живёт там, где выпускают ключи. Spark смотрит наружу
/// (spark.elitesochi.com), так что код работает и у удалённого места. Не
/// достучались — не беда: поле для ключа под кодом никуда не девается.
///
/// Контракт — spark.elitesochi.com/docs/elitesip-qr-pair.md.
enum PairService {

    struct Session: Decodable {
        let sessionID: String
        let pollSecret: String
        let qr: String
        let expiresAt: Date

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case pollSecret = "poll_secret"
            case qr
            case expiresAt = "expires_at"
        }
    }

    struct Poll: Decodable {
        let state: String
        let sealedKey: String?

        enum CodingKeys: String, CodingKey {
            case state
            case sealedKey = "sealed_key"
        }
    }

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

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            let plain = ISO8601DateFormatter()
            if let date = plain.date(from: raw) { return date }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: raw) { return date }
            // Срок нужен только для перевыпуска кода — без него перевыпустим
            // по своему таймеру.
            return Date().addingTimeInterval(170)
        }
        return decoder
    }()

    static func start(publicKey: String) async throws -> Session {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/pair/sessions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "public_key": publicKey,
            "device_name": Host.current().localizedName ?? "Mac",
            "app_version": version,
        ])
        let data = try await send(request, expecting: 201)
        return try decoder.decode(Session.self, from: data)
    }

    /// Длинный опрос: Spark держит ответ до ~25 секунд, пока ключа нет.
    static func poll(_ session: Session) async throws -> Poll {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/pair/sessions/\(session.sessionID)"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "wait", value: "1")]
        var request = URLRequest(url: components.url!)
        request.setValue("Pair \(session.pollSecret)", forHTTPHeaderField: "Authorization")
        let data = try await send(request, expecting: 200)
        return try decoder.decode(Poll.self, from: data)
    }

    /// Ключ распечатан — запечатанному на сервере лежать больше незачем.
    static func ack(_ session: Session) async {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/pair/sessions/\(session.sessionID)/ack"))
        request.httpMethod = "POST"
        request.setValue("Pair \(session.pollSecret)", forHTTPHeaderField: "Authorization")
        _ = try? await send(request, expecting: 204)
    }

    private static func send(_ request: URLRequest, expecting status: Int) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == status else { throw URLError(.badServerResponse) }
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

/// Живой QR на экране ввода ключа: открывает сессию, перевыпускает код по
/// истечении и отдаёт ключ, как только установщик его привяжет.
@MainActor
final class PairingController: ObservableObject {

    enum Phase: Equatable {
        case starting
        case showing
        case received
        /// Spark недоступен — код не показываем, ключ вводят руками.
        case unavailable
    }

    @Published private(set) var phase: Phase = .starting
    @Published private(set) var qr: NSImage?

    private var loop: Task<Void, Never>?

    /// Запускает показ кода. `onKey` получает ключ из EliteGuard.
    func start(onKey: @escaping @MainActor (ActivationKey) async -> Void) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self else { return }
                let pair = PairKeyPair()
                do {
                    if self.phase != .showing { self.phase = .starting }
                    let session = try await PairService.start(publicKey: pair.publicKeyBase64)
                    failures = 0
                    self.qr = PairService.qrImage(session.qr, side: 168)
                    self.phase = .showing

                    while !Task.isCancelled, Date() < session.expiresAt {
                        let poll = try await PairService.poll(session)
                        if poll.state == "claimed", let sealed = poll.sealedKey {
                            let key = try pair.openKey(sealedBase64: sealed)
                            await PairService.ack(session)
                            self.phase = .received
                            self.loop = nil
                            await onKey(key)
                            return
                        }
                        if poll.state != "waiting" { break }
                    }
                } catch {
                    if Task.isCancelled { return }
                    failures += 1
                    if failures >= 3 { self.phase = .unavailable }
                    // Сеть пропала — пробуем снова, но не долбим сервер.
                    try? await Task.sleep(nanoseconds: UInt64(min(failures, 6)) * 5_000_000_000)
                }
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        if phase != .received { phase = .starting }
    }

    /// Ключ не подошёл — снова показываем код.
    func restart(onKey: @escaping @MainActor (ActivationKey) async -> Void) {
        stop()
        phase = .starting
        start(onKey: onKey)
    }
}
