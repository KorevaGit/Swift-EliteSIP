import AdminAccess
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
    ///
    /// 1 — конфигурация лежала открытым JSON. 2 — она запечатана кодом
    /// восстановления (`RecoveryCodeSeal`). Первую версию мы по-прежнему
    /// читаем: файлы её выпуска существуют, и отказ им означал бы потерянный
    /// перенос рабочего места на ровном месте. Пишем только вторую.
    ///
    /// Приложение прежней сборки, встретив вторую версию, скажет «файл сделан
    /// версией новее этой» — проверка для того и стоит до разбора содержимого.
    static let currentVersion = 2

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
        /// Файл запечатан не тем кодом, каким открывают здесь.
        ///
        /// Отдельно от `damaged`, потому что совет человеку разный: битый файл
        /// надо снять заново, а этот — принесён из конторы с другим кодом
        /// провижининга, и «снимите заново» ему не поможет.
        case sealedByAnotherCode

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
            case .sealedByAnotherCode:
                return NSLocalizedString(
                    "Файл сделан для другой установки EliteSIP и здесь не открывается.",
                    comment: "файл запечатан чужим кодом восстановления"
                )
            }
        }
    }

    // MARK: - Запись

    /// Предустановка пишется открытым текстом, и это не забывчивость.
    ///
    /// Секретов в ней нет по построению: `SettingsPreset` снимает пароль,
    /// номер и весь блок доступа ещё при создании снимка. Шифровать шаблон
    /// отдела, в котором лежат макросы и номера очередей, значило бы добавить
    /// возню на пустом месте — и заодно лишить администратора возможности
    /// заглянуть в файл глазами перед тем, как разослать его по местам.
    static func encode(preset: SettingsPreset) throws -> Data {
        try encode(Envelope(kind: .preset, preset: preset, sealed: nil))
    }

    /// Конфигурация запечатывается: в ней пароль от добавочного.
    ///
    /// Заголовок остаётся читаемым — по нему `read` отличает чужой файл от
    /// нашего и старую версию от новой, и делает это до того, как возьмётся за
    /// содержимое.
    static func encode(config settings: AppSettings) throws -> Data {
        // Блок доступа не уезжает вовсе, хотя шифрование его и прикрыло бы:
        // читающая сторона его всё равно выбрасывает (`machineIndependent`),
        // административный пароль всегда берётся из вшитого конфига, и
        // запечатанный мёртвый секрет остаётся секретом, который незачем
        // возить.
        var portable = settings
        portable.admin = AppSettings.AdminSettings()

        let payload = try JSONEncoder().encode(portable)
        let sealed = try RecoveryCodeSeal.seal(payload, code: Provisioning.recoveryCode)
        return try encode(Envelope(kind: .config, preset: nil, sealed: sealed))
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
            return .config(machineIndependent(try settings(from: envelope)))
        }
    }

    /// Настройки из обёртки любой из двух версий.
    ///
    /// Первая версия несла их открытым JSON, вторая — запечатанными. Читаются
    /// обе: файлы первой версии существуют, и отказ им означал бы потерянный
    /// перенос рабочего места из-за нашего же обновления.
    private static func settings(from envelope: Envelope) throws -> AppSettings {
        if let sealed = envelope.sealed {
            let opened: Data
            do {
                opened = try sealed.open(code: Provisioning.recoveryCode)
            } catch {
                // Открыть не вышло. Причин ровно две — чужой код провижининга
                // или испорченные байты, — и различить их нечем: тег GCM
                // ломается одинаково. Говорим о более полезной для человека:
                // битый файл он снимет заново и получит то же самое, а про
                // чужую установку хотя бы поймёт, куда идти.
                throw Failure.sealedByAnotherCode
            }
            guard let settings = try? JSONDecoder().decode(AppSettings.self, from: opened) else {
                throw Failure.damaged
            }
            return settings
        }

        guard let settings = envelope.settings else { throw Failure.damaged }
        return settings
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

        /// Конфигурация, запечатанная кодом. Версия 2 и новее.
        var sealed: RecoveryCodeSeal?

        /// Конфигурация открытым текстом. Только версия 1 — читается, но
        /// больше не пишется.
        var settings: AppSettings?

        init(kind: Kind, preset: SettingsPreset?, sealed: RecoveryCodeSeal?) {
            self.format = kind.rawValue
            self.version = EliteSIPDocument.currentVersion
            self.preset = preset
            self.sealed = sealed
            self.settings = nil
        }
    }
}
