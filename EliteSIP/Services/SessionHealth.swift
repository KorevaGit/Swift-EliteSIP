import Foundation
import SIPCore

/// Здоровье рабочего места — то, что уезжает в Spark заголовками помашинных
/// запросов.
///
/// Своего канала телеметрии у приложения нет, а о падении на рабочем месте до
/// 0.1.58 узнавали только из жалобы. Машина и так спрашивает канал раз в
/// пятнадцать минут (отзыв, конфигурация); к этим запросам приложены три
/// заголовка, и сервер видит парк без нового адреса и без новой связи:
///
///   - `X-EliteSIP-Registration` — состояние регистрации сейчас:
///     `registered`, `registering`, `failed`, `idle`, `unregistering`;
///   - `X-EliteSIP-Registered-At` — когда регистрация последний раз стала
///     успешной в этом сеансе (ISO 8601) или `never`;
///   - `X-EliteSIP-Unclean-Exit` — `1`, если прошлый сеанс кончился не штатным
///     выходом: падение, снятый процесс, пропавшее питание. Различить их
///     изнутри нельзя, но частые единицы на одной машине — повод забрать
///     архив поддержки.
///
/// Секретов здесь нет и быть не должно: номер и так в ключе машины, а
/// причина отказа регистрации может нести текст ответа АТС — она остаётся в
/// журнале.
@MainActor
enum SessionHealth {

    private static var markerURL: URL {
        SettingsStore.fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("session.running")
    }

    /// Прошлый сеанс не дошёл до штатного выхода.
    private(set) static var previousSessionEndedUncleanly = false

    private static var registrationState = "idle"
    private static var lastRegisteredAt: Date?

    /// Зовётся первым делом при запуске: отметка прошлого сеанса, оставшаяся
    /// на диске, и есть признак, что он не вышел штатно.
    static func noteLaunch() {
        let marker = markerURL
        previousSessionEndedUncleanly = FileManager.default.fileExists(atPath: marker.path)
        try? FileManager.default.createDirectory(
            at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: marker.path,
            contents: Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8))
    }

    /// Штатный выход: по ⌘Q, перезапуском или установщиком обновления.
    static func noteCleanExit() {
        try? FileManager.default.removeItem(at: markerURL)
    }

    static func noteRegistration(_ state: SIPRegistrationState) {
        switch state {
        case .idle: registrationState = "idle"
        case .registering: registrationState = "registering"
        case .registered:
            registrationState = "registered"
            lastRegisteredAt = Date()
        case .unregistering: registrationState = "unregistering"
        case .failed: registrationState = "failed"
        }
    }

    static var headers: [String: String] {
        [
            "X-EliteSIP-Registration": registrationState,
            "X-EliteSIP-Registered-At": lastRegisteredAt.map { ISO8601DateFormatter().string(from: $0) } ?? "never",
            "X-EliteSIP-Unclean-Exit": previousSessionEndedUncleanly ? "1" : "0",
        ]
    }
}
