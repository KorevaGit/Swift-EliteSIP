import CryptoKit
import Foundation
import PanelLink

/// То, что принадлежит одной машине: её конфигурация из Spark и её отзыв.
///
/// Отдельно от `PresetService`, хотя ходит на тот же канал тем же ключом.
/// Причина в сроках: файл предустановок машина спрашивает раз в два часа, а
/// конфигурацию и отзыв — раз в пятнадцать минут. Отзыв срабатывает ровно с
/// задержкой опроса, и на двухчасовом сроке уволенный сотрудник работал бы ещё
/// два часа после нажатия «отвязать»; смена номера доезжала бы так же долго.
///
/// **Ходит она помашинным ключом, а не общей парой из бандла.** Общая лежит
/// открытым текстом в каждом приложении и открывает только выпуски.
@MainActor
final class MachineService {

    /// Как часто спрашивать конфигурацию и отзыв.
    ///
    /// Пятнадцать минут. Объекты крошечные, «не отзывали» — это 404 в
    /// несколько байт: тридцать машин дают несколько тысяч запросов в сутки.
    static let revocationInterval: TimeInterval = 15 * 60

    private let publicKey: Curve25519.Signing.PublicKey?
    private let settings: () -> AppSettings

    /// Применить приехавшую конфигурацию.
    private let applyConfig: (MachineConfig) -> Void

    /// Запомнить ключ машины, созданный при переходе со старого ключа.
    private let storeMachineKey: (String) -> Void

    /// Сбросить машину. Зовётся только по подписанному отзыву.
    private let reset: (Revocation) -> Void

    private let log: (String) -> Void

    /// Что сейчас спрашивается — по приставке, а не одним флагом на всё:
    /// такты у линий разные, и при наложении второй запрос молча отбрасывался
    /// бы. Найдено аудитом 27 августа 2026.
    private var asking: Set<String> = []

    /// Идёт регистрация ключа машины, поднятой ещё ключом активации.
    private var upgrading = false

    init(publicKey: Curve25519.Signing.PublicKey?,
         settings: @escaping () -> AppSettings,
         applyConfig: @escaping (MachineConfig) -> Void,
         storeMachineKey: @escaping (String) -> Void,
         reset: @escaping (Revocation) -> Void,
         log: @escaping (String) -> Void) {
        self.publicKey = publicKey
        self.settings = settings
        self.applyConfig = applyConfig
        self.storeMachineKey = storeMachineKey
        self.reset = reset
        self.log = log
    }

    /// Спросить канал про свою конфигурацию.
    ///
    /// Машина, поднятая ещё ключом активации, своего ключа машины не имеет:
    /// сперва она его создаёт и регистрирует в Spark своим ключом канала, и
    /// только потом Spark начинает выкладывать ей конфигурацию.
    func checkConfig() {
        let now = settings()
        guard now.panel.hasChannelKey else { return }
        guard now.panel.hasMachineKey else {
            upgradeLegacy(now.panel)
            return
        }
        guard let raw = Data(base64Encoded: now.panel.machineKey),
              let keyPair = try? MachineKeyPair(rawPrivateKey: raw)
        else {
            // не переводится: строка журнала
            log("конфигурация: ключ машины в настройках испорчен")
            return
        }
        fetch(prefix: "config") { @MainActor [weak self] data, publicKey, installationID in
            guard let self else { return }
            do {
                let config = try MachineConfig.verified(data, publicKey: publicKey,
                                                        installationID: installationID, keyPair: keyPair)
                self.applyConfig(config)
            } catch {
                // не переводится: строка журнала
                self.log("конфигурация ОТБРОШЕНА: \(error.localizedDescription)")
            }
        }
    }

    /// Спросить канал, не отвязали ли машину. Свой такт, вчетверо чаще
    /// предустановок.
    ///
    /// **Отсутствие ответа никогда не означает отзыв.** Нет сети, лежит
    /// сервер, 404 по адресу — машина работает дальше. Сбрасывает её только
    /// подписанный объект: иначе опечатка на стороне канала стирала бы не одну
    /// машину, а все тридцать разом.
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

    /// Переход машины, поднятой ключом активации: свой ключ машины и его
    /// регистрация в Spark. Ключ сохраняется сразу — повторная попытка должна
    /// предъявить тот же, а не новый: Spark второй ключ не примет.
    private func upgradeLegacy(_ panel: AppSettings.PanelSettings) {
        guard !upgrading else { return }
        upgrading = true
        let keyPair = MachineKeyPair()
        let machineKey = keyPair.rawPrivateKey.base64EncodedString()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.upgrading = false }
            do {
                try await PairService.registerLegacy(installationID: panel.installationID,
                                                     channelKey: panel.channelKey, keyPair: keyPair)
                self.storeMachineKey(machineKey)
                // не переводится: строка журнала
                self.log("ключ машины зарегистрирован в Spark: дальше настройки приходят конфигурацией")
                self.checkConfig()
            } catch {
                // Нет сети, Spark не ответил или машину там уже отвязали —
                // попробуем на следующем такте. Доступ старого образца до
                // обновления уже не читаем: пароль и предустановка приедут
                // конфигурацией.
                // не переводится: строка журнала
                self.log("ключ машины не зарегистрирован: \(error.localizedDescription)")
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
        guard !asking.contains(prefix) else { return }
        asking.insert(prefix)

        let request = Self.machineRequest(url: url, panel: now.panel)
        let installationID = now.panel.installationID
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self else { return }
                self.asking.remove(prefix)

                if let error {
                    // Нет связи — обычное состояние, а не беда.
                    // не переводится: строка журнала
                    self.log("\(prefix): канал недоступен — \(error.localizedDescription)")
                    return
                }
                guard let http = response as? HTTPURLResponse else { return }
                if http.statusCode == 404 {
                    // Для отзыва это «не отзывали», для конфигурации — «Spark
                    // ещё не выложил». Оба случая — молчание, а не событие.
                    return
                }
                if http.statusCode == 401 {
                    // Ключ канала обрублен. Это **не** отзыв: сбрасываться по
                    // отказу в доступе нельзя.
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

    /// Запрос за помашинным объектом: вход ключом канала и заголовки, по
    /// которым Spark видит, что машина уже применила.
    static func machineRequest(url: URL, panel: AppSettings.PanelSettings) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // Помашинная пара: имя пользователя — идентификатор машины, пароль —
        // ключ канала. Общая пара из бандла сюда не пускает вовсе.
        let pair = "\(panel.installationID):\(panel.channelKey)"
        if let encoded = pair.data(using: .utf8)?.base64EncodedString() {
            request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(PairService.appVersion, forHTTPHeaderField: "X-EliteSIP-App")
        request.setValue(String(AppSettings.currentSchemaVersion), forHTTPHeaderField: "X-EliteSIP-Schema")
        request.setValue(String(panel.appliedRevision), forHTTPHeaderField: "X-EliteSIP-Revision")
        request.setValue(String(panel.appliedConfigRevision), forHTTPHeaderField: "X-EliteSIP-Config")
        return request
    }
}

extension MachineService {

    /// Забрать настройки только что привязанной машины: конфигурацию и её
    /// предустановку.
    ///
    /// Нужно в мастере, сразу после привязки. Ждать общего опроса там нельзя:
    /// человек смотрит на экран и ждёт, чьё это место. Отдельная функция, а не
    /// метод службы: службы в этот момент ещё нет — она заводится при запуске
    /// приложения, а мастер идёт до него.
    static func fetchSetup(installationID: String, channelKey: String,
                           keyPair: MachineKeyPair) async throws -> MachineSetup {
        guard let publicKey = PresetService.channelPublicKey else {
            throw PanelLinkError.signatureDidNotMatch
        }
        guard let channel = Provisioning.secrets?.updates,
              let configURL = channel.machineURL(prefix: "config", installationID: installationID),
              let presetsURL = channel.presetsURL
        else {
            throw PanelLinkError.malformedBundle
        }
        var panel = AppSettings.PanelSettings()
        panel.installationID = installationID
        panel.channelKey = channelKey

        // Spark выкладывает конфигурацию до того, как отвечает «привязана», но
        // запас на пару повторов стоит дёшево.
        var configData: Data?
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            let (data, response) = try await URLSession.shared.data(for: machineRequest(url: configURL, panel: panel))
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 { configData = data; break }
            if code != 404 { throw PairService.HTTPStatus(code: code) }
        }
        guard let configData else { throw PairService.HTTPStatus(code: 404) }
        let config = try MachineConfig.verified(configData, publicKey: publicKey,
                                                installationID: installationID, keyPair: keyPair)

        var preset: MachineSetup.Preset?
        let (bundleData, bundleResponse) = try await URLSession.shared.data(for: machineRequest(url: presetsURL, panel: panel))
        if (bundleResponse as? HTTPURLResponse)?.statusCode == 200,
           let bundle = try? PresetBundle.verified(bundleData, publicKey: publicKey),
           let entry = bundle.entry(id: config.presetID) {
            preset = MachineSetup.Preset(id: entry.id, name: entry.name, revision: entry.revision, fields: entry.fields)
        }
        return MachineSetup(installationID: installationID, channelKey: channelKey,
                            machineKey: keyPair.rawPrivateKey.base64EncodedString(),
                            config: config, preset: preset)
    }
}
