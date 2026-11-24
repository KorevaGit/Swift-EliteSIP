import CryptoKit
import Foundation

/// Просьба Spark собрать архив журналов для техподдержки.
///
/// Подписанная, как отзыв: по неподписанной машина отправляла бы свои журналы
/// любому, кто сумел положить объект по её адресу. Идентификатор запроса —
/// 32 знака hex: он же имя архива на сервере, и сервер принимает архив только
/// на тот запрос, что лежит для этой машины сейчас. Формат общий с Windows- и
/// Linux-версиями.
public struct SupportRequest: Sendable, Equatable {

    public static let supportedFormat = 1

    public var installationID: String
    public var requestID: String
    public var requestedAt: Date
    public var expiresAt: Date

    public static func verified(_ data: Data,
                                publicKey: Curve25519.Signing.PublicKey,
                                installationID: String) throws -> SupportRequest {
        let payload = try SignedEnvelope.open(data, publicKey: publicKey)

        struct Wire: Decodable {
            var format: Int
            var installation_id: String
            var request_id: String
            var requested_at: String?
            var expires_at: String?
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: payload),
              isRequestID(wire.request_id)
        else {
            throw PanelLinkError.malformedBundle
        }
        guard wire.format <= supportedFormat else { throw PanelLinkError.bundleTooNew }

        // Запрос чужой машины — не наш: отправили бы свои журналы на чужой запрос.
        guard wire.installation_id == installationID else { throw PanelLinkError.malformedBundle }

        return SupportRequest(
            installationID: wire.installation_id,
            requestID: wire.request_id,
            requestedAt: wire.requested_at.flatMap(timestamp) ?? Date(),
            // Без срока запрос считается истёкшим: отправлять по нему нечего.
            expiresAt: wire.expires_at.flatMap(timestamp) ?? .distantPast
        )
    }

    /// Время ISO 8601 — с долями секунды и без. От срока зависит, уйдёт ли
    /// архив, а Go пишет доли, когда они есть (`RFC3339Nano`): обычный
    /// `ISO8601DateFormatter` такую строку не разбирает, и запрос молча
    /// считался бы истёкшим.
    static func timestamp(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    /// Ровно 32 знака строчного hex — имя идёт в адрес и в имя файла.
    static func isRequestID(_ text: String) -> Bool {
        text.utf8.count == 32 && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}
