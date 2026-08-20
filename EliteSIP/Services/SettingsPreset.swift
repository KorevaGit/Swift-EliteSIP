import Foundation
import SIPCore

/// Сохранённая копия настроек рабочего места.
///
/// Отвечает на «как настроено рабочее место такого-то отдела», а не «чьё оно».
/// Администратор снимает предустановку с настроенной машины один раз, а дальше
/// на каждом следующем месте выбирает её и вписывает номер — всё остальное
/// приезжает готовым: кнопки макросов, очереди, правила приёма вызова, адрес
/// АТС, стук, журнал.
///
/// **Чего в снимке нет.** Номера, пароля SIP и всего блока административного
/// доступа целиком.
/// Причина не в объёме, а в том, что предустановка ходит между машинами: номер
/// у каждого места свой по определению, а пароль, размноженный по десятку
/// рабочих мест из одного шаблона, перестаёт быть паролем. Логин отдельно тоже
/// не хранится — он дублируется с номера при применении.
///
/// Список предустановок из снимка вычищается обязательно: без этого снимок
/// содержал бы сам себя, и файл настроек рос бы вдвое на каждом сохранении.
struct SettingsPreset: Identifiable, Codable, Equatable, Sendable {

    var id: UUID
    var name: String

    /// Настройки целиком — уже без номера, паролей и вложенных предустановок.
    var snapshot: AppSettings

    /// Когда снята. Показывается в списке: две предустановки с похожими
    /// именами различают по дате, а не по угадыванию.
    var createdAt: Date

    init(id: UUID = UUID(), name: String, snapshot: AppSettings, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.snapshot = SettingsPreset.stripped(snapshot)
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        snapshot = try container.decode(AppSettings.self, forKey: .snapshot)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        // Чистка повторяется на чтении, а не только на записи: файл могли
        // подложить руками, и секрет из чужого шаблона не должен доехать до
        // машины только потому, что его туда вписали.
        snapshot = SettingsPreset.stripped(snapshot)
    }

    /// Убирает из снимка всё, чему в шаблоне не место.
    private static func stripped(_ settings: AppSettings) -> AppSettings {
        var result = settings
        result.presets = []
        // Происхождение принадлежит машине, а не шаблону: иначе снимок,
        // снятый с настроенного места, объявлял бы каждое следующее место
        // заведённым по той предустановке, по которой заведено оно само.
        result.appliedPresetName = ""
        result.appliedPresetAt = nil
        // Весь блок доступа, а не одно поле: пароль администратора — единственный
        // секрет, который в шаблоне опаснее всего, и полагаться на то, что мы
        // помним все его поля, нельзя. Появится второе — оно тоже не уедет.
        result.admin = AppSettings.AdminSettings()
        result.profiles = SIPProfileList(profiles: [template(of: settings.profiles.active)])
        return result
    }

    /// Профиль без того, что принадлежит конкретному месту.
    ///
    /// Из всего списка берётся только активный: шаблон описывает одно рабочее
    /// место, а не чужой набор добавочных. Метка остаётся — по ней предустановку
    /// и узнают в списке профилей («Менеджер», «Секретарь»).
    private static func template(of profile: SIPProfile) -> SIPProfile {
        var result = profile
        result.password = ""
        result.account.username = ""
        result.account.authUsername = nil
        return result
    }

    /// Профиль этого шаблона с подставленным номером.
    ///
    /// Логин дублируется с номера, а не хранится отдельно: у добавочного они
    /// совпадают, а отдельное поле в шаблоне означало бы один логин на все
    /// места, заведённые из него.
    func profile(number: String, keeping existing: SIPProfile?) -> SIPProfile {
        var result = snapshot.profiles.active
        // Идентификатор и пароль — существующего профиля, если применяем к
        // нему: предустановка не знает ни того, ни другого, и стереть пароль
        // настроенного места она не должна.
        result.id = existing?.id ?? UUID()
        result.password = existing?.password ?? ""
        result.account.username = number
        result.account.authUsername = nil
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, snapshot, createdAt
    }
}
