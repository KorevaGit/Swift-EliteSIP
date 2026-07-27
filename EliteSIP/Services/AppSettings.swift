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
    var incomingCall: IncomingCallSettings
    var minimumLogLevel: SIPLogLevel

    /// Доверять любому сертификату TLS.
    ///
    /// Отключает защиту от подмены сервера: перехватчик увидит и пароль, и
    /// разговор. Существует ровно ради самоподписанного сертификата
    /// лаборатории на localhost. В бою должно быть выключено.
    var acceptsAnyTLSCertificate: Bool

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
