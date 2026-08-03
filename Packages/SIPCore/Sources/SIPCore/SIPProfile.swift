import Foundation

/// Откуда работают с этим профилем.
///
/// До 3 августа 2026 признак был только выводимым: стучать по портам или нет,
/// решал адрес сервера — приватный значит офис, внешний значит удалёнка
/// ([remote-access.md](../../../../docs/remote-access.md)). Правило рабочее, но
/// это догадка по косвенному признаку, и ошибается оно молча в обе стороны:
/// офис за внешним доменом получает семь секунд лишней задержки на каждом
/// подключении, а удалённое место, которому вписали внутренний адрес через
/// чужой туннель, не стучит вовсе и не регистрируется без объяснения причины.
///
/// Поэтому признак стал полем профиля, а догадка осталась значением по
/// умолчанию: `.automatic` — это ровно прежнее поведение, и файл настроек без
/// этого ключа читается именно так.
public enum SIPProfileSite: String, Sendable, Hashable, Codable, CaseIterable {

    /// Решает адрес сервера — поведение M2d.
    case automatic

    /// Офис: стука нет никогда, даже если сервер записан внешним доменом.
    case office

    /// Удалённое рабочее место: стук перед регистрацией всегда, даже если
    /// адрес сервера выглядит внутренним. Так работает место за чужим
    /// туннелем, где до АТС видно приватный адрес, а шлюз всё равно фильтрует.
    case remote

    /// Подпись для интерфейса и журнала. Здесь, а не во вью: та же строка
    /// нужна журналу, а разъезжаться им нельзя.
    public var title: String {
        switch self {
        case .automatic: return "по адресу сервера"
        case .office: return "офис"
        case .remote: return "удалённо"
        }
    }
}

/// Сохранённая учётная запись со своей меткой.
///
/// Профилей может быть несколько, зарегистрирован одновременно ровно один —
/// это согласованное решение M0. Пароля здесь нет по той же причине, по которой
/// его нет в `SIPAccount`: он живёт в связке ключей под ключом «номер@домен».
/// Из этого следует важное свойство: два профиля с одинаковой парой номер+домен
/// делят один пароль, и это не ошибка, а то же самое рабочее место.
public struct SIPProfile: Sendable, Hashable, Codable, Identifiable {

    /// Устойчивый идентификатор. Именно им профиль адресуется, а не номером:
    /// номер редактируется, и переименование не должно означать «другой профиль».
    public var id: UUID

    /// Метка профиля. Пустая означает не «без имени», а «метка равна номеру» —
    /// то же правило, что у `displayName` в `SIPAccount`. Так согласованное
    /// решение «номер служит локальной меткой» остаётся умолчанием, а
    /// «Лаба»/«Боевой» можно вписать руками.
    ///
    /// Правит её и администратор, и сам менеджер: по метке профиль и выбирают,
    /// а номер в списке из двух добавочных на одной АТС не различает ничего.
    /// Отдельного «поля для заметки менеджера» рядом нет намеренно — два поля с
    /// одинаковым смыслом расходятся, и в поддержке потом непонятно, по какому
    /// из них человек опознаёт профиль.
    public var label: String

    public var account: SIPAccount

    /// Офисное это рабочее место или удалённое. Решает, стучать ли по портам
    /// перед регистрацией; `.automatic` оставляет решение адресу сервера.
    public var site: SIPProfileSite

    /// Доверять любому сертификату TLS этого сервера.
    ///
    /// Свойство сервера, а не приложения, и потому лежит в профиле: включают
    /// его ради самоподписанного сертификата лаборатории, а забытым оно
    /// оставалось бы на боевом профиле, куда переключились следом. Отключает
    /// защиту от подмены сервера целиком — перехватчик увидит и digest-ответ,
    /// и разговор.
    public var acceptsAnyTLSCertificate: Bool

    public init(
        id: UUID = UUID(),
        label: String = "",
        account: SIPAccount,
        site: SIPProfileSite = .automatic,
        acceptsAnyTLSCertificate: Bool = false
    ) {
        self.id = id
        self.label = label
        self.account = account
        self.site = site
        self.acceptsAnyTLSCertificate = acceptsAnyTLSCertificate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        account = try container.decode(SIPAccount.self, forKey: .account)
        // Отсутствие ключа — это профиль, записанный до появления поля, и
        // менять ему поведение молча нельзя: `.automatic` и есть то, как он
        // работал вчера. Незнакомое значение читается так же — файл настроек
        // правят руками, и опечатка в нём не должна выключать регистрацию.
        site =
            (try? container.decodeIfPresent(SIPProfileSite.self, forKey: .site))
            .flatMap { $0 } ?? .automatic
        // Умолчание — проверять сертификат. Профиль, записанный до появления
        // поля, получает безопасное поведение, а не прежнее: прежнее здесь
        // общее на приложение, и переносит его миграция, а не этот декодер.
        acceptsAnyTLSCertificate =
            try container.decodeIfPresent(Bool.self, forKey: .acceptsAnyTLSCertificate) ?? false
    }

    /// Чем профиль подписан в списке. Пустая строка означает, что подписывать
    /// нечем вовсе — ни метки, ни номера; текст для такого случая выбирает
    /// интерфейс, а не пакет протокола.
    public var title: String {
        label.isEmpty ? account.username : label
    }

    /// Пустой профиль для «Добавить»: транспорт, сервер и рабочее место
    /// наследуются от образца, номер — нет. Обычный случай — второй добавочный
    /// на той же АТС с того же места, и переписывать домен с портом заново
    /// незачем.
    public static func blank(
        basedOn sample: SIPAccount? = nil,
        site: SIPProfileSite = .automatic
    ) -> SIPProfile {
        SIPProfile(
            account: SIPAccount(
                username: "",
                displayName: "",
                domain: sample?.domain ?? "",
                serverHost: sample?.serverHost,
                serverPort: sample?.serverPort,
                transport: sample?.transport ?? .tls,
                registrationExpires: sample?.registrationExpires ?? 300
            ),
            site: site
        )
    }
}

/// Список профилей с ровно одним активным.
///
/// Инварианты держит сам тип, а не вызывающий код: список никогда не пуст, и
/// `activeID` всегда указывает на существующий профиль. Иначе «удалили
/// последний профиль» означало бы интерфейс без единого поля учётной записи и
/// приложение, которое нечем настроить.
public struct SIPProfileList: Sendable, Equatable, Codable {

    public private(set) var profiles: [SIPProfile]
    public private(set) var activeID: UUID

    public init(profiles: [SIPProfile] = [], activeID: UUID? = nil) {
        let restored = profiles.isEmpty ? [SIPProfile.blank()] : profiles
        self.profiles = restored
        if let activeID, restored.contains(where: { $0.id == activeID }) {
            self.activeID = activeID
        } else {
            self.activeID = restored[0].id
        }
    }

    /// Миграция схемы 1 → 2: единственный аккаунт становится первым профилем и
    /// остаётся активным. Идентификатор новый, пароль в связке ключей не
    /// трогается — ключ по «номер@домен» переживает миграцию как есть.
    public init(migrating account: SIPAccount) {
        self.init(profiles: [SIPProfile(account: account)])
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try container.decodeIfPresent([SIPProfile].self, forKey: .profiles) ?? []
        let active = try container.decodeIfPresent(UUID.self, forKey: .activeID)
        self.init(profiles: stored, activeID: active)
    }

    public var active: SIPProfile {
        get { profiles.first(where: { $0.id == activeID }) ?? profiles[0] }
        set {
            guard let index = profiles.firstIndex(where: { $0.id == activeID }) else { return }
            // Идентификатор активного профиля правке не подлежит: подменив его
            // через это свойство, вызывающий код получил бы список без
            // активного профиля.
            var replacement = newValue
            replacement.id = activeID
            profiles[index] = replacement
        }
    }

    public subscript(id: UUID) -> SIPProfile? {
        profiles.first(where: { $0.id == id })
    }

    /// Делает профиль активным. `false` — такого профиля нет.
    @discardableResult
    public mutating func activate(_ id: UUID) -> Bool {
        guard profiles.contains(where: { $0.id == id }) else { return false }
        activeID = id
        return true
    }

    /// Добавляет профиль и делает его активным: добавляют его затем, чтобы
    /// сразу заполнить.
    @discardableResult
    public mutating func add(_ profile: SIPProfile) -> UUID {
        profiles.append(profile)
        activeID = profile.id
        return profile.id
    }

    /// Удаляет профиль и возвращает удалённый — вызывающему коду он нужен,
    /// чтобы стереть пароль из связки ключей.
    ///
    /// Пустым список не остаётся: удаление последнего профиля оставляет на его
    /// месте пустой. Активность переезжает на соседа.
    @discardableResult
    public mutating func remove(_ id: UUID) -> SIPProfile? {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = profiles.remove(at: index)
        if profiles.isEmpty {
            // Рабочее место наследуется: удаляют профиль обычно затем, чтобы
            // завести на его месте другой, и переезжать при этом никто не
            // собирался. Доверие к сертификату, наоборот, не наследуется —
            // умолчание у него безопасное.
            profiles = [SIPProfile.blank(basedOn: removed.account, site: removed.site)]
        }
        if activeID == id {
            activeID = profiles[min(index, profiles.count - 1)].id
        }
        return removed
    }

    @discardableResult
    public mutating func rename(_ id: UUID, to label: String) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return false }
        profiles[index].label = label
        return true
    }

    /// Заменяет учётную запись профиля. `false` — такого профиля нет.
    ///
    /// Нужно смене рабочего места: она переписывает адрес АТС у профиля,
    /// который может быть и не активным.
    @discardableResult
    public mutating func setAccount(_ account: SIPAccount, for id: UUID) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return false }
        profiles[index].account = account
        return true
    }

    /// Меняет рабочее место профиля. `false` — такого профиля нет.
    @discardableResult
    public mutating func setSite(_ site: SIPProfileSite, for id: UUID) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return false }
        profiles[index].site = site
        return true
    }

    /// Ставит учётную запись на место совпадающей по «номер@домен» либо
    /// добавляет новую, и в обоих случаях делает её активной.
    ///
    /// Нужно пресетам лаборатории: нажимать «Пир 100» можно сколько угодно раз,
    /// и плодить одинаковые профили от этого не должно.
    /// `site` — `nil` означает «не трогать»: у существующего профиля рабочее
    /// место остаётся своим. Пресет лаборатории его, наоборот, задаёт: стенд на
    /// `127.0.0.1` заведомо офисный, а профиль до этого мог быть помечен
    /// удалённым, и тогда клиент стучал бы в петлю.
    @discardableResult
    public mutating func upsert(
        _ account: SIPAccount,
        label: String = "",
        site: SIPProfileSite? = nil,
        acceptsAnyTLSCertificate: Bool? = nil
    ) -> UUID {
        if let index = profiles.firstIndex(where: {
            $0.account.username == account.username && $0.account.domain == account.domain
        }) {
            profiles[index].account = account
            if !label.isEmpty { profiles[index].label = label }
            if let site { profiles[index].site = site }
            if let acceptsAnyTLSCertificate {
                profiles[index].acceptsAnyTLSCertificate = acceptsAnyTLSCertificate
            }
            activeID = profiles[index].id
            return profiles[index].id
        }
        return add(
            SIPProfile(
                label: label,
                account: account,
                site: site ?? .automatic,
                acceptsAnyTLSCertificate: acceptsAnyTLSCertificate ?? false
            )
        )
    }

    /// Делят ли другие профили ту же запись в связке ключей.
    ///
    /// Ключ там — «номер@домен», и удалять пароль вместе с профилем можно
    /// только тогда, когда он больше никому не принадлежит.
    public func sharesCredentials(of profile: SIPProfile, excludingID excluded: UUID) -> Bool {
        profiles.contains {
            $0.id != excluded
                && $0.account.username == profile.account.username
                && $0.account.domain == profile.account.domain
        }
    }
}
