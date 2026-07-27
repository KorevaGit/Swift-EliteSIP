import Testing
@testable import SIPCore

@Suite("NameAddress")
struct NameAddressTests {

    @Test("Разбирает имя в кавычках и URI в скобках")
    func quotedDisplayName() throws {
        let value = try #require(NameAddress(#""Agent 100" <sip:100@pbx.example.com>;tag=abc123"#))
        #expect(value.displayName == "Agent 100")
        #expect(value.uri.user == "100")
        #expect(value.uri.host == "pbx.example.com")
        #expect(value.tag == "abc123")
    }

    @Test("Разбирает имя без кавычек")
    func bareDisplayName() throws {
        let value = try #require(NameAddress("Agent <sip:100@host>"))
        #expect(value.displayName == "Agent")
        #expect(value.tag == nil)
    }

    @Test("Без угловых скобок параметры принадлежат заголовку, а не URI")
    func parametersWithoutAngles() throws {
        // RFC 3261 §20.10: это ключевая неоднозначность SIP. Здесь tag — это
        // параметр заголовка To, а не параметр URI.
        let value = try #require(NameAddress("sip:100@host;tag=xyz"))
        #expect(value.uri.host == "host")
        #expect(value.uri.parameters.isEmpty, "URI не должен забрать tag себе")
        #expect(value.tag == "xyz")
    }

    @Test("В скобках параметры URI и заголовка различаются")
    func parametersWithAngles() throws {
        let value = try #require(NameAddress("<sip:100@host;transport=tls>;tag=xyz"))
        #expect(value.uri[parameter: "transport"] == "tls")
        #expect(value.tag == "xyz")
        #expect(value.uri.transport == .tls)
    }

    @Test("Запятая и точка с запятой внутри кавычек не ломают разбор")
    func punctuationInsideQuotes() throws {
        let value = try #require(NameAddress(#""Петров, Иван; отдел 5" <sip:100@host>;tag=q"#))
        #expect(value.displayName == "Петров, Иван; отдел 5")
        #expect(value.tag == "q")
    }

    @Test("expires у Contact читается")
    func contactExpires() throws {
        // Asterisk может вернуть срок регистрации именно здесь, а не в Expires.
        let value = try #require(NameAddress("<sip:100@10.0.0.5:5060>;expires=120"))
        #expect(value.expires == 120)
    }

    @Test("Сериализация всегда ставит URI в угловые скобки")
    func encodingUsesAngles() {
        var value = NameAddress(uri: SIPURI(user: "100", host: "host"))
        #expect(value.description == "<sip:100@host>")

        value.tag = "t1"
        #expect(value.description == "<sip:100@host>;tag=t1")

        value.displayName = "Agent 100"
        #expect(value.description == #""Agent 100" <sip:100@host>;tag=t1"#)
    }

    @Test("Round-trip сохраняет смысл")
    func roundTrip() throws {
        for text in [
            "<sip:100@host>",
            "<sip:100@host>;tag=abc",
            #""Agent" <sip:100@host:5061;transport=tls>;tag=abc"#,
        ] {
            let parsed = try #require(NameAddress(text))
            let reparsed = try #require(NameAddress(parsed.description))
            #expect(reparsed == parsed, "потеря при round-trip: \(text) -> \(parsed.description)")
        }
    }

    @Test("Мусор отвергается", arguments: ["", "   ", "<>", "<not-a-uri>", "Agent <sip:>"])
    func rejectsGarbage(_ text: String) {
        #expect(NameAddress(text) == nil)
    }
}
