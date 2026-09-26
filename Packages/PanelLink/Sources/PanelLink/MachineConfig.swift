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
    /// Все номера сотрудника, основной первым. Пусто — номер один, и он в
    /// `number`/`sipPassword`. Несколько бывает только у ручного профиля в
    /// Spark; на машине каждый номер становится своим профилем.
    public var lines: [Line]

    /// Номер сотрудника. `id` держится, пока номер живёт в Spark: по нему
    /// машина узнаёт свой профиль и не теряет его историю звонков.
    public struct Line: Sendable, Equatable, Codable {
        public var id: String
        public var number: String
        public var sipPassword: String
        public var label: String

        public init(id: String, number: String, sipPassword: String, label: String) {
            self.id = id
            self.number = number
            self.sipPassword = sipPassword
            self.label = label
        }
    }

    /// Номера, которые машина должна держать профилями: всегда хотя бы один.
    public var effectiveLines: [Line] {
        lines.isEmpty
            ? [Line(id: "main", number: number, sipPassword: sipPassword, label: employee)]
            : lines
    }

    public init(installationID: String, revision: Int, issuedAt: Date, employee: String, number: String,
                sipPassword: String, workFormat: String, presetID: String, presetName: String,
                adminPassword: String, lines: [Line] = []) {
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
        self.lines = lines
    }

    // Конфигурация, сохранённая сборкой без номеров, читается как с одним.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        installationID = try c.decode(String.self, forKey: .installationID)
        revision = try c.decode(Int.self, forKey: .revision)
        issuedAt = try c.decode(Date.self, forKey: .issuedAt)
        employee = try c.decode(String.self, forKey: .employee)
        number = try c.decode(String.self, forKey: .number)
        sipPassword = try c.decode(String.self, forKey: .sipPassword)
        workFormat = try c.decode(String.self, forKey: .workFormat)
        presetID = try c.decode(String.self, forKey: .presetID)
        presetName = try c.decode(String.self, forKey: .presetName)
        adminPassword = try c.decode(String.self, forKey: .adminPassword)
        lines = try c.decodeIfPresent([Line].self, forKey: .lines) ?? []
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
            var lines: [WireLine]?
        }
        struct WireLine: Decodable {
            var id: String
            var number: String
            var sip_password: String
            var label: String
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
            adminPassword: wire.admin_password,
            lines: (wire.lines ?? []).map {
                Line(id: $0.id, number: $0.number, sipPassword: $0.sip_password, label: $0.label)
            }
        )
    }
}
