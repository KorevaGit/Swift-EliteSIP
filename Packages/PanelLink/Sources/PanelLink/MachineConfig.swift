import CryptoKit
import Foundation

/// Конфигурация машины из Spark: кто за ней работает и с какими настройками.
///
/// Лежит на сервере обновлений как `config/<installation_id>`: оболочка
/// подписана Spark тем же ключом, что и файл предустановок, а содержимое
/// зашифровано под открытый ключ этой машины. Сервер обновлений прочитать её
/// не может — SIP-пароль на нём лежит только шифротекстом.
///
/// Приезжает каждый раз, когда в Spark правят место: номер, SIP-пароль,
/// подпись, формат, предустановку или пароль настроек. Машина применяет только
/// ревизию новее применённой.
///
/// `Codable` — ради мастера: полученная конфигурация переживает закрытое окно,
/// как раньше пакет активации.
public struct MachineConfig: Sendable, Equatable, Codable {

    /// Версия оболочки, которую понимает эта сборка. Более новую не разбираем:
    /// внутри учётные данные, и применять наполовину понятое нельзя.
    public static let supportedFormat = 1

    public var installationID: String
    public var revision: Int
    public var issuedAt: Date

    public var employee: String
    public var number: String
    public var sipPassword: String
    /// `office` или `remote`.
    public var workFormat: String
    public var presetID: String
    public var presetName: String
    /// Пароль «Управления». Пустой — у предустановки пароля нет.
    public var adminPassword: String

    public init(installationID: String, revision: Int, issuedAt: Date, employee: String, number: String,
                sipPassword: String, workFormat: String, presetID: String, presetName: String,
                adminPassword: String) {
        self.installationID = installationID
        self.revision = revision
        self.issuedAt = issuedAt
        self.employee = employee
        self.number = number
        self.sipPassword = sipPassword
        self.workFormat = workFormat
        self.presetID = presetID
        self.presetName = presetName
        self.adminPassword = adminPassword
    }

    /// Проверяет подпись, что конфигурация своя, и расшифровывает.
    ///
    /// - Parameter installationID: чью конфигурацию мы ждали. Подписанная
    ///   конфигурация чужой машины — это чужой SIP-пароль, и принимать её молча
    ///   нельзя, даже если канал её почему-то отдал.
    public static func verified(_ data: Data,
                                publicKey: Curve25519.Signing.PublicKey,
                                installationID: String,
                                keyPair: MachineKeyPair) throws -> MachineConfig {
        let payload = try SignedEnvelope.open(data, publicKey: publicKey)

        struct Envelope: Decodable {
            var format: Int
            var installation_id: String
            var revision: Int
            var issued_at: String
            var sealed: String
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: payload) else {
            throw PanelLinkError.malformedBundle
        }
        guard envelope.format <= supportedFormat else { throw PanelLinkError.configTooNew }
        guard envelope.installation_id == installationID else { throw PanelLinkError.malformedBundle }
        guard let sealed = Data(base64Encoded: envelope.sealed) else { throw PanelLinkError.malformedBundle }

        let plain = try keyPair.open(sealed)
        struct Wire: Decodable {
            var employee: String
            var number: String
            var sip_password: String
            var work_format: String
            var preset_id: String
            var preset_name: String
            var admin_password: String
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: plain) else {
            throw PanelLinkError.malformedBundle
        }
        return MachineConfig(
            installationID: envelope.installation_id,
            revision: envelope.revision,
            issuedAt: ISO8601DateFormatter().date(from: envelope.issued_at) ?? Date(),
            employee: wire.employee,
            number: wire.number,
            sipPassword: wire.sip_password,
            workFormat: wire.work_format,
            presetID: wire.preset_id,
            presetName: wire.preset_name,
            adminPassword: wire.admin_password
        )
    }
}
