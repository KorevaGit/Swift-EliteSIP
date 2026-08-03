import XCTest

@testable import SIPCore

/// Список профилей: инварианты, миграция схемы 1 → 2 и связь с паролем.
///
/// Проверяется здесь, а не в приложении, ровно потому, что цена ошибки —
/// потерянная учётная запись на чужом рабочем месте при обычном обновлении
/// версии. Тип для этого и вынесен в пакет: у приложения тестов нет.
final class ProfileTests: XCTestCase {

    private func account(_ user: String, _ domain: String = "pbx.example") -> SIPAccount {
        SIPAccount(username: user, displayName: "Agent \(user)", domain: domain, transport: .udp)
    }

    // MARK: - Инварианты

    func testEmptyListGetsOneBlankProfile() {
        let list = SIPProfileList()
        XCTAssertEqual(list.profiles.count, 1)
        XCTAssertEqual(list.activeID, list.profiles[0].id)
        XCTAssertFalse(list.active.account.isUsable)
    }

    func testUnknownActiveIDFallsBackToFirst() {
        let first = SIPProfile(account: account("100"))
        let list = SIPProfileList(profiles: [first], activeID: UUID())
        XCTAssertEqual(list.activeID, first.id)
    }

    func testEditingActiveWritesBackIntoTheList() {
        var list = SIPProfileList(profiles: [SIPProfile(account: account("100"))])
        list.active.account.username = "101"
        XCTAssertEqual(list.profiles[0].account.username, "101")
        XCTAssertEqual(list.activeID, list.profiles[0].id)
    }

    /// Подмена идентификатора через `active` оставила бы список без активного
    /// профиля, и настраивать стало бы нечего.
    func testActiveSetterKeepsIdentity() {
        var list = SIPProfileList(profiles: [SIPProfile(account: account("100"))])
        let id = list.activeID
        list.active = SIPProfile(id: UUID(), label: "другой", account: account("200"))
        XCTAssertEqual(list.activeID, id)
        XCTAssertEqual(list.profiles.count, 1)
        XCTAssertEqual(list.active.account.username, "200")
        XCTAssertEqual(list.active.label, "другой")
    }

    func testAddMakesNewProfileActive() {
        var list = SIPProfileList(profiles: [SIPProfile(account: account("100"))])
        let added = list.add(SIPProfile(account: account("200")))
        XCTAssertEqual(list.profiles.count, 2)
        XCTAssertEqual(list.activeID, added)
    }

    func testActivateRejectsUnknownProfile() {
        var list = SIPProfileList(profiles: [SIPProfile(account: account("100"))])
        let id = list.activeID
        XCTAssertFalse(list.activate(UUID()))
        XCTAssertEqual(list.activeID, id)
    }

    // MARK: - Удаление

    func testRemovingActiveMovesActivityToNeighbour() {
        let first = SIPProfile(account: account("100"))
        let second = SIPProfile(account: account("200"))
        var list = SIPProfileList(profiles: [first, second], activeID: second.id)

        let removed = list.remove(second.id)
        XCTAssertEqual(removed?.account.username, "200")
        XCTAssertEqual(list.profiles.count, 1)
        XCTAssertEqual(list.activeID, first.id)
    }

    func testRemovingInactiveKeepsActive() {
        let first = SIPProfile(account: account("100"))
        let second = SIPProfile(account: account("200"))
        var list = SIPProfileList(profiles: [first, second], activeID: first.id)

        list.remove(second.id)
        XCTAssertEqual(list.activeID, first.id)
    }

    /// Удаление последнего профиля не должно оставить приложение без единого
    /// поля учётной записи. Сервер наследуется: чаще всего профиль удаляют,
    /// чтобы завести на той же АТС другой.
    func testRemovingTheLastProfileLeavesABlankOne() {
        let only = SIPProfile(account: account("100"))
        var list = SIPProfileList(profiles: [only])

        list.remove(only.id)
        XCTAssertEqual(list.profiles.count, 1)
        XCTAssertEqual(list.activeID, list.profiles[0].id)
        XCTAssertEqual(list.active.account.domain, "pbx.example")
        XCTAssertTrue(list.active.account.username.isEmpty)
    }

    func testRemoveReturnsNilForUnknownProfile() {
        var list = SIPProfileList(profiles: [SIPProfile(account: account("100"))])
        XCTAssertNil(list.remove(UUID()))
        XCTAssertEqual(list.profiles.count, 1)
    }

    /// Пароль в связке ключей лежит под «номер@домен». Два профиля с одной
    /// парой — одно рабочее место, и удаление одного не должно стирать пароль
    /// у второго.
    func testSharedCredentialsAreDetectedByNumberAndDomain() {
        let office = SIPProfile(label: "офис", account: account("100"))
        let remote = SIPProfile(label: "удалённый", account: account("100"))
        let other = SIPProfile(account: account("200"))
        let list = SIPProfileList(profiles: [office, remote, other])

        XCTAssertTrue(list.sharesCredentials(of: office, excludingID: office.id))
        XCTAssertFalse(list.sharesCredentials(of: other, excludingID: other.id))
    }

    func testSharedCredentialsIgnoreDifferentDomain() {
        let office = SIPProfile(account: account("100", "pbx.office"))
        let remote = SIPProfile(account: account("100", "pbx.remote"))
        let list = SIPProfileList(profiles: [office, remote])

        XCTAssertFalse(list.sharesCredentials(of: office, excludingID: office.id))
    }

    // MARK: - Пресеты

    func testUpsertReplacesMatchingAccountInsteadOfDuplicating() {
        var list = SIPProfileList(profiles: [SIPProfile(account: account("100"))])
        let first = list.upsert(account("100"), label: "Лаборатория")
        let second = list.upsert(account("100"), label: "Лаборатория")

        XCTAssertEqual(first, second)
        XCTAssertEqual(list.profiles.count, 1)
        XCTAssertEqual(list.activeID, first)
        XCTAssertEqual(list.active.label, "Лаборатория")
    }

    func testUpsertAddsUnknownAccount() {
        var list = SIPProfileList(profiles: [SIPProfile(account: account("100"))])
        let added = list.upsert(account("200"), label: "Лаборатория")

        XCTAssertEqual(list.profiles.count, 2)
        XCTAssertEqual(list.activeID, added)
    }

    // MARK: - Метка

    /// Согласованное решение: номер служит локальной меткой профиля. Пустая
    /// метка означает именно это, а не «профиль без имени».
    func testTitleFallsBackToNumber() {
        let profile = SIPProfile(account: account("100"))
        XCTAssertEqual(profile.title, "100")

        var named = profile
        named.label = "офис"
        XCTAssertEqual(named.title, "офис")
    }

    func testBlankProfileInheritsServerButNotNumber() {
        let sample = SIPAccount(
            username: "100",
            displayName: "Agent 100",
            domain: "pbx.example",
            serverPort: 5070,
            transport: .udp,
            registrationExpires: 120
        )
        let blank = SIPProfile.blank(basedOn: sample)

        XCTAssertTrue(blank.account.username.isEmpty)
        XCTAssertTrue(blank.account.displayName.isEmpty)
        XCTAssertEqual(blank.account.domain, "pbx.example")
        XCTAssertEqual(blank.account.serverPort, 5070)
        XCTAssertEqual(blank.account.transport, .udp)
        XCTAssertEqual(blank.account.registrationExpires, 120)
    }

    // MARK: - Рабочее место

    /// Умолчание — прежнее поведение M2d: решает адрес сервера.
    func testSiteDefaultsToAutomatic() {
        XCTAssertEqual(SIPProfile(account: account("100")).site, .automatic)
        XCTAssertEqual(SIPProfile.blank().site, .automatic)
    }

    func testSetSiteChangesOnlyTheAddressedProfile() {
        var list = SIPProfileList(profiles: [
            SIPProfile(label: "офис", account: account("100")),
            SIPProfile(label: "дом", account: account("200")),
        ])
        let remote = list.profiles[1].id

        XCTAssertTrue(list.setSite(.remote, for: remote))
        XCTAssertEqual(list.profiles[0].site, .automatic)
        XCTAssertEqual(list.profiles[1].site, .remote)
        XCTAssertFalse(list.setSite(.office, for: UUID()))
    }

    /// Второй добавочный заводят с того же рабочего места, что и первый.
    func testBlankProfileInheritsSite() {
        XCTAssertEqual(SIPProfile.blank(basedOn: account("100"), site: .remote).site, .remote)
    }

    /// Пресет лаборатории проставляет рабочее место сам: стенд на `127.0.0.1`
    /// офисный, и профиль, помеченный до этого удалённым, стучать не должен.
    func testUpsertOverwritesSiteWhenAsked() {
        var list = SIPProfileList(profiles: [
            SIPProfile(label: "дом", account: account("100"), site: .remote)
        ])
        list.upsert(account("100"), label: "Лаборатория", site: .office)
        XCTAssertEqual(list.profiles.count, 1)
        XCTAssertEqual(list.active.site, .office)
    }

    /// Без явного значения рабочее место существующего профиля не трогается:
    /// провижининг учётки не должен переносить место работы сотрудника.
    func testUpsertKeepsSiteByDefault() {
        var list = SIPProfileList(profiles: [
            SIPProfile(label: "дом", account: account("100"), site: .remote)
        ])
        list.upsert(account("100"), label: "дом")
        XCTAssertEqual(list.active.site, .remote)
    }

    /// Смена рабочего места переписывает адрес АТС, и профиль при этом может
    /// быть не активным.
    func testSetAccountReplacesAddressedProfile() {
        var list = SIPProfileList(profiles: [
            SIPProfile(label: "офис", account: account("100", "192.168.1.2")),
            SIPProfile(label: "второй", account: account("200")),
        ])
        let office = list.profiles[0].id
        list.activate(list.profiles[1].id)

        var moved = list[office]!.account
        moved.domain = "crm.elitesochi.com"
        XCTAssertTrue(list.setAccount(moved, for: office))
        XCTAssertEqual(list[office]?.account.domain, "crm.elitesochi.com")
        XCTAssertEqual(list.activeID, list.profiles[1].id, "активность не переезжает от правки адреса")
        XCTAssertFalse(list.setAccount(moved, for: UUID()))
    }

    // MARK: - Доверие к сертификату TLS

    /// Свойство сервера, а не приложения: включённое ради лаборатории, оно не
    /// должно оказаться у боевого профиля, на который переключились следом.
    func testCertificateTrustIsPerProfile() {
        var list = SIPProfileList(profiles: [
            SIPProfile(label: "лаба", account: account("200"), acceptsAnyTLSCertificate: true),
            SIPProfile(label: "бой", account: account("711", "pbx.prod")),
        ])
        list.activate(list.profiles[1].id)
        XCTAssertFalse(list.active.acceptsAnyTLSCertificate)
        XCTAssertTrue(list.profiles[0].acceptsAnyTLSCertificate)
    }

    /// Умолчание безопасное: профиль без поля сертификат проверяет.
    func testCertificateTrustDefaultsToChecking() throws {
        let json = """
        {"profiles":[{"account":{"username":"100","displayName":"","domain":"pbx.example",
        "transport":"tls","registrationExpires":120}}]}
        """
        let list = try JSONDecoder().decode(SIPProfileList.self, from: Data(json.utf8))
        XCTAssertFalse(list.active.acceptsAnyTLSCertificate)
        XCTAssertFalse(SIPProfile.blank().acceptsAnyTLSCertificate)
    }

    /// Пресет лаборатории включает доверие своему профилю и только ему.
    func testUpsertCarriesCertificateTrust() {
        var list = SIPProfileList(profiles: [
            SIPProfile(label: "бой", account: account("711", "pbx.prod"))
        ])
        list.upsert(account("200"), label: "Лаборатория", acceptsAnyTLSCertificate: true)
        XCTAssertTrue(list.active.acceptsAnyTLSCertificate)
        XCTAssertFalse(list.profiles[0].acceptsAnyTLSCertificate)
    }

    // MARK: - Схема файла

    func testMigrationKeepsAccountAndMakesItActive() {
        let list = SIPProfileList(migrating: account("100"))
        XCTAssertEqual(list.profiles.count, 1)
        XCTAssertEqual(list.active.account.username, "100")
        XCTAssertEqual(list.active.account.domain, "pbx.example")
        XCTAssertEqual(list.activeID, list.profiles[0].id)
        XCTAssertTrue(list.active.label.isEmpty)
    }

    func testRoundTripKeepsProfilesAndActiveOne() throws {
        var list = SIPProfileList(profiles: [
            SIPProfile(label: "офис", account: account("100")),
            SIPProfile(label: "удалённый", account: account("200", "sip.example")),
        ])
        list.activate(list.profiles[1].id)

        let data = try JSONEncoder().encode(list)
        let restored = try JSONDecoder().decode(SIPProfileList.self, from: data)

        XCTAssertEqual(restored, list)
        XCTAssertEqual(restored.active.label, "удалённый")
    }

    /// Файл, у которого профили есть, а активного нет: правка руками или
    /// провижининг снаружи. Падать нельзя — иначе настройки молча откатятся к
    /// пустым.
    func testDecodingWithoutActiveIDTakesFirstProfile() throws {
        let json = """
        {"profiles":[{"id":"\(UUID().uuidString)","label":"офис",
        "account":{"username":"100","displayName":"","domain":"pbx.example",
        "transport":"udp","registrationExpires":120}}]}
        """
        let list = try JSONDecoder().decode(SIPProfileList.self, from: Data(json.utf8))
        XCTAssertEqual(list.profiles.count, 1)
        XCTAssertEqual(list.activeID, list.profiles[0].id)
        XCTAssertEqual(list.active.account.username, "100")
    }

    func testDecodingProfileWithoutIDGetsOne() throws {
        let json = """
        {"profiles":[{"account":{"username":"100","displayName":"","domain":"pbx.example",
        "transport":"udp","registrationExpires":120}}]}
        """
        let list = try JSONDecoder().decode(SIPProfileList.self, from: Data(json.utf8))
        XCTAssertEqual(list.activeID, list.profiles[0].id)
    }

    func testDecodingEmptyObjectGivesOneBlankProfile() throws {
        let list = try JSONDecoder().decode(SIPProfileList.self, from: Data("{}".utf8))
        XCTAssertEqual(list.profiles.count, 1)
        XCTAssertFalse(list.active.account.isUsable)
    }

    /// Профиль, записанный до появления поля, читается как «по адресу
    /// сервера» — то есть работает ровно так же, как работал вчера.
    func testDecodingProfileWithoutSiteIsAutomatic() throws {
        let json = """
        {"profiles":[{"account":{"username":"100","displayName":"","domain":"pbx.example",
        "transport":"udp","registrationExpires":120}}]}
        """
        let list = try JSONDecoder().decode(SIPProfileList.self, from: Data(json.utf8))
        XCTAssertEqual(list.active.site, .automatic)
    }

    /// Файл настроек правят руками, и опечатка в этом поле не должна ронять
    /// чтение целиком: профиль без пригодного значения работает как раньше.
    func testDecodingUnknownSiteFallsBackToAutomatic() throws {
        let json = """
        {"profiles":[{"site":"vpn","account":{"username":"100","displayName":"",
        "domain":"pbx.example","transport":"udp","registrationExpires":120}}]}
        """
        let list = try JSONDecoder().decode(SIPProfileList.self, from: Data(json.utf8))
        XCTAssertEqual(list.active.site, .automatic)
    }

    func testSiteSurvivesRoundTrip() throws {
        var list = SIPProfileList(profiles: [
            SIPProfile(label: "офис", account: account("100"), site: .office),
            SIPProfile(label: "дом", account: account("200", "sip.example"), site: .remote),
        ])
        list.activate(list.profiles[1].id)

        let data = try JSONEncoder().encode(list)
        let restored = try JSONDecoder().decode(SIPProfileList.self, from: data)

        XCTAssertEqual(restored, list)
        XCTAssertEqual(restored.profiles[0].site, .office)
        XCTAssertEqual(restored.active.site, .remote)
    }

    // MARK: - Пометка менеджера

    func testNoteIsSeparateFromLabel() {
        var list = SIPProfileList(profiles: [
            SIPProfile(label: "офис", account: account("100", "sip.example"))
        ])
        let id = list.profiles[0].id

        XCTAssertTrue(list.setNote("мой основной", for: id))
        // Подпись администратора и пометка менеджера не затирают друг друга:
        // ради этого пометка и заведена отдельным полем.
        XCTAssertEqual(list.profiles[0].note, "мой основной")
        XCTAssertEqual(list.profiles[0].label, "офис")

        list.rename(id, to: "продажи")
        XCTAssertEqual(list.profiles[0].note, "мой основной")
        XCTAssertEqual(list.profiles[0].label, "продажи")
    }

    func testNoteOfMissingProfileIsRefused() {
        var list = SIPProfileList(profiles: [
            SIPProfile(account: account("100", "sip.example"))
        ])
        XCTAssertFalse(list.setNote("чужая", for: UUID()))
    }

    func testNoteSurvivesFile() throws {
        var list = SIPProfileList(profiles: [
            SIPProfile(account: account("100", "sip.example"))
        ])
        list.setNote("для отдела продаж", for: list.profiles[0].id)

        let data = try JSONEncoder().encode(list)
        let restored = try JSONDecoder().decode(SIPProfileList.self, from: data)
        XCTAssertEqual(restored.profiles[0].note, "для отдела продаж")
    }

    func testProfileWithoutNoteKeyReadsAsEmpty() throws {
        // Файл, записанный до появления поля: пометки нет, и это не ошибка.
        let json = """
            {"activeID":"00000000-0000-0000-0000-000000000001","profiles":[{\
            "id":"00000000-0000-0000-0000-000000000001","label":"офис",\
            "account":{"username":"100","displayName":"","domain":"sip.example",\
            "transport":"tls","registrationExpires":300}}]}
            """
        let restored = try JSONDecoder().decode(SIPProfileList.self, from: Data(json.utf8))
        XCTAssertEqual(restored.profiles[0].note, "")
    }
}
