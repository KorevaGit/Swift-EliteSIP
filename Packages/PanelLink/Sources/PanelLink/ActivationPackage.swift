import CommonCrypto
import CryptoKit
import Foundation

/// Пакет активации: всё, что нужно рабочему месту, одним зашифрованным файлом.
///
/// Приложение скачивает его по адресу, выведенному из ключа, и распечатывает
/// тем же ключом. Панель при этом ничего не знает о машине: она положила пакет
/// и забыла, а забрал его тот, у кого ключ.
public struct ActivationPackage: Sendable, Equatable {

    /// Версия формата, которую понимает эта сборка.
    ///
    /// Пакет более новой версии не разбирается вовсе, и это не упрямство: поля
    /// внутри — учётные данные, и применить наполовину понятый пакет означало
    /// бы поднять рабочее место наполовину.
    ///
    /// Правило зеркально файлу предустановок: там машина терпима и пропускает
    /// незнакомое, потому что обязана работать со старой сборкой. Здесь —
    /// строга, потому что это разовое действие под присмотром человека, и
    /// отказ с внятной причиной лучше половины настройки.
    public static let supportedFormat = 1

    /// Заголовок в начале шифротекста. Он же уходит в дополнительные данные
    /// AES-GCM: подменивший заголовок ломает проверку целостности.
    static let header = Data("ESIPA1".utf8)

    /// Число итераций PBKDF2.
    ///
    /// Взято у панели, а панель взяла его у `AdminAccess.KeyDerivation`. Argon2id
    /// здесь был бы уместнее, но его нет ни в CryptoKit, ни в CommonCrypto на
    /// Catalina, а тянуть ради него зависимость в однозависимое приложение
    /// нельзя — разбор в elitesip-site/docs/DECISIONS.md.
    static let iterations = 150_000

    public var format: Int
    public var installationID: String
    public var issuedAt: Date
    public var employee: String
    public var number: String
    public var sipPassword: String
    public var adminPassword: String
    public var preset: Preset

    /// Предустановка, приехавшая с пакетом.
    public struct Preset: Sendable, Equatable {
        public var id: String
        public var name: String
        public var revision: Int
        public var schemaVersion: Int

        /// Управляемые поля как есть, неразобранными.
        ///
        /// Разбирает их та же дорога, что и файл предустановок: правило
        /// «незнакомое пропускается, понятное применяется» должно быть одно на
        /// оба пути, а не два похожих.
        public var settings: Data
    }

    /// Распечатывает пакет.
    ///
    /// - Parameters:
    ///   - sealed: то, что скачали по адресу из ключа.
    ///   - key: ключ, который ввёл сотрудник.
    public static func open(sealed: Data, with key: ActivationKey) throws -> ActivationPackage {
        // Заголовок проверяется до всякой криптографии: пакет чужой версии надо
        // отличить от неподошедшего ключа, иначе человек пойдёт искать опечатку
        // в ключе вместо того, чтобы обновить приложение.
        guard sealed.count > header.count else { throw PanelLinkError.keyDidNotOpen }
        let head = sealed.prefix(header.count)
        guard head == header else {
            // Начало «ESIPA» с другой цифрой — это наш формат новее нашего.
            if head.starts(with: Data("ESIPA".utf8)) {
                throw PanelLinkError.packageTooNew
            }
            throw PanelLinkError.keyDidNotOpen
        }

        // Двенадцать байт nonce сразу за заголовком — как кладёт панель.
        let nonceStart = sealed.index(sealed.startIndex, offsetBy: header.count)
        let nonceEnd = sealed.index(nonceStart, offsetBy: 12, limitedBy: sealed.endIndex)
        guard let nonceEnd else { throw PanelLinkError.keyDidNotOpen }

        let nonceBytes = sealed[nonceStart..<nonceEnd]
        let body = sealed[nonceEnd...]
        // Метка целостности — последние шестнадцать байт.
        guard body.count > 16 else { throw PanelLinkError.keyDidNotOpen }

        let secret = try derive(key: key)

        let plaintext: Data
        do {
            let nonce = try AES.GCM.Nonce(data: nonceBytes)
            let ciphertext = body.prefix(body.count - 16)
            let tag = body.suffix(16)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            plaintext = try AES.GCM.open(box, using: SymmetricKey(data: secret),
                                         authenticating: header)
        } catch {
            // Сюда приходит и неверный ключ, и испорченный файл. Ответ один и
            // тот же — см. PanelLinkError.keyDidNotOpen.
            throw PanelLinkError.keyDidNotOpen
        }

        return try decode(plaintext)
    }

    /// Ключ шифрования из ключа активации.
    static func derive(key: ActivationKey) throws -> Data {
        let salt = key.salt
        let secretBytes = Array(key.canonical.utf8)
        var derived = Data(count: 32)

        let status: Int32 = derived.withUnsafeMutableBytes { output in
            salt.withUnsafeBytes { saltBuffer in
                secretBytes.withUnsafeBufferPointer { secretBuffer in
                    let pointer = secretBuffer.baseAddress.map {
                        UnsafeRawPointer($0).assumingMemoryBound(to: Int8.self)
                    }
                    return CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pointer,
                        secretBytes.count,
                        saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        output.bindMemory(to: UInt8.self).baseAddress,
                        32
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw PanelLinkError.keyDidNotOpen }
        return derived
    }

    /// Разбирает распечатанный JSON.
    static func decode(_ plaintext: Data) throws -> ActivationPackage {
        struct Wire: Decodable {
            var format: Int
            var installation_id: String
            var issued_at: String
            var employee: String
            var number: String
            var sip_password: String
            var admin_password: String
            var preset: WirePreset
        }
        struct WirePreset: Decodable {
            var id: String
            var name: String
            var revision: Int
            var schema_version: Int
            var settings: SettingsBlob
        }
        /// Управляемые поля не разбираются здесь, а сохраняются как есть.
        struct SettingsBlob: Decodable {
            var raw: Data
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                let any = try container.decode(AnyJSON.self)
                raw = try JSONSerialization.data(withJSONObject: any.value,
                                                 options: [.sortedKeys])
            }
        }

        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: plaintext)
        } catch {
            // Ключ подошёл — расшифровка сошлась, — а содержимое не разобралось.
            // Значит панель новее нас или пакет собран не тем.
            throw PanelLinkError.packageTooNew
        }

        guard wire.format <= supportedFormat else { throw PanelLinkError.packageTooNew }

        let formatter = ISO8601DateFormatter()
        return ActivationPackage(
            format: wire.format,
            installationID: wire.installation_id,
            issuedAt: formatter.date(from: wire.issued_at) ?? Date(),
            employee: wire.employee,
            number: wire.number,
            sipPassword: wire.sip_password,
            adminPassword: wire.admin_password,
            preset: Preset(
                id: wire.preset.id,
                name: wire.preset.name,
                revision: wire.preset.revision,
                schemaVersion: wire.preset.schema_version,
                settings: wire.preset.settings.raw
            )
        )
    }
}
