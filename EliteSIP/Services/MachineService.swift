import CryptoKit
import Foundation
import PanelLink

/// То, что принадлежит одной машине: её административный пароль и её отзыв.
///
/// Отдельно от `PresetService`, хотя ходит на тот же канал тем же ключом.
/// Причина в сроках: файл предустановок машина спрашивает раз в два часа, а
/// отзыв — раз в пятнадцать минут, потому что отзыв срабатывает ровно с
/// задержкой опроса, и на двухчасовом сроке уволенный сотрудник работал бы ещё
/// два часа после нажатия «отозвать».
///
/// **Ходит она помашинным ключом, а не общей парой из бандла.** Общая лежит
/// открытым текстом в каждом приложении и открывает теперь только выпуски.
@MainActor
final class MachineService {

    /// Как часто спрашивать про отзыв.
    ///
    /// Пятнадцать минут. Объект крошечный, ответ «не отзывали» — это 404 в
    /// несколько байт: тридцать машин дают меньше трёх тысяч запросов в сутки,
    /// три процента бесплатной квоты канала.
    static let revocationInterval: TimeInterval = 15 * 60

    private let publicKey: Curve25519.Signing.PublicKey?
    private let settings: () -> AppSettings

    /// Применить приехавший административный пароль.
    private let applyAccess: (MachineAccess) -> Void

    /// Сбросить машину. Зовётся только по подписанному отзыву.
    private let reset: (Revocation) -> Void

    private let log: (String) -> Void

    private var isAsking = false

    init(publicKey: Curve25519.Signing.PublicKey?,
         settings: @escaping () -> AppSettings,
         applyAccess: @escaping (MachineAccess) -> Void,
         reset: @escaping (Revocation) -> Void,
         log: @escaping (String) -> Void) {
        self.publicKey = publicKey
        self.settings = settings
        self.applyAccess = applyAccess
        self.reset = reset
        self.log = log
    }

    /// Спросить канал про свой доступ. Идёт в общем такте с предустановками.
    func checkAccess() {
        fetch(prefix: "access") { @MainActor [weak self] data, publicKey, installationID in
            guard let self else { return }
            do {
                let access = try MachineAccess.verified(data, publicKey: publicKey,
                                                        installationID: installationID)
                self.applyAccess(access)
            } catch {
                // не переводится: строка журнала
                self.log("доступ ОТБРОШЕН: \(error.localizedDescription)")
            }
        }
    }

    /// Спросить канал, не отозвали ли машину. Свой такт, вчетверо чаще.
    ///
    /// **Отсутствие ответа никогда не означает отзыв.** Нет сети, лежит
    /// Worker, 404 по адресу — машина работает дальше. Сбрасывает её только
    /// подписанный объект: иначе опечатка в правиле Cloudflare стирала бы не
    /// одну машину, а все тридцать разом.
    func checkRevocation() {
        fetch(prefix: "revoked") { @MainActor [weak self] data, publicKey, installationID in
            guard let self else { return }
            do {
                let revocation = try Revocation.verified(data, publicKey: publicKey,
                                                         installationID: installationID)
                // не переводится: строка журнала
                self.log("получен подписанный отзыв от \(revocation.revokedAt)")
                self.reset(revocation)
            } catch {
                // Подпись не сошлась — это не отзыв, а мусор по нашему адресу.
                // Сбрасывать по нему нельзя ни в коем случае.
                // не переводится: строка журнала
                self.log("отзыв ОТБРОШЕН: \(error.localizedDescription)")
            }
        }
    }

    /// Общий заход на канал за помашинным объектом.
    private func fetch(prefix: String,
                       handle: @escaping @MainActor (Data, Curve25519.Signing.PublicKey, String) -> Void) {
        guard let publicKey else {
            // не переводится: строка журнала
            log("помашинные объекты выключены: в Info.plist нет открытого ключа линии")
            return
        }
        let now = settings()
        guard now.panel.hasChannelKey else { return }
        guard let channel = Provisioning.secrets?.updates,
              let url = channel.machineURL(prefix: prefix, installationID: now.panel.installationID)
        else { return }
        guard !isAsking else { return }
        isAsking = true

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        // Помашинная пара: имя пользователя — идентификатор машины, пароль —
        // ключ канала. Общая пара из бандла сюда не пускает вовсе.
        let pair = "\(now.panel.installationID):\(now.panel.channelKey)"
        if let encoded = pair.data(using: .utf8)?.base64EncodedString() {
            request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(Self.appVersion, forHTTPHeaderField: "X-EliteSIP-App")

        let installationID = now.panel.installationID
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self else { return }
                self.isAsking = false

                if let error {
                    // Нет связи — обычное состояние, а не беда.
                    // не переводится: строка журнала
                    self.log("\(prefix): канал недоступен — \(error.localizedDescription)")
                    return
                }
                guard let http = response as? HTTPURLResponse else { return }
                if http.statusCode == 404 {
                    // Для отзыва это «не отзывали», для доступа — «панель ещё
                    // не выложила». Оба случая — молчание, а не событие.
                    return
                }
                if http.statusCode == 401 {
                    // Ключ канала обрублен. Это **не** отзыв: сбрасываться по
                    // отказу в доступе нельзя — так одна ошибка на стороне
                    // канала стирала бы все машины сразу.
                    // не переводится: строка журнала
                    self.log("\(prefix): канал не принял ключ машины")
                    return
                }
                guard http.statusCode == 200, let data else {
                    // не переводится: строка журнала
                    self.log("\(prefix): канал ответил \(http.statusCode)")
                    return
                }
                handle(data, publicKey, installationID)
            }
        }.resume()
    }

    private static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
    }
}

extension MachineService {

    /// Забрать свой административный пароль прямо сейчас, не дожидаясь такта.
    ///
    /// Нужно ровно в одном месте — в мастере, сразу после того, как ключ
    /// открыл пакет. Ждать общего опроса там нельзя: между концом мастера и
    /// первым заходом на канал «Управление» стояло бы открытым для всякого, а
    /// машина при этом выглядела бы настроенной. Ту же дыру закрывали 17
    /// августа 2026, когда пароль ещё был вшит в сборку.
    ///
    /// Отдельная функция, а не метод службы: службы в этот момент ещё нет —
    /// она заводится при запуске приложения, а мастер идёт до него.
    static func fetchAccess(installationID: String, channelKey: String) async throws -> MachineAccess {
        guard let publicKey = PresetService.channelPublicKey else {
            throw PanelLinkError.signatureDidNotMatch
        }
        guard let channel = Provisioning.secrets?.updates,
              let url = channel.machineURL(prefix: "access", installationID: installationID)
        else {
            throw PanelLinkError.malformedBundle
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let pair = "\(installationID):\(channelKey)"
        if let encoded = pair.data(using: .utf8)?.base64EncodedString() {
            request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw PanelLinkError.malformedBundle
        }
        return try MachineAccess.verified(data, publicKey: publicKey, installationID: installationID)
    }
}
