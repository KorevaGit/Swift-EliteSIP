import CryptoKit
import Foundation

/// Пакет активации: всё, что нужно рабочему месту, одним зашифрованным файлом.
///
/// Приложение скачивает его по адресу, выведенному из ключа, и распечатывает
/// тем же ключом. Панель при этом ничего не знает о машине: она положила пакет
/// и забыла, а забрал его тот, у кого ключ.
/// `Codable` — не для канала: по нему пакет ездит своим форматом, зашифрованным
/// и с заголовком, а разбирают его `Wire` ниже. Это для черновика мастера:
/// распечатанный пакет ложится на диск до конца настройки, потому что ключ
/// сгорает в тот же миг, когда его проверили, — см. `ActivationDraftStore`.
public struct ActivationPackage: Sendable, Equatable, Codable {

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
    public static let supportedFormat = 2

    /// Заголовок в начале шифротекста. Он же уходит в дополнительные данные
    /// AES-GCM: подменивший заголовок ломает проверку целостности.
    ///
    /// Вторая версия — разбор 25 августа 2026: изменился и вывод ключа, и
    /// состав содержимого.
    static let header = Data("ESIPA2".utf8)

    public var format: Int
    public var installationID: String

    /// Помашинный ключ доступа к каналу раздачи.
    ///
    /// С него начинается всё, что машина получает после активации: файл
    /// предустановок, свой административный пароль и проверка отзыва. Общая
    /// пара из бандла открывает теперь только выпуски — поэтому уволенный с
    /// копией `.app` тянет обновления и не тянет настройки конторы.
    ///
    /// **Панель убирает его на своей стороне — и машина перестаёт получать что
    /// бы то ни было.** Отсюда и взялся отзыв как техническое действие.
    public var channelKey: String

    public var issuedAt: Date
    public var employee: String
    public var number: String
    public var sipPassword: String

    /// Административного пароля здесь нет.
    ///
    /// Он стал полем предустановки и приезжает отдельным помашинным объектом —
    /// `MachineAccess`. Держать его ещё и в пакете значило бы завести второй
    /// источник одного факта: пакет выдаётся один раз, а пароль меняют когда
    /// угодно после.
    public var preset: Preset

    /// Предустановка, приехавшая с пакетом.
    public struct Preset: Sendable, Equatable, Codable {
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
    ///   - key: материал ключа, которым же посчитан и адрес. Одна прогонка на
    ///     оба применения — см. `BoundActivationKey`.
    public static func open(sealed: Data, with key: BoundActivationKey) throws -> ActivationPackage {
        // Заголовок проверяется до всякой криптографии: пакет чужой версии надо
        // отличить от неподошедшего ключа, иначе человек пойдёт искать опечатку
        // в ключе вместо того, чтобы обновить приложение.
        guard sealed.count > header.count else { throw PanelLinkError.keyDidNotOpen }
        let head = sealed.prefix(header.count)
        guard head == header else {
            // Начало «ESIPA» с другой цифрой — это наш формат, но не наша
            // версия. Новее — приложение отстало и его надо обновить; старее —
            // отстала панель, и обновление приложения делу не поможет. Второе
            // возможно, пока в конторе не выложили новую панель, и говорить в
            // этом случае «обновите приложение» значит отправить человека не
            // туда.
            if head.starts(with: Data("ESIPA".utf8)),
               let theirs = head.last, let ours = header.last {
                throw theirs > ours ? PanelLinkError.packageTooNew : PanelLinkError.keyDidNotOpen
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

        let plaintext: Data
        do {
            let nonce = try AES.GCM.Nonce(data: nonceBytes)
            let ciphertext = body.prefix(body.count - 16)
            let tag = body.suffix(16)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            plaintext = try AES.GCM.open(box, using: SymmetricKey(data: key.cipherKey),
                                         authenticating: header)
        } catch {
            // Сюда приходит и неверный ключ, и испорченный файл. Ответ один и
            // тот же — см. PanelLinkError.keyDidNotOpen.
            throw PanelLinkError.keyDidNotOpen
        }

        return try decode(plaintext)
    }

    /// Разбирает распечатанный JSON.
    static func decode(_ plaintext: Data) throws -> ActivationPackage {
        struct Wire: Decodable {
            var format: Int
            var installation_id: String
            var channel_key: String
            var issued_at: String
            var employee: String
            var number: String
            var sip_password: String
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
            channelKey: wire.channel_key,
            issuedAt: formatter.date(from: wire.issued_at) ?? Date(),
            employee: wire.employee,
            number: wire.number,
            sipPassword: wire.sip_password,
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
