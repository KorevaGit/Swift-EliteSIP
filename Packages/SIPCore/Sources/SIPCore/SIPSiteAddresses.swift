import Foundation

/// Пара адресов одной и той же АТС: изнутри и снаружи.
///
/// Переключить профиль между офисом и удалёнкой, не тронув адрес сервера,
/// бессмысленно: из дома внутренний `192.168.1.2` недостижим, а из офиса
/// внешний домен ведёт на тот же самый сервер длинной дорогой через шлюз.
/// Поэтому смена рабочего места меняет и адрес — это одно действие, а не два.
///
/// Значения пока зашиты, но лежат в файле настроек и правятся без пересборки:
/// приедут они из EliteDash вместе с остальным провижинингом (M8), а до тех пор
/// известны только нам. Тот же приём, что у последовательности стука
/// (`PortKnockSequence`), и по той же причине — адреса живут не у нас.
public struct SIPSiteAddresses: Sendable, Hashable, Codable {

    /// Адрес АТС изнутри офисной сети.
    public var office: String

    /// Адрес той же АТС снаружи. Именно на него открывает дорогу стук.
    public var remote: String

    public init(office: String, remote: String) {
        self.office = office
        self.remote = remote
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        office = try container.decodeIfPresent(String.self, forKey: .office)
            ?? SIPSiteAddresses.production.office
        remote = try container.decodeIfPresent(String.self, forKey: .remote)
            ?? SIPSiteAddresses.production.remote
    }

    public static let production = SIPSiteAddresses(
        office: "192.168.1.2",
        remote: "crm.elitesochi.com"
    )

    /// Адрес, соответствующий рабочему месту. `nil` для `.automatic`: там
    /// решение принимает адрес, и менять его было бы рассуждением по кругу.
    public func host(for site: SIPProfileSite) -> String? {
        switch site {
        case .office: return office
        case .remote: return remote
        case .automatic: return nil
        }
    }

    /// Наша ли это пара.
    ///
    /// Проверяется перед подменой адреса: лабораторный `127.0.0.1` и чужая АТС
    /// к этой паре отношения не имеют, и переписывать их адрес нельзя — пометка
    /// рабочего места не должна незаметно уводить профиль на другой сервер.
    public func recognizes(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: .whitespaces).lowercased()
        return host == office.lowercased() || host == remote.lowercased()
    }

    public var isEmpty: Bool { office.isEmpty || remote.isEmpty }
}
