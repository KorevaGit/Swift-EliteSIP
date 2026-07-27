import Testing
@testable import SIPCore

@Suite("SIPURI")
struct SIPURITests {

    @Test("Разбирает минимальный URI без пользователя и порта")
    func parsesHostOnly() throws {
        let uri = try #require(SIPURI("sip:pbx.example.com"))
        #expect(uri.scheme == .sip)
        #expect(uri.user == nil)
        #expect(uri.host == "pbx.example.com")
        #expect(uri.port == nil)
        #expect(uri.parameters.isEmpty)
    }

    @Test("Разбирает пользователя, порт и параметры")
    func parsesFullURI() throws {
        let uri = try #require(SIPURI("sip:100@192.168.1.1:5060;transport=tls;lr"))
        #expect(uri.user == "100")
        #expect(uri.host == "192.168.1.1")
        #expect(uri.port == 5060)
        #expect(uri[parameter: "transport"] == "tls")
        #expect(uri.hasParameter("lr"))
        #expect(uri[parameter: "lr"] == nil, "флаг без значения не должен получать пустую строку")
        #expect(uri.transport == .tls)
    }

    @Test("Понимает схему sips и регистр схемы")
    func parsesSecureScheme() throws {
        let uri = try #require(SIPURI("SIPS:200@pbx.example.com"))
        #expect(uri.scheme == .sips)
        #expect(uri.resolvedPort(defaultTransport: .udp) == 5061, "sips обязан уводить на 5061 даже без transport=")
    }

    @Test("Снимает IPv6-литерал в скобках, не путая его с портом")
    func parsesIPv6() throws {
        let uri = try #require(SIPURI("sip:100@[2001:db8::1]:5061"))
        #expect(uri.host == "2001:db8::1")
        #expect(uri.port == 5061)

        let noPort = try #require(SIPURI("sip:[2001:db8::1]"))
        #expect(noPort.host == "2001:db8::1")
        #expect(noPort.port == nil)
    }

    @Test("Игнорирует пароль в userinfo")
    func ignoresPassword() throws {
        let uri = try #require(SIPURI("sip:100:secret@pbx.example.com"))
        #expect(uri.user == "100")
        #expect(!uri.description.contains("secret"), "пароль не должен утекать назад в сериализацию")
    }

    @Test("Отбрасывает header-часть, но не ломается на ней")
    func toleratesHeaders() throws {
        let uri = try #require(SIPURI("sip:100@pbx.example.com?X-Foo=bar"))
        #expect(uri.host == "pbx.example.com")
    }

    @Test("Round-trip сохраняет строку и порядок параметров")
    func roundTrip() throws {
        for text in [
            "sip:pbx.example.com",
            "sip:100@192.168.1.1:5060",
            "sip:100@192.168.1.1:5060;transport=tls;lr",
            "sips:200@pbx.example.com:5061",
            "sip:100@[2001:db8::1]:5061",
        ] {
            let uri = try #require(SIPURI(text), "не разобрался: \(text)")
            #expect(uri.description == text)
            #expect(SIPURI(uri.description) == uri, "повторный разбор должен давать то же значение")
        }
    }

    @Test("Отклоняет мусор", arguments: [
        "",
        "100@pbx.example.com",          // нет схемы
        "http:pbx.example.com",         // чужая схема
        "sip:",                         // нет хоста
        "sip:@pbx.example.com",         // пустой userinfo
        "sip:100@",                     // нет хоста после @
        "sip:pbx.example.com:99999",    // порт вне UInt16
        "sip:pbx.example.com:abc",      // порт не число
        "sip:[2001:db8::1",             // незакрытая скобка
    ])
    func rejectsGarbage(_ text: String) {
        #expect(SIPURI(text) == nil, "должен быть отвергнут: \(text)")
    }

    @Test("Параметры доступны без учёта регистра имени")
    func parameterLookupIsCaseInsensitive() throws {
        let uri = try #require(SIPURI("sip:pbx.example.com;Transport=TLS"))
        #expect(uri[parameter: "transport"] == "TLS")
        #expect(uri.transport == .tls, "значение параметра тоже читается без учёта регистра")
    }

    @Test("Изменение параметра через subscript добавляет и удаляет")
    func parameterMutation() throws {
        var uri = try #require(SIPURI("sip:pbx.example.com"))
        uri[parameter: "transport"] = "tls"
        #expect(uri.description == "sip:pbx.example.com;transport=tls")
        uri[parameter: "TRANSPORT"] = nil
        #expect(uri.description == "sip:pbx.example.com")
    }

    @Test("Порт по умолчанию зависит от транспорта")
    func resolvedPortFallsBackToTransport() throws {
        let plain = try #require(SIPURI("sip:pbx.example.com"))
        #expect(plain.resolvedPort(defaultTransport: .udp) == 5060)
        #expect(plain.resolvedPort(defaultTransport: .tls) == 5061)

        let explicit = try #require(SIPURI("sip:pbx.example.com;transport=tls"))
        #expect(explicit.resolvedPort(defaultTransport: .udp) == 5061)

        let pinned = try #require(SIPURI("sip:pbx.example.com:5080;transport=tls"))
        #expect(pinned.resolvedPort(defaultTransport: .udp) == 5080, "явный порт важнее транспорта")
    }
}
