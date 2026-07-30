import CallGuard
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
    var schemaVersion: Int = 1

    var account: SIPAccount
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

    /// Доверять любому сертификату TLS.
    ///
    /// Отключает защиту от подмены сервера: перехватчик увидит и пароль, и
    /// разговор. Существует ровно ради самоподписанного сертификата
    /// лаборатории на localhost. В бою должно быть выключено.
    var acceptsAnyTLSCertificate: Bool

    /// Свой почленный инициализатор: наличие `init(from:)` отменяет
    /// синтезированный.
    init(
        schemaVersion: Int = 1,
        account: SIPAccount,
        audio: AudioSettings = AudioSettings(),
        incomingCall: CallGuardPolicy = CallGuardPolicy(),
        ringtone: RingtoneSettings = RingtoneSettings(),
        dtmf: DTMFSettings = DTMFSettings(),
        conference: ConferenceSettings = ConferenceSettings(),
        minimumLogLevel: SIPLogLevel = .info,
        acceptsAnyTLSCertificate: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.account = account
        self.audio = audio
        self.incomingCall = incomingCall
        self.ringtone = ringtone
        self.dtmf = dtmf
        self.conference = conference
        self.minimumLogLevel = minimumLogLevel
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
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        account = try container.decode(SIPAccount.self, forKey: .account)
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
        acceptsAnyTLSCertificate =
            try container.decodeIfPresent(Bool.self, forKey: .acceptsAnyTLSCertificate) ?? false
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
        /// Выключатель нужен не для красоты: если разговор всё равно уходит в
        /// город, широкая полоса не переживёт стык с телефонной сетью, зато
        /// добавит Asterisk перекодирование. На загруженной АТС это заметно.
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

        init(isEnabled: Bool = true, volume: Double = 0.5, usesSystemOutput: Bool = true) {
            self.isEnabled = isEnabled
            self.volume = volume
            self.usesSystemOutput = usesSystemOutput
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
            volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 0.5
            usesSystemOutput = try container.decodeIfPresent(Bool.self, forKey: .usesSystemOutput) ?? true
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
        account: SIPAccount(
            username: "",
            displayName: "",
            domain: "",
            transport: .tls,
            registrationExpires: 300
        ),
        incomingCall: CallGuardPolicy(),
        minimumLogLevel: .info,
        acceptsAnyTLSCertificate: false
    )

    /// Настройки лаборатории — чтобы проверить регистрацию одним нажатием.
    static let labUDP = AppSettings(
        account: SIPAccount(
            username: "100",
            displayName: "Agent 100",
            domain: "127.0.0.1",
            serverPort: 5060,
            transport: .udp,
            registrationExpires: 120
        ),
        incomingCall: CallGuardPolicy(),
        minimumLogLevel: .debug,
        acceptsAnyTLSCertificate: false
    )

    static let labTLS = AppSettings(
        account: SIPAccount(
            username: "200",
            displayName: "Agent 200 secure",
            domain: "127.0.0.1",
            serverPort: 5061,
            transport: .tls,
            registrationExpires: 120
        ),
        incomingCall: CallGuardPolicy(),
        minimumLogLevel: .debug,
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

    static func save(_ settings: AppSettings) throws {
        let url = fileURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}
