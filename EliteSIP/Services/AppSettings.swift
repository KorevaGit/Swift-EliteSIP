import AdminAccess
import AppKit
import CallGuard
import CallHistory
import Diagnostics
import Foundation
import MediaCore
import SIPCore

/// Всё, что приложение помнит между запусками, кроме пароля.
///
/// Один плоский `Codable` с версией схемы — под будущую синхронизацию с
/// EliteDash и баш-скрипт провижининга: им нужен предсказуемый формат, который
/// можно сгенерировать снаружи и положить в файл.
struct AppSettings: Codable, Sendable, Equatable {

    /// Версия схемы. Растёт, когда формат меняется несовместимо.
    ///
    /// 1 — единственный `account`. 2 — список профилей с активным (M7b).
    static let currentSchemaVersion = 2

    var schemaVersion: Int = AppSettings.currentSchemaVersion

    /// Сохранённые учётные записи. Зарегистрирован одновременно ровно один
    /// профиль — активный.
    var profiles: SIPProfileList
    var audio: AudioSettings = AudioSettings()

    /// Защита приёма вызова от автокликеров.
    ///
    /// Ключ в файле остался прежним (`incomingCall`): у `CallGuardPolicy` те же
    /// три поля, что были у настроек окна, а остальные её декодер добирает
    /// значениями по умолчанию. Файл настроек от обновления не пострадает.
    var incomingCall: CallGuardPolicy
    var ringtone: RingtoneSettings = RingtoneSettings()
    var dtmf: DTMFSettings = DTMFSettings()
    var conference: ConferenceSettings = ConferenceSettings()
    var minimumLogLevel: SIPLogLevel

    /// Журнал в файле. Отдельно от `minimumLogLevel`: на экране нужен короткий,
    /// в файле — подробный.
    var logFile: LogFileSettings = LogFileSettings()

    /// Локальная история звонков: вести ли её и сколько дней хранить.
    ///
    /// Схема не выросла: старый файл читается терпимым декодером и получает
    /// умолчания — история включена, срок 30 дней. Версия растёт от
    /// несовместимости, а не от прибавления.
    var history: CallHistorySettings = CallHistorySettings()

    /// Светлая тема, тёмная или как в системе.
    ///
    /// Схема не выросла: старый файл читается терпимым декодером и получает
    /// `.system` — ровно прежнее поведение, когда приложение просто следовало
    /// за системой.
    var appearance: AppearanceSetting = .system

    /// Административный доступ: пароль и то, кто управляет настройками.
    ///
    /// Схема не выросла до 3, хотя поле новое: старый файл читается терпимым
    /// декодером и получает `AdminSettings()` — «пароль не задан, управляет
    /// администратор этой машины». Это ровно прежнее поведение, а версия схемы
    /// растёт от несовместимости, а не от прибавления.
    var admin: AdminSettings = AdminSettings()

    /// Доверять любому сертификату TLS активного профиля.
    ///
    /// Отключает защиту от подмены сервера: перехватчик увидит и пароль, и
    /// разговор. Существует ровно ради самоподписанного сертификата
    /// лаборатории на localhost. В бою должно быть выключено.
    ///
    /// Хранится в профиле, а не здесь: это свойство сервера. Общим на
    /// приложение оно оставалось включённым после переключения с лабораторного
    /// профиля на боевой — молча и ровно в том случае, ради которого его
    /// включали один раз.
    var acceptsAnyTLSCertificate: Bool {
        get { profiles.active.acceptsAnyTLSCertificate }
        set { profiles.active.acceptsAnyTLSCertificate = newValue }
    }

    /// Стук по портам для удалённого рабочего места.
    ///
    /// В интерфейс не выведено намеренно: сотруднику эту последовательность не
    /// объяснить и незачем — для него подключение должно просто работать, как
    /// оно «просто работало» со скриптом. Но в файле настроек она лежит и
    /// правится, потому что живёт на чужом шлюзе и может измениться без нас.
    var portKnock: PortKnockSequence = .production

    /// Пара адресов одной АТС: изнутри и снаружи. Смена рабочего места в
    /// профиле переписывает адрес по этой паре, иначе пометка ничего не решает.
    /// Пока зашита, потом приедет из EliteDash — как и `portKnock`.
    var siteAddresses: SIPSiteAddresses = .production

    /// Учётная запись активного профиля.
    ///
    /// Остальное приложение работает ровно с одной учёткой — той, которой
    /// сейчас регистрируются, — и после появления списка это не изменилось.
    /// Поэтому доступ к ней остался прежним свойством, а не разошёлся по коду
    /// цепочками `profiles.active.account`.
    var account: SIPAccount {
        get { profiles.active.account }
        set { profiles.active.account = newValue }
    }

    /// Пароль активного профиля — тем же коротким путём, что и учётка.
    ///
    /// Живёт в настройках, а не в связке ключей (решение от 5 августа 2026,
    /// см. `SIPProfile`): это часть настройки рабочего места, которую делает
    /// администратор, а не секрет того, кто за машиной сидит.
    var sipPassword: String {
        get { profiles.active.password }
        set { profiles.active.password = newValue }
    }

    /// Свой почленный инициализатор: наличие `init(from:)` отменяет
    /// синтезированный.
    init(
        schemaVersion: Int = AppSettings.currentSchemaVersion,
        profiles: SIPProfileList,
        audio: AudioSettings = AudioSettings(),
        incomingCall: CallGuardPolicy = CallGuardPolicy(),
        ringtone: RingtoneSettings = RingtoneSettings(),
        dtmf: DTMFSettings = DTMFSettings(),
        conference: ConferenceSettings = ConferenceSettings(),
        minimumLogLevel: SIPLogLevel = .info,
        logFile: LogFileSettings = LogFileSettings(),
        history: CallHistorySettings = CallHistorySettings(),
        admin: AdminSettings = AdminSettings(),
        acceptsAnyTLSCertificate: Bool = false,
        portKnock: PortKnockSequence = .production,
        siteAddresses: SIPSiteAddresses = .production
    ) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.audio = audio
        self.incomingCall = incomingCall
        self.ringtone = ringtone
        self.dtmf = dtmf
        self.conference = conference
        self.minimumLogLevel = minimumLogLevel
        self.logFile = logFile
        self.history = history
        self.admin = admin
        self.portKnock = portKnock
        self.siteAddresses = siteAddresses
        // После `profiles`: свойство живёт в активном профиле.
        self.acceptsAnyTLSCertificate = acceptsAnyTLSCertificate
    }

    /// Разбор терпим к отсутствующим полям.
    ///
    /// Синтезированный декодер этого не умеет: значение по умолчанию у свойства
    /// он игнорирует и падает на первом же незнакомом файле. А падение здесь —
    /// это молчаливый откат к пустым настройкам в `SettingsStore.load`, то есть
    /// потерянная учётная запись при обычном обновлении версии.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Прочитанная версия схемы наружу не выходит: файл, прочитанный
        // однажды, сохраняется уже во второй схеме. Держать в модели «версию,
        // которая была» значило бы записать её обратно и мигрировать ещё раз.
        _ = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        schemaVersion = AppSettings.currentSchemaVersion
        profiles = try AppSettings.decodedProfiles(from: decoder)
        audio = try container.decodeIfPresent(AudioSettings.self, forKey: .audio) ?? AudioSettings()
        incomingCall = try container.decodeIfPresent(
            CallGuardPolicy.self, forKey: .incomingCall
        ) ?? CallGuardPolicy()
        ringtone = try container.decodeIfPresent(RingtoneSettings.self, forKey: .ringtone) ?? RingtoneSettings()
        dtmf = try container.decodeIfPresent(DTMFSettings.self, forKey: .dtmf) ?? DTMFSettings()
        conference =
            try container.decodeIfPresent(ConferenceSettings.self, forKey: .conference)
                ?? ConferenceSettings()
        minimumLogLevel = try container.decodeIfPresent(SIPLogLevel.self, forKey: .minimumLogLevel) ?? .info
        // Файла настроек без этого ключа достаточно, чтобы журнал заработал:
        // умолчание включено. Диагностика, которую надо сперва включить, не
        // помогает там, где нужна, — жалоба всегда про то, что уже случилось.
        logFile = try container.decodeIfPresent(LogFileSettings.self, forKey: .logFile) ?? LogFileSettings()
        // Умолчание тоже включено, и по той же причине: историю открывают,
        // чтобы вспомнить уже состоявшийся звонок, а «сперва включите» на этот
        // вопрос не отвечает.
        history =
            try container.decodeIfPresent(CallHistorySettings.self, forKey: .history)
                ?? CallHistorySettings()
        // Испорченный блок доступа читается как «пароля нет», а не роняет весь
        // файл: иначе одна битая строка стоила бы учётной записи. Открытые
        // настройки на машине, где пароль был, заметят сразу — в отличие от
        // потерянного профиля.
        admin = (try? container.decodeIfPresent(AdminSettings.self, forKey: .admin)) ?? AdminSettings()
        portKnock =
            try container.decodeIfPresent(PortKnockSequence.self, forKey: .portKnock) ?? .production
        siteAddresses =
            try container.decodeIfPresent(SIPSiteAddresses.self, forKey: .siteAddresses) ?? .production

        // Доверие к сертификату переехало в профиль. Общий ключ старого файла
        // достаётся активному профилю, а не всем: включали его ради одного
        // сервера, и раздать его остальным значило бы размножить ровно ту
        // ошибку, из-за которой поле и переехало.
        let legacyTrust = try decoder.container(keyedBy: LegacyKeys.self)
        if let trusted = try legacyTrust.decodeIfPresent(
            Bool.self, forKey: .acceptsAnyTLSCertificate
        ), trusted, !profiles.active.acceptsAnyTLSCertificate {
            profiles.active.acceptsAnyTLSCertificate = true
        }
    }

    /// Ключи, которых в модели больше нет: схема 1 целиком и поля, переехавшие
    /// в профиль.
    ///
    /// Отдельным типом, а не лишними случаями в `CodingKeys`: синтезированный
    /// `encode(to:)` перебирает именно `CodingKeys`, и случай без хранимого
    /// свойства сломал бы синтез. Заодно видно, что ключ читается и не пишется.
    private enum LegacyKeys: String, CodingKey {
        case account
        case acceptsAnyTLSCertificate
    }

    /// Список профилей из файла любой из двух схем.
    ///
    /// Решает наличие ключа, а не номер версии: файл провижининга или правка
    /// руками вполне может нести профили при версии 1, и «мигрировать» такой
    /// файл значило бы выбросить всё, кроме первого профиля. Отсутствие обоих
    /// ключей — первый запуск, а не порча: получится один пустой профиль.
    private static func decodedProfiles(from decoder: Decoder) throws -> SIPProfileList {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let stored = try container.decodeIfPresent(SIPProfileList.self, forKey: .profiles) {
            return stored
        }
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        if let account = try legacy.decodeIfPresent(SIPAccount.self, forKey: .account) {
            return SIPProfileList(migrating: account)
        }
        return SIPProfileList()
    }

    /// Файловый журнал.
    ///
    /// Уровень отдельный от экранного и по умолчанию подробнее: на панели
    /// пятьсот строк живут в памяти и нужны для быстрого взгляда, а в файл
    /// пишется то, по чему потом разбирают жалобу. Разбирать «info» бесполезно —
    /// в нём нет ни кодов ответов, ни причин пересогласования.
    struct LogFileSettings: Codable, Sendable, Equatable {

        var isEnabled: Bool = true
        var minimumLevel: SIPLogLevel = .debug

        /// Потолок одного файла в мегабайтах.
        var maximumFileMegabytes: Int = 4

        /// Сколько отложенных файлов держим, не считая текущего.
        var keptFiles: Int = 5

        /// Сколько дней храним отложенные файлы. Записи содержат номера лидов,
        /// поэтому «хранить вечно» — решение не про диск.
        var maximumAgeInDays: Int = 14

        init(
            isEnabled: Bool = true,
            minimumLevel: SIPLogLevel = .debug,
            maximumFileMegabytes: Int = 4,
            keptFiles: Int = 5,
            maximumAgeInDays: Int = 14
        ) {
            self.isEnabled = isEnabled
            self.minimumLevel = minimumLevel
            self.maximumFileMegabytes = maximumFileMegabytes
            self.keptFiles = keptFiles
            self.maximumAgeInDays = maximumAgeInDays
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
            minimumLevel = try container.decodeIfPresent(SIPLogLevel.self, forKey: .minimumLevel) ?? .debug
            maximumFileMegabytes =
                try container.decodeIfPresent(Int.self, forKey: .maximumFileMegabytes) ?? 4
            keptFiles = try container.decodeIfPresent(Int.self, forKey: .keptFiles) ?? 5
            maximumAgeInDays = try container.decodeIfPresent(Int.self, forKey: .maximumAgeInDays) ?? 14
        }

        /// Приводит настройки к тому, что понимает `Diagnostics`, и заодно к
        /// разумным границам: значения приезжают из файла, который правит
        /// человек, и «ноль мегабайт» означал бы ротацию на каждой строке.
        var storage: LogFile.Settings {
            LogFile.Settings(
                directory: LogFileSettings.directory,
                maximumFileBytes: min(max(maximumFileMegabytes, 1), 64) * 1024 * 1024,
                keptFiles: min(max(keptFiles, 0), 50),
                maximumAgeInDays: min(max(maximumAgeInDays, 0), 365)
            )
        }

        /// `~/Library/Logs/EliteSIP` — то место, куда смотрят и Console, и
        /// человек, которого попросили прислать журнал. Настройки лежат в
        /// Application Support, но журналу там не место: это разные вещи по
        /// сроку жизни и по тому, кто их читает.
        static var directory: URL {
            let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            return base
                .appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent("EliteSIP", isDirectory: true)
        }
    }

    /// Локальная история звонков.
    ///
    /// Настройка закрытая, административная, и это не про удобство. В записях
    /// лежат номера лидов, то есть персональные данные, и «сколько мы их
    /// храним» — политика заказчика, а не привычка менеджера. Умолчание в
    /// 30 дней согласовано 3 августа 2026; в M8 то же значение приедет файлом
    /// конфигурации и перестанет зависеть от того, кто сидит за машиной.
    ///
    /// Ручного удаления записей в интерфейсе нет намеренно (там же). История
    /// нужна в том числе как свидетельство при разборе жалобы, а свидетельство,
    /// которое может убрать заинтересованная сторона, свидетельством не
    /// является. Уходят записи только по сроку.
    struct CallHistorySettings: Codable, Sendable, Equatable {

        /// Вести историю вообще.
        ///
        /// Выключатель существует ради машин, где хранить номера лидов нельзя
        /// вовсе. Выключение не стирает уже накопленное — стирает срок.
        var isEnabled: Bool = true

        var maximumAgeInDays: Int = 30

        init(isEnabled: Bool = true, maximumAgeInDays: Int = 30) {
            self.isEnabled = isEnabled
            self.maximumAgeInDays = maximumAgeInDays
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
            maximumAgeInDays = try container.decodeIfPresent(Int.self, forKey: .maximumAgeInDays) ?? 30
        }

        /// То же, что понимает `CallHistory`, и в тех же границах: значение
        /// приезжает из файла, который правит человек.
        var storage: CallHistoryStore.Settings {
            CallHistoryStore.Settings(
                fileURL: CallHistorySettings.fileURL,
                maximumAgeInDays: min(max(maximumAgeInDays, 1), 3650)
            )
        }

        /// Рядом с настройками, а не в `~/Library/Logs`.
        ///
        /// Журнал отдаёт в поддержку сам оператор, и туда его кладут именно
        /// поэтому. Историю в поддержку не отправляют никогда: это накопленные
        /// персональные данные со своим сроком жизни, и попадать в архив для
        /// поддержки заодно с журналом она не должна.
        static var fileURL: URL {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            return base
                .appendingPathComponent("EliteSIP", isDirectory: true)
                .appendingPathComponent("call-history.sqlite")
        }
    }

    /// Административный доступ, как он лежит в файле.
    ///
    /// Самого пароля здесь нет — только проверочное значение и запечатанная
    /// копия, которую открывает код восстановления. Устройство и цена решения —
    /// в пакете `AdminAccess`.
    struct AdminSettings: Codable, Sendable, Equatable {

        /// nil — пароль не задан, закрытая часть открыта всем.
        var credential: AdminCredential?

        /// Кто управляет закрытыми настройками. Пока всегда локально.
        var management: AdminManagement = .local

        init(credential: AdminCredential? = nil, management: AdminManagement = .local) {
            self.credential = credential
            self.management = management
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            credential = try container.decodeIfPresent(AdminCredential.self, forKey: .credential)
            management = try container.decodeIfPresent(AdminManagement.self, forKey: .management) ?? .local
        }
    }

    struct AudioSettings: Codable, Sendable, Equatable {

        /// Микрофон (`AudioDevice.uid`). nil — системный по умолчанию.
        ///
        /// Хранится именно uid, а не имя и не номер: номер HAL живёт до
        /// переподключения устройства, а имён «AirPods Pro» в доме может быть
        /// несколько.
        var inputDeviceUID: String?

        /// Устройство вывода. nil — системное по умолчанию.
        ///
        /// Если оно отличается от микрофона, тракт соберёт приватное агрегатное
        /// устройство — иначе macOS не даёт развести стороны.
        var outputDeviceUID: String?

        /// Отпускать звуковое устройство между звонками.
        ///
        /// Ради Bluetooth-гарнитур: пока микрофон открыт, AirPods работают в
        /// двустороннем режиме, и у всей системы приглушён звук. Выключать это
        /// имеет смысл только на проводной гарнитуре, где переключать нечего, а
        /// открыть устройство заново — лишние доли секунды в начале звонка.
        var releasesDeviceWhenIdle: Bool = true

        /// Предлагать широкую полосу (G.722).
        ///
        /// Против боевого Asterisk выключатель сейчас ни на что не влияет:
        /// сервер отвечает по своему порядку `allow` и всегда берёт G.711
        /// (решение M2c). Остаётся он ради двух случаев — прямого разговора со
        /// стороной, которая уважает наш порядок, и возможной смены настройки
        /// АТС. Значение по умолчанию оставлено включённым: предложить лишний
        /// кодек последним не стоит ничего.
        var prefersWideband: Bool = true

        /// Автоусиление в блоке обработки голоса.
        ///
        /// Система включает его сама, мы его сразу выключаем. На хорошей
        /// гарнитуре оно «дышит»: подтягивает шум в паузах и приседает на громком
        /// слоге. Эхоподавитель при выключенном AGC остаётся — это независимые
        /// блоки, так что цена решения нулевая, а вернуть его можно галочкой.
        var automaticGainControl: Bool = false

        init(
            inputDeviceUID: String? = nil,
            outputDeviceUID: String? = nil,
            releasesDeviceWhenIdle: Bool = true,
            prefersWideband: Bool = true,
            automaticGainControl: Bool = false
        ) {
            self.inputDeviceUID = inputDeviceUID
            self.outputDeviceUID = outputDeviceUID
            self.releasesDeviceWhenIdle = releasesDeviceWhenIdle
            self.prefersWideband = prefersWideband
            self.automaticGainControl = automaticGainControl
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            inputDeviceUID = try container.decodeIfPresent(String.self, forKey: .inputDeviceUID)
            outputDeviceUID = try container.decodeIfPresent(String.self, forKey: .outputDeviceUID)
            releasesDeviceWhenIdle =
                try container.decodeIfPresent(Bool.self, forKey: .releasesDeviceWhenIdle) ?? true
            prefersWideband = try container.decodeIfPresent(Bool.self, forKey: .prefersWideband) ?? true
            // Отсутствие ключа — это файл, записанный до продуктового решения
            // «AGC по умолчанию выключено». Возвращать там `true` значило бы
            // молча оставить прежним рабочим местам поведение, от которого
            // отказались; явно записанное значение пользователя уважается.
            automaticGainControl =
                try container.decodeIfPresent(Bool.self, forKey: .automaticGainControl) ?? false
        }
    }

    struct RingtoneSettings: Codable, Sendable, Equatable {

        var isEnabled: Bool = true

        /// Громкость, от 0 до 1.
        var volume: Double = 0.5

        /// Играть в системное устройство вывода, а не в выбранное для разговора.
        ///
        /// Смысл в гарнитуре: пока она лежит на столе, звонок нужно слышать
        /// колонками. А вот отдать рингтон в ту же гарнитуру полезно, когда она
        /// на голове, — поэтому это выбор, а не решение за пользователя.
        var usesSystemOutput: Bool = true

        /// Свой звук вместо синтезированного. nil — стандартный.
        ///
        /// Путь, а не закладка безопасности: App Sandbox выключен осознанно
        /// (см. `EliteSIP.entitlements`), и закладка здесь была бы обвязкой без
        /// причины. Пропавший файл не ломает звонок — рингтон молча возвращается
        /// к стандартному, потому что беззвучный входящий хуже неожиданного.
        var customSoundPath: String?

        init(
            isEnabled: Bool = true,
            volume: Double = 0.5,
            usesSystemOutput: Bool = true,
            customSoundPath: String? = nil
        ) {
            self.isEnabled = isEnabled
            self.volume = volume
            self.usesSystemOutput = usesSystemOutput
            self.customSoundPath = customSoundPath
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
            volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 0.5
            usesSystemOutput = try container.decodeIfPresent(Bool.self, forKey: .usesSystemOutput) ?? true
            customSoundPath = try container.decodeIfPresent(String.self, forKey: .customSoundPath)
        }

        /// Файл рингтона, если он задан и на месте.
        var customSoundURL: URL? {
            guard let customSoundPath, !customSoundPath.isEmpty else { return nil }
            let url = URL(fileURLWithPath: customSoundPath)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    /// Серверная конференция через dynamic feature Asterisk.
    ///
    /// Клиент не смешивает звук сам: код переводит оба плеча текущего Dial в
    /// одну комнату ConfBridge. Значение настраивается, потому что `*3` в
    /// лаборатории восстановлен по виду боевого кода, а не скопирован с боя.
    struct ConferenceSettings: Codable, Sendable, Equatable {

        var featureCode: String = "*3"

        /// Добавочный прямого входа в комнату. Нужен для проверки и станет
        /// целью третьей линии после появления многолинейного UI.
        var roomExtension: String = "8000"

        init(featureCode: String = "*3", roomExtension: String = "8000") {
            self.featureCode = featureCode
            self.roomExtension = roomExtension
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            featureCode = try container.decodeIfPresent(String.self, forKey: .featureCode) ?? "*3"
            roomExtension = try container.decodeIfPresent(String.self, forKey: .roomExtension) ?? "8000"
        }

        var command: DTMFSequence { DTMFSequence(featureCode) }

        var isUsable: Bool {
            command.hasTones
                && DTMFSequence.unsupportedCharacters(in: featureCode).isEmpty
        }
    }

    /// DTMF: длительность тонов и макросы.
    ///
    /// Формат макроса заказчиком пока не задан — это открытый вопрос 1 в README.
    /// Здесь принято то, к чему привыкли по телефонам: цифры, `*`, `#`, `A`–`D`
    /// и запятая как секундная пауза. Автоотправки нет: макрос уходит по
    /// нажатию оператора, а не сам по себе. Из готовых макросов не поставляется
    /// ни одного — боевые коды переводов известны только по виду (открытый
    /// вопрос 4), и вписывать догадку в настройки по умолчанию нельзя.
    struct DTMFSettings: Codable, Sendable, Equatable {

        struct Macro: Codable, Sendable, Equatable, Identifiable, Hashable {
            var id: UUID = UUID()
            /// Подпись на кнопке. Коротко: панель узкая.
            var title: String = ""
            /// Запись набора: цифры и запятые.
            var sequence: String = ""

            init(id: UUID = UUID(), title: String = "", sequence: String = "") {
                self.id = id
                self.title = title
                self.sequence = sequence
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
                title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
                sequence = try container.decodeIfPresent(String.self, forKey: .sequence) ?? ""
            }

            /// Годен ли макрос к отправке.
            var isUsable: Bool {
                !title.trimmingCharacters(in: .whitespaces).isEmpty
                    && DTMFSequence(sequence).hasTones
                    && DTMFSequence.unsupportedCharacters(in: sequence).isEmpty
            }
        }

        var toneMilliseconds: Int = 120
        var gapMilliseconds: Int = 80
        var pauseMilliseconds: Int = DTMFSequence.defaultPauseMilliseconds
        var macros: [Macro] = []

        init(
            toneMilliseconds: Int = 120,
            gapMilliseconds: Int = 80,
            pauseMilliseconds: Int = DTMFSequence.defaultPauseMilliseconds,
            macros: [Macro] = []
        ) {
            self.toneMilliseconds = toneMilliseconds
            self.gapMilliseconds = gapMilliseconds
            self.pauseMilliseconds = pauseMilliseconds
            self.macros = macros
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            toneMilliseconds = try container.decodeIfPresent(Int.self, forKey: .toneMilliseconds) ?? 120
            gapMilliseconds = try container.decodeIfPresent(Int.self, forKey: .gapMilliseconds) ?? 80
            pauseMilliseconds = try container.decodeIfPresent(Int.self, forKey: .pauseMilliseconds)
                ?? DTMFSequence.defaultPauseMilliseconds
            macros = try container.decodeIfPresent([Macro].self, forKey: .macros) ?? []
        }

        /// То же самое в терминах MediaCore.
        var timing: DTMFTiming {
            DTMFTiming(
                toneMilliseconds: toneMilliseconds,
                gapMilliseconds: gapMilliseconds
            )
        }

        func sequence(of macro: Macro) -> DTMFSequence {
            DTMFSequence(macro.sequence, pauseMilliseconds: pauseMilliseconds)
        }
    }

    static let `default` = AppSettings(
        profiles: SIPProfileList(),
        incomingCall: CallGuardPolicy(),
        minimumLogLevel: .info,
        acceptsAnyTLSCertificate: false
    )

    /// Пресет лаборатории — чтобы проверить регистрацию одним нажатием.
    ///
    /// Со списком профилей пресет перестал быть «настройками целиком»: он
    /// добавляет профиль и трогает только то, что относится к серверу. Иначе
    /// нажатие «Пир 100» стирало бы выбранные устройства, макросы и политику
    /// защиты — раньше именно так и было, и заметить это было негде.
    struct LabPreset {
        var label: String
        var account: SIPAccount
        var acceptsAnyTLSCertificate: Bool
        var minimumLogLevel: SIPLogLevel = .debug

        /// Стенд — заведомо не удалённое рабочее место, и пресет это
        /// проставляет явно: профиль до него мог быть помечен удалённым, а
        /// стучать в `127.0.0.1` бессмысленно и стоит семь секунд на запуск.
        var site: SIPProfileSite = .office
    }
}

/// Пресеты лаборатории — отдельным расширением, чтобы `applyLabPreset(.labUDP)`
/// читался по месту вызова без имени типа.
extension AppSettings.LabPreset {

    static let labUDP = Self(
        label: "Лаборатория · UDP",
        account: SIPAccount(
            username: "100",
            displayName: "Agent 100",
            domain: "127.0.0.1",
            serverPort: 5060,
            transport: .udp,
            registrationExpires: 120
        ),
        acceptsAnyTLSCertificate: false
    )

    static let labTLS = Self(
        label: "Лаборатория · TLS",
        account: SIPAccount(
            username: "200",
            displayName: "Agent 200 secure",
            domain: "127.0.0.1",
            serverPort: 5061,
            transport: .tls,
            registrationExpires: 120
        ),
        acceptsAnyTLSCertificate: true
    )
}

/// Чтение и запись настроек в Application Support.
enum SettingsStore {

    private static let fileName = "settings.json"

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("EliteSIP", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    static func load() -> AppSettings {
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            // Отсутствие файла — норма при первом запуске. Испорченный файл тоже
            // не повод падать: пользователь просто увидит пустые настройки.
            return .default
        }
    }

    /// Версия схемы, как она записана в файле. nil — файла нет или он испорчен.
    ///
    /// Нужна ровно для одного: понять при запуске, что файл мигрировали, и
    /// записать его в новой схеме сразу. Иначе старая схема живёт до первой
    /// правки настроек, и «мигрировано» превращается в «мигрируется каждый раз
    /// заново» — с новыми идентификаторами профилей при каждом запуске.
    static func storedSchemaVersion() -> Int? {
        struct Header: Decodable { var schemaVersion: Int? }
        guard let data = try? Data(contentsOf: fileURL),
            let header = try? JSONDecoder().decode(Header.self, from: data)
        else { return nil }
        return header.schemaVersion ?? 1
    }

    static func save(_ settings: AppSettings) throws {
        let url = fileURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
        // Права 0600 — потому что с 5 августа 2026 в файле лежит пароль от
        // добавочного (см. `SIPProfile`). Ставятся после каждой записи, а не
        // один раз при создании: `.atomic` пишет во временный файл и
        // переименовывает его на место старого, то есть права у файла каждый
        // раз новые, взятые из umask.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    }
}

/// Оформление приложения: за системой, светлое или тёмное.
///
/// Своя настройка, а не только системная, потому что рабочее место оператора
/// живёт не по его вкусу: панель висит поверх CRM весь день, и если CRM светлая,
/// а система тёмная, то тёмная панель на светлом фоне бьёт по глазам сильнее,
/// чем несовпадение с остальной системой.
enum AppearanceSetting: String, Codable, Sendable, CaseIterable, Identifiable {

    case system
    case light
    case dark

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Системная"
        case .light: return "Светлая"
        case .dark: return "Тёмная"
        }
    }

    /// `nil` — «не навязывать»: окна следуют за системой.
    var appKitAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}
