import CryptoKit
import Foundation

/// Файл предустановок: то, чем панель правит уже настроенные рабочие места.
///
/// Отдельная от Sparkle линия, для данных, а не для кода. Приложение опрашивает
/// её тем же таймером, что и обновления, проверяет подпись и применяет.
///
/// **Подпись проверяется до разбора содержимого.** Не после и не «заодно»:
/// проверка идёт по байтам `payload` как они пришли, поэтому не зависит ни от
/// канонизации JSON, ни от того, как посредник переставит ключи. Разбирать
/// сначала значило бы подписывать своё представление о файле, а не файл.
public struct PresetBundle: Sendable, Equatable {

    /// Версия формата, которую понимает эта сборка.
    public static let supportedFormat = 1

    public var format: Int
    public var generatedAt: Date
    public var presets: [Entry]

    /// Одна предустановка в файле.
    public struct Entry: Sendable, Equatable {
        /// Машина ищет себя по нему, а **не по имени**: имя переименовывают, и
        /// поиск по нему разорвал бы связь у всех машин разом.
        public var id: String
        public var name: String
        public var revision: Int
        public var schemaVersion: Int

        /// Управляемые поля как есть — разбирает их приложение.
        public var fields: Data
    }

    /// Проверяет подпись и разбирает файл.
    ///
    /// - Parameters:
    ///   - data: то, что скачали с канала.
    ///   - publicKey: открытый ключ линии предустановок из `Info.plist`.
    public static func verified(_ data: Data, publicKey: Curve25519.Signing.PublicKey) throws -> PresetBundle {
        // Конверт общий с помашинными объектами — см. SignedEnvelope.
        return try decode(SignedEnvelope.open(data, publicKey: publicKey))
    }

    /// Разбирает уже проверенное содержимое.
    static func decode(_ payload: Data) throws -> PresetBundle {
        struct Wire: Decodable {
            var format: Int
            var generated_at: String
            var presets: [WireEntry]
        }
        struct WireEntry: Decodable {
            var id: String
            var name: String
            var revision: Int
            var schema_version: Int
            var fields: FieldsBlob
        }
        struct FieldsBlob: Decodable {
            var raw: Data
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                let any = try container.decode(AnyJSON.self)
                raw = try JSONSerialization.data(withJSONObject: any.value, options: [.sortedKeys])
            }
        }

        guard let wire = try? JSONDecoder().decode(Wire.self, from: payload) else {
            throw PanelLinkError.malformedBundle
        }
        guard wire.format <= supportedFormat else { throw PanelLinkError.bundleTooNew }

        let formatter = ISO8601DateFormatter()
        return PresetBundle(
            format: wire.format,
            generatedAt: formatter.date(from: wire.generated_at) ?? Date(),
            presets: wire.presets.map {
                Entry(id: $0.id, name: $0.name, revision: $0.revision,
                      schemaVersion: $0.schema_version, fields: $0.fields.raw)
            }
        )
    }

    /// Своя запись в файле.
    ///
    /// По `id`, а не по имени — см. `Entry.id`. Отсутствие себя в файле не
    /// ошибка: предустановку могли заархивировать, и машина продолжает работать
    /// с тем, что применила раньше.
    public func entry(id: String) -> Entry? {
        presets.first { $0.id == id }
    }
}
