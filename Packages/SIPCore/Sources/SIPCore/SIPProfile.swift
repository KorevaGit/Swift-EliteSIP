import Foundation

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
    /// «офисный»/«удалённый» можно вписать руками.
    public var label: String

    public var account: SIPAccount

    public init(id: UUID = UUID(), label: String = "", account: SIPAccount) {
        self.id = id
        self.label = label
        self.account = account
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        account = try container.decode(SIPAccount.self, forKey: .account)
    }

    /// Чем профиль подписан в списке. Пустая строка означает, что подписывать
    /// нечем вовсе — ни метки, ни номера; текст для такого случая выбирает
    /// интерфейс, а не пакет протокола.
    public var title: String {
        label.isEmpty ? account.username : label
    }

    /// Пустой профиль для «Добавить»: транспорт и сервер наследуются от
    /// образца, номер — нет. Обычный случай — второй добавочный на той же АТС,
    /// и переписывать домен с портом заново незачем.
    public static func blank(basedOn sample: SIPAccount? = nil) -> SIPProfile {
        SIPProfile(
            account: SIPAccount(
                username: "",
                displayName: "",
                domain: sample?.domain ?? "",
                serverHost: sample?.serverHost,
                serverPort: sample?.serverPort,
                transport: sample?.transport ?? .tls,
                registrationExpires: sample?.registrationExpires ?? 300
            )
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
            profiles = [SIPProfile.blank(basedOn: removed.account)]
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

    /// Ставит учётную запись на место совпадающей по «номер@домен» либо
    /// добавляет новую, и в обоих случаях делает её активной.
    ///
    /// Нужно пресетам лаборатории: нажимать «Пир 100» можно сколько угодно раз,
    /// и плодить одинаковые профили от этого не должно.
    @discardableResult
    public mutating func upsert(_ account: SIPAccount, label: String = "") -> UUID {
        if let index = profiles.firstIndex(where: {
            $0.account.username == account.username && $0.account.domain == account.domain
        }) {
            profiles[index].account = account
            if !label.isEmpty { profiles[index].label = label }
            activeID = profiles[index].id
            return profiles[index].id
        }
        return add(SIPProfile(label: label, account: account))
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
