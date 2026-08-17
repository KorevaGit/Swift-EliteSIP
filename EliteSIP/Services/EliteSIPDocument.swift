import Foundation
import SIPCore

/// Файлы, которыми обмениваются рабочие места: предустановка и конфигурация.
///
/// Появились в этапе 9. До него выгрузка предустановки была, а загрузки **не
/// было нигде** — заявленный в M8 путь «настроить одну машину, снять шаблон,
/// разнести по остальным» обрывался на середине.
///
/// **Две разные сущности, и путать их нельзя.**
///
/// - `preset` — шаблон отдела: настройки без номера, без пароля SIP и без блока
///   доступа. Им заводят **новое** рабочее место.
/// - `config` — полный слепок машины, включая добавочный и пароль. Им
///   **переносят** рабочее место человека на новый компьютер.
///
/// **Свой тип документа, внутри JSON.** Расширение своё, заголовок свой, а
/// содержимое — обычный `Codable`, тот же, что в `settings.json`. Двоичный
/// формат рассматривался и отклонён: `AppSettings` объявлен плоским `Codable` с
/// версией схемы именно затем, чтобы конфигурацию можно было сгенерировать
/// снаружи — EliteDash (M9) и баш-скрипт провижининга оба на это опираются.
/// Свой сериализатор пришлось бы везти в EliteDash, а на bash конфиг не
/// собрался бы вовсе.
enum EliteSIPDocument {

    /// Расширение файла. Без точки — так его ждут `NSOpenPanel` и `NSSavePanel`.
    static let fileExtension = "elitesip"

    /// Версия формата файла. Не то же, что `AppSettings.schemaVersion`: та
    /// описывает настройки внутри, эта — саму обёртку.
    static let currentVersion = 1

    /// Что лежит в файле.
    enum Kind: String, Codable, Sendable {
        case preset = "elitesip.preset"
        case config = "elitesip.config"
    }

    /// Прочитанное содержимое.
    enum Content {
        case preset(SettingsPreset)
        case config(AppSettings)
    }

    /// Почему файл не прочитался.
    ///
    /// Отдельный тип, а не `localizedDescription` от декодера: «файл не от
    /// нашего приложения» и «файл от версии новее нашей» — это разные советы
    /// человеку, а `JSONDecoder` про оба говорит одинаково невнятно.
    enum Failure: Error {
        case notEliteSIP
        case futureVersion(Int)
        case damaged

        var title: String {
            switch self {
            case .notEliteSIP:
                return NSLocalizedString(
                    "Это не файл EliteSIP.",
                    comment: "чужой файл выбран для загрузки"
                )
            case .futureVersion(let version):
                return String(
                    format: NSLocalizedString(
                        "Файл сделан версией новее этой (формат %d). Обновите приложение.",
                        comment: "файл новее, чем приложение"
                    ),
                    version
                )
            case .damaged:
                return NSLocalizedString(
                    "Файл повреждён и не читается.",
                    comment: "битый файл выбран для загрузки"
                )
            }
        }
    }

    // MARK: - Запись

    static func encode(preset: SettingsPreset) throws -> Data {
        try encode(Envelope(kind: .preset, preset: preset, settings: nil))
    }

    static func encode(config settings: AppSettings) throws -> Data {
        try encode(Envelope(kind: .config, preset: nil, settings: settings))
    }

    /// Имя файла по умолчанию в окне сохранения.
    static func suggestedName(_ kind: Kind, label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = trimmed.isEmpty ? defaultStem(kind) : trimmed
        return "\(stem).\(fileExtension)"
    }

    private static func defaultStem(_ kind: Kind) -> String {
        switch kind {
        case .preset: return NSLocalizedString("Предустановка", comment: "имя файла предустановки")
        case .config: return NSLocalizedString("Конфигурация", comment: "имя файла конфигурации")
        }
    }

    private static func encode(_ envelope: Envelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(envelope)
    }

    // MARK: - Чтение

    /// Читает файл, отбивая чужой и слишком новый по заголовку.
    ///
    /// Заголовок проверяется **до** разбора содержимого: чужой JSON того же
    /// вида иначе прочитался бы терпимыми декодерами `AppSettings` в пустые
    /// настройки, и «файл не наш» выглядело бы как «файл пустой».
    static func read(_ data: Data) throws -> Content {
        let decoder = JSONDecoder()

        guard let header = try? decoder.decode(Header.self, from: data),
            let kind = Kind(rawValue: header.format)
        else { throw Failure.notEliteSIP }

        guard header.version <= currentVersion else {
            throw Failure.futureVersion(header.version)
        }

        guard let envelope = try? decoder.decode(Envelope.self, from: data) else {
            throw Failure.damaged
        }

        switch kind {
        case .preset:
            guard let preset = envelope.preset else { throw Failure.damaged }
            // Чистку делает сам `SettingsPreset` на чтении — секрет из чужого
            // шаблона не должен доехать только потому, что его туда вписали.
            return .preset(preset)

        case .config:
            guard let settings = envelope.settings else { throw Failure.damaged }
            return .config(machineIndependent(settings))
        }
    }

    /// Убирает из слепка всё, что принадлежит **той** машине, а не рабочему месту.
    ///
    /// Четыре вещи, и у каждой своя причина:
    ///
    /// - **UID звуковых устройств** — это uid конкретной железки. На новой
    ///   машине он указывает в никуда, а `nil` означает «системное устройство по
    ///   умолчанию» — единственный верный ответ для машины, которую ещё никто не
    ///   видел.
    /// - **Путь к своему рингтону** — путь, а не звук: файла по нему на новой
    ///   машине нет, и обнаружилось бы это на первом входящем.
    /// - **Тема и стекло** — их спрашивает мастер экранами 3 и 4.
    /// - **Блок доступа** — административный пароль всегда берётся из вшитого
    ///   конфига. Иначе слепок с машины, где пароль правили руками, увёз бы её
    ///   пароль на новую, и та встала бы с паролем, которого нет ни у кого.
    private static func machineIndependent(_ settings: AppSettings) -> AppSettings {
        var result = settings
        result.audio.inputDeviceUID = nil
        result.audio.outputDeviceUID = nil
        result.ringtone.customSoundPath = nil
        result.appearance = AppSettings.default.appearance
        result.plainChrome = AppSettings.default.plainChrome
        result.admin = AppSettings.AdminSettings()
        return result
    }

    // MARK: - Обёртка

    /// Только заголовок — читается первым и отдельно.
    private struct Header: Decodable {
        var format: String
        var version: Int
    }

    private struct Envelope: Codable {
        var format: String
        var version: Int
        var preset: SettingsPreset?
        var settings: AppSettings?

        init(kind: Kind, preset: SettingsPreset?, settings: AppSettings?) {
            self.format = kind.rawValue
            self.version = EliteSIPDocument.currentVersion
            self.preset = preset
            self.settings = settings
        }
    }
}
