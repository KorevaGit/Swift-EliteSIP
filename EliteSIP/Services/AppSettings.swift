import Foundation
import SIPCore

/// Всё, что приложение помнит между запусками, кроме пароля.
///
/// Один плоский `Codable` с версией схемы — под будущую синхронизацию с
/// EliteDash и баш-скрипт провижининга: им нужен предсказуемый формат, который
/// можно сгенерировать снаружи и положить в файл.
struct AppSettings: Codable, Sendable, Equatable {

    /// Версия схемы. Растёт, когда формат меняется несовместимо.
    var schemaVersion: Int = 1

    var account: SIPAccount
    var audio: AudioSettings = AudioSettings()
    var incomingCall: IncomingCallSettings
    var minimumLogLevel: SIPLogLevel

    /// Доверять любому сертификату TLS.
    ///
    /// Отключает защиту от подмены сервера: перехватчик увидит и пароль, и
    /// разговор. Существует ровно ради самоподписанного сертификата
    /// лаборатории на localhost. В бою должно быть выключено.
    var acceptsAnyTLSCertificate: Bool

    /// Свой почленный инициализатор: наличие `init(from:)` отменяет
    /// синтезированный.
    init(
        schemaVersion: Int = 1,
        account: SIPAccount,
        audio: AudioSettings = AudioSettings(),
        incomingCall: IncomingCallSettings = IncomingCallSettings(),
        minimumLogLevel: SIPLogLevel = .info,
        acceptsAnyTLSCertificate: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.account = account
        self.audio = audio
        self.incomingCall = incomingCall
        self.minimumLogLevel = minimumLogLevel
        self.acceptsAnyTLSCertificate = acceptsAnyTLSCertificate
    }

    /// Разбор терпим к отсутствующим полям.
    ///
    /// Синтезированный декодер этого не умеет: значение по умолчанию у свойства
    /// он игнорирует и падает на первом же незнакомом файле. А падение здесь —
    /// это молчаливый откат к пустым настройкам в `SettingsStore.load`, то есть
    /// потерянная учётная запись при обычном обновлении версии.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        account = try container.decode(SIPAccount.self, forKey: .account)
        audio = try container.decodeIfPresent(AudioSettings.self, forKey: .audio) ?? AudioSettings()
        incomingCall = try container.decodeIfPresent(
            IncomingCallSettings.self, forKey: .incomingCall
        ) ?? IncomingCallSettings()
        minimumLogLevel = try container.decodeIfPresent(SIPLogLevel.self, forKey: .minimumLogLevel) ?? .info
        acceptsAnyTLSCertificate =
            try container.decodeIfPresent(Bool.self, forKey: .acceptsAnyTLSCertificate) ?? false
    }

    struct AudioSettings: Codable, Sendable, Equatable {

        /// Микрофон (`AudioDevice.uid`). nil — системный по умолчанию.
        ///
        /// Хранится именно uid, а не имя и не номер: номер HAL живёт до
        /// переподключения устройства, а имён «AirPods Pro» в доме может быть
        /// несколько.
        var inputDeviceUID: String?

        /// Устройство вывода. nil — системное по умолчанию.
        ///
        /// Если оно отличается от микрофона, тракт соберёт приватное агрегатное
        /// устройство — иначе macOS не даёт развести стороны.
        var outputDeviceUID: String?

        /// Отпускать звуковое устройство между звонками.
        ///
        /// Ради Bluetooth-гарнитур: пока микрофон открыт, AirPods работают в
        /// двустороннем режиме, и у всей системы приглушён звук. Выключать это
        /// имеет смысл только на проводной гарнитуре, где переключать нечего, а
        /// открыть устройство заново — лишние доли секунды в начале звонка.
        var releasesDeviceWhenIdle: Bool = true

        /// Предлагать широкую полосу (G.722).
        ///
        /// Выключатель нужен не для красоты: если разговор всё равно уходит в
        /// город, широкая полоса не переживёт стык с телефонной сетью, зато
        /// добавит Asterisk перекодирование. На загруженной АТС это заметно.
        var prefersWideband: Bool = true

        /// Автоусиление в блоке обработки голоса.
        ///
        /// Система включает его сама. На хорошей гарнитуре оно «дышит»:
        /// подтягивает шум в паузах и приседает на громком слоге.
        var automaticGainControl: Bool = true

        init(
            inputDeviceUID: String? = nil,
            outputDeviceUID: String? = nil,
            releasesDeviceWhenIdle: Bool = true,
            prefersWideband: Bool = true,
            automaticGainControl: Bool = true
        ) {
            self.inputDeviceUID = inputDeviceUID
            self.outputDeviceUID = outputDeviceUID
            self.releasesDeviceWhenIdle = releasesDeviceWhenIdle
            self.prefersWideband = prefersWideband
            self.automaticGainControl = automaticGainControl
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            inputDeviceUID = try container.decodeIfPresent(String.self, forKey: .inputDeviceUID)
            outputDeviceUID = try container.decodeIfPresent(String.self, forKey: .outputDeviceUID)
            releasesDeviceWhenIdle =
                try container.decodeIfPresent(Bool.self, forKey: .releasesDeviceWhenIdle) ?? true
            prefersWideband = try container.decodeIfPresent(Bool.self, forKey: .prefersWideband) ?? true
            automaticGainControl =
                try container.decodeIfPresent(Bool.self, forKey: .automaticGainControl) ?? true
        }
    }

    struct IncomingCallSettings: Codable, Sendable, Equatable {
        var isRandomPositionEnabled: Bool = true
        /// Минимальное смещение окна от прошлой позиции, в точках.
        var minimumTravel: Double = 150
        /// Отступ от краёв рабочей области, в точках.
        var screenMargin: Double = 24
    }

    static let `default` = AppSettings(
        account: SIPAccount(
            username: "",
            displayName: "",
            domain: "",
            transport: .tls,
            registrationExpires: 300
        ),
        incomingCall: IncomingCallSettings(),
        minimumLogLevel: .info,
        acceptsAnyTLSCertificate: false
    )

    /// Настройки лаборатории — чтобы проверить регистрацию одним нажатием.
    static let labUDP = AppSettings(
        account: SIPAccount(
            username: "100",
            displayName: "Agent 100",
            domain: "127.0.0.1",
            serverPort: 5060,
            transport: .udp,
            registrationExpires: 120
        ),
        incomingCall: IncomingCallSettings(),
        minimumLogLevel: .debug,
        acceptsAnyTLSCertificate: false
    )

    static let labTLS = AppSettings(
        account: SIPAccount(
            username: "200",
            displayName: "Agent 200 secure",
            domain: "127.0.0.1",
            serverPort: 5061,
            transport: .tls,
            registrationExpires: 120
        ),
        incomingCall: IncomingCallSettings(),
        minimumLogLevel: .debug,
        acceptsAnyTLSCertificate: true
    )
}

/// Чтение и запись настроек в Application Support.
enum SettingsStore {

    private static let fileName = "settings.json"

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("EliteSIP", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    static func load() -> AppSettings {
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            // Отсутствие файла — норма при первом запуске. Испорченный файл тоже
            // не повод падать: пользователь просто увидит пустые настройки.
            return .default
        }
    }

    static func save(_ settings: AppSettings) throws {
        let url = fileURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}
