import CryptoKit
import Foundation

/// Конверт, в котором панель выкладывает всё подписанное.
///
/// Один и тот же у файла предустановок, у помашинного доступа и у отзыва — и
/// это решение, а не совпадение. Второй конверт означал бы вторую проверку
/// подписи в приложении, то есть второе место, где её можно однажды не сделать.
///
/// Подпись считается по **байтам** `payload`, а сам он лежит рядом как есть.
/// Так проверка не зависит ни от канонизации JSON, ни от того, как посредник
/// переставит ключи: подписано ровно то, что прочитано.
enum SignedEnvelope {

    /// Достаёт содержимое, если подпись сошлась.
    static func open(_ data: Data, publicKey: Curve25519.Signing.PublicKey) throws -> Data {
        struct Envelope: Decodable {
            var payload: String
            var signature: String
        }

        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let payload = Data(base64Encoded: envelope.payload),
              let signature = Data(base64Encoded: envelope.signature)
        else {
            throw PanelLinkError.malformedBundle
        }

        guard publicKey.isValidSignature(signature, for: payload) else {
            throw PanelLinkError.signatureDidNotMatch
        }
        return payload
    }
}

/// Помашинный доступ: то, что принадлежит одной машине и не может лежать в
/// общем файле предустановок.
///
/// Административный пароль — поле предустановки, а у техподдержки предустановка
/// своя. Положи пароль в общий файл — и любой оператор прочитает пароль
/// поддержки в собственном скачанном файле, а разделение станет мнимым.
public struct MachineAccess: Sendable, Equatable {

    public static let supportedFormat = 1

    public var installationID: String
    public var presetID: String
    public var adminPassword: String
    public var issuedAt: Date

    /// Проверяет подпись и разбирает.
    ///
    /// - Parameter installationID: чей доступ мы ожидали получить. Совпадение
    ///   проверяется здесь, а не только на стороне Worker'а: подписанный объект
    ///   чужой машины — это чужой административный пароль, и принимать его
    ///   молча нельзя, даже если канал его почему-то отдал.
    public static func verified(_ data: Data,
                                publicKey: Curve25519.Signing.PublicKey,
                                installationID: String) throws -> MachineAccess {
        let payload = try SignedEnvelope.open(data, publicKey: publicKey)

        struct Wire: Decodable {
            var format: Int
            var installation_id: String
            var preset_id: String
            var admin_password: String
            var issued_at: String
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: payload) else {
            throw PanelLinkError.malformedBundle
        }
        guard wire.format <= supportedFormat else { throw PanelLinkError.bundleTooNew }
        guard wire.installation_id == installationID else { throw PanelLinkError.malformedBundle }

        return MachineAccess(
            installationID: wire.installation_id,
            presetID: wire.preset_id,
            adminPassword: wire.admin_password,
            issuedAt: ISO8601DateFormatter().date(from: wire.issued_at) ?? Date()
        )
    }
}

/// Отзыв: единственное, что запускает сброс машины.
///
/// **Подписанный, и только подписанный.** Сброс по отказу в доступе означал бы,
/// что опечатка в правиле Cloudflare, протухший секрет Worker'а или
/// оборвавшаяся уборка стирают не одну машину, а все тридцать разом. Отсутствие
/// ответа никогда не означает отзыв: машина, не достучавшаяся до канала,
/// работает дальше.
public struct Revocation: Sendable, Equatable {

    public static let supportedFormat = 1

    public var installationID: String
    public var revokedAt: Date

    public static func verified(_ data: Data,
                                publicKey: Curve25519.Signing.PublicKey,
                                installationID: String) throws -> Revocation {
        let payload = try SignedEnvelope.open(data, publicKey: publicKey)

        struct Wire: Decodable {
            var format: Int
            var installation_id: String
            var revoked_at: String
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: payload) else {
            throw PanelLinkError.malformedBundle
        }
        guard wire.format <= supportedFormat else { throw PanelLinkError.bundleTooNew }

        // Отзыв чужой машины — не наше дело. Совпадение обязательно: иначе
        // подсунутый объект соседней машины сбрасывал бы эту.
        guard wire.installation_id == installationID else { throw PanelLinkError.malformedBundle }

        return Revocation(
            installationID: wire.installation_id,
            revokedAt: ISO8601DateFormatter().date(from: wire.revoked_at) ?? Date()
        )
    }
}
