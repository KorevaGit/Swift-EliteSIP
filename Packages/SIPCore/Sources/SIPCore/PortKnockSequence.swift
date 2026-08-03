import Compat
import Foundation

/// Открывает дорогу до сервера перед тем, как по ней пойдёт SIP.
///
/// Отдельным протоколом, а не вызовом стука напрямую: `SIPUserAgent` не должен
/// знать ни про ICMP, ни про то, что на другом конце MikroTik. Ему нужно ровно
/// одно — возможность сказать «сейчас будет регистрация» и дождаться. В тестах
/// на это место встаёт заглушка, которая считает вызовы.
public protocol SIPPathOpener: Sendable {
    func openPath(reason: SIPPathOpenReason) async
}

/// Зачем открываем дорогу. Решает, можно ли пропустить.
public enum SIPPathOpenReason: Sendable, Hashable {

    /// Перед плановой регистрацией.
    case registration

    /// Перед повтором после отказа. Именно здесь пропускать нельзя: самая
    /// вероятная причина отказа — что дорогу как раз закрыли.
    case retry

    /// Тик по времени, пока всё хорошо.
    case periodic
}

/// Один шаг стука — то же, что одна строка `ping` в скрипте подключения.
///
/// `payloadBytes` — это `-s`, то есть данные ICMP без восьмибайтового
/// заголовка, ровно как их считает `ping`. Именно длина и есть подпись:
/// правило на шлюзе смотрит на размер пакета, а не на содержимое.
public struct PortKnockStep: Sendable, Hashable, Codable {

    /// Куда стучать. Пустая строка означает «хост сервера из профиля» — в
    /// скрипте это `crm.elitesochi.com`, но зашивать его в код нельзя: на
    /// стенде и в лаборатории сервер другой.
    public var host: String

    /// Байты данных ICMP. Аналог `ping -s`.
    public var payloadBytes: Int

    /// Сколько пакетов подряд. Аналог `ping -c`.
    public var count: Int

    public init(host: String = "", payloadBytes: Int, count: Int = 1) {
        self.host = host
        self.payloadBytes = payloadBytes
        self.count = count
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        payloadBytes = try container.decode(Int.self, forKey: .payloadBytes)
        count = try container.decodeIfPresent(Int.self, forKey: .count) ?? 1
    }

    /// Хост с подставленным адресом сервера.
    public func resolvedHost(server: String) -> String {
        host.isEmpty ? server : host
    }
}

/// Последовательность стука целиком.
///
/// По умолчанию — то же, что делает боевой скрипт подключения, без его
/// оформления: без пауз «Connecting… 10 seconds», без открытия браузера и без
/// финального «Successfully connected!», которое печаталось независимо от того,
/// дошло ли хоть что-нибудь.
///
/// Значения по умолчанию сознательно вынесены в настройки: последовательность
/// живёт на чужом шлюзе, и менять её нам придётся не пересборкой приложения, а
/// правкой файла настроек или провижинингом от EliteDash.
public struct PortKnockSequence: Sendable, Hashable, Codable {

    public var steps: [PortKnockStep]

    /// Пауза между пакетами.
    ///
    /// Секунда — не осторожность, а воспроизведение: `ping` шлёт с таким
    /// интервалом по умолчанию, и правило на шлюзе годами видело стук именно в
    /// этом темпе. Порядок пакетов для стука значим, и торопиться незачем.
    public var spacingSeconds: Double

    /// Как часто повторять стук, пока всё работает.
    ///
    /// Точный срок, на который шлюз открывает доступ, неизвестен — известно
    /// только, что при смене публичного адреса он почти наверняка перестаёт
    /// действовать, а адрес у большинства сотрудников динамический. Десять
    /// минут — заведомо меньше любого правдоподобного таймаута списка на
    /// MikroTik и при этом восемь ICMP-пакетов за десять минут, то есть цена
    /// вопроса не обсуждается.
    public var repeatIntervalSeconds: Double

    public init(
        steps: [PortKnockStep] = PortKnockSequence.production.steps,
        spacingSeconds: Double = 1,
        repeatIntervalSeconds: Double = 600
    ) {
        self.steps = steps
        self.spacingSeconds = spacingSeconds
        self.repeatIntervalSeconds = repeatIntervalSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try container.decodeIfPresent([PortKnockStep].self, forKey: .steps)
        // Пустой список в файле — это «стучать нечем», а не «взять умолчание»:
        // иначе выключить стук правкой настроек было бы невозможно.
        steps = stored ?? PortKnockSequence.production.steps
        spacingSeconds = try container.decodeIfPresent(Double.self, forKey: .spacingSeconds) ?? 1
        repeatIntervalSeconds =
            try container.decodeIfPresent(Double.self, forKey: .repeatIntervalSeconds) ?? 600
    }

    /// Боевая последовательность из скрипта удалённого подключения.
    ///
    /// Три адреса стучатся отдельно от домена сознательно: какой из них АТС, а
    /// какие CRM и прочее, на стороне заказчика ответить не смогли, поэтому
    /// повторяем скрипт целиком, а не ту его часть, которая кажется нужной.
    public static let production = PortKnockSequence(
        steps: [
            PortKnockStep(payloadBytes: 228, count: 2),
            PortKnockStep(payloadBytes: 126, count: 2),
            PortKnockStep(payloadBytes: 125, count: 1),
            PortKnockStep(host: "45.10.53.84", payloadBytes: 228, count: 1),
            PortKnockStep(host: "45.10.53.86", payloadBytes: 126, count: 1),
            PortKnockStep(host: "45.10.53.94", payloadBytes: 125, count: 1),
        ],
        spacingSeconds: 1,
        repeatIntervalSeconds: 600
    )

    /// Сколько всего пакетов уйдёт.
    public var packetCount: Int {
        steps.reduce(0) { $0 + max(0, $1.count) }
    }

    /// Сколько времени займёт стук. Нужно тому, кто его ждёт: это задержка
    /// перед первым REGISTER, и она должна быть предсказуемой, а не сюрпризом.
    public var estimatedDuration: Interval {
        .seconds(Double(max(0, packetCount - 1)) * spacingSeconds)
    }

    public var isEmpty: Bool { packetCount == 0 }
}

/// Нужен ли стук вообще.
///
/// Решает поле `site` профиля, а когда оно оставлено на `.automatic` — адрес
/// сервера, а не адрес рабочего места. В офисе в профиль вписывают внутренний
/// `192.168.1.2`, снаружи — внешний домен; проверять при этом собственный адрес
/// машины было бы хуже, потому что он у сотрудника тоже приватный
/// (`192.168.1.154` в дампе боевого пира — это его домашняя сеть, а не
/// офисная), и различить по нему офис от дома нельзя в принципе.
public enum PortKnockPolicy {

    /// Внутренний ли адрес сервера.
    ///
    /// Обобщение сверх «не равно 192.168.1.2» намеренное: под правило попадают
    /// и лаборатория на `127.0.0.1`, и стенд в любой приватной сети. Стучать
    /// туда бессмысленно, а на localhost ещё и вредно — там нет ни шлюза, ни
    /// правила, зато есть семь секунд задержки на каждом запуске.
    public static func isInternal(host: String) -> Bool {
        let host = host.trimmingCharacters(in: .whitespaces).lowercased()
        guard !host.isEmpty else { return true }

        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".localhost") {
            return true
        }
        if host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd") {
            return true
        }

        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        let numbers = octets.compactMap { UInt16($0) }
        guard numbers.count == 4, numbers.allSatisfy({ $0 <= 255 }) else { return false }

        switch (numbers[0], numbers[1]) {
        case (10, _): return true
        case (127, _): return true
        case (192, 168): return true
        case (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    /// Стучать ли перед регистрацией.
    ///
    /// Явно заданное рабочее место сильнее адреса — в этом весь смысл поля:
    /// офис за внешним доменом не платит семью секундами за каждое
    /// подключение, а удалённое место с внутренним адресом сервера (чужой
    /// туннель, проброс) всё-таки стучит. `.automatic` — прежнее правило M2d.
    public static func needsKnocking(
        serverHost: String,
        site: SIPProfileSite = .automatic
    ) -> Bool {
        switch site {
        case .office: return false
        case .remote: return true
        case .automatic: return !isInternal(host: serverHost)
        }
    }

    /// Во что превращается `.automatic` на самом деле.
    ///
    /// Нужно интерфейсу: выбора «определять по адресу» человеку не предлагают —
    /// он и так выбирает вручную, и третья кнопка означала бы «не выбирать».
    /// Вместо этого система решает сама, показывает решение выбранным и даёт
    /// его переопределить. `.automatic` остаётся в модели как «ещё не
    /// выбирали»: именно так читается файл, записанный до появления поля.
    public static func resolvedSite(serverHost: String, site: SIPProfileSite) -> SIPProfileSite {
        switch site {
        case .office, .remote: return site
        case .automatic: return isInternal(host: serverHost) ? .office : .remote
        }
    }

    /// Чем решение объясняется в журнале. Нужно тому, кто разбирает «почему не
    /// стучим» или «почему ждём семь секунд»: догадка по адресу и явная
    /// настройка выглядят одинаково, пока их не назвать по-разному.
    public static func explanation(serverHost: String, site: SIPProfileSite) -> String {
        switch site {
        case .office: return "профиль помечен как офисный"
        case .remote: return "профиль помечен как удалённый"
        case .automatic:
            return isInternal(host: serverHost)
                ? "адрес сервера внутренний"
                : "адрес сервера внешний"
        }
    }
}

/// Пропускать ли очередной стук.
///
/// Вынесено из актора отдельным значением, чтобы правило проверялось тестом, а
/// не живой сетью: единственное, что здесь можно испортить, — это отношение
/// «когда стучали в прошлый раз» к «зачем стучим сейчас».
public struct PortKnockThrottle: Sendable, Equatable {

    public var minimumInterval: Interval
    private var lastKnockAt: Date?

    public init(minimumInterval: Interval) {
        self.minimumInterval = minimumInterval
    }

    /// Повтор после отказа не пропускается никогда — см. `SIPPathOpenReason`.
    public func shouldKnock(reason: SIPPathOpenReason, now: Date) -> Bool {
        if reason == .retry { return true }
        guard let lastKnockAt else { return true }
        return now.timeIntervalSince(lastKnockAt) >= minimumInterval.seconds
    }

    public mutating func recordKnock(at moment: Date) {
        lastKnockAt = moment
    }

    /// Забыть о прошлом стуке: сеть сменилась, и открытым может быть уже не
    /// наш адрес.
    public mutating func invalidate() {
        lastKnockAt = nil
    }
}
