import Testing
@testable import SIPCore

@Suite("Via")
struct SIPViaTests {

    @Test("Разбирает транспорт, хост, порт и branch")
    func parsesBasics() throws {
        let via = try #require(SIPVia("SIP/2.0/UDP 10.0.0.5:5060;branch=z9hG4bKabc123;rport"))
        #expect(via.transport == .udp)
        #expect(via.host == "10.0.0.5")
        #expect(via.port == 5060)
        #expect(via.branch == "z9hG4bKabc123")
        #expect(via.hasParameter("rport"))
        #expect(via.rport == nil, "в запросе rport идёт без значения")
    }

    @Test("received и rport из ответа дают внешний адрес")
    func observedAddressFromResponse() throws {
        // Это единственный способ узнать, каким нас видно из-за NAT. Без этого
        // Contact в регистрации указывает на локальный адрес, и входящие не идут.
        let via = try #require(SIPVia(
            "SIP/2.0/UDP 192.168.1.50:5060;branch=z9hG4bK1;received=203.0.113.7;rport=41234"
        ))
        #expect(via.received == "203.0.113.7")
        #expect(via.rport == 41234)

        let observed = try #require(via.observedAddress)
        #expect(observed.host == "203.0.113.7")
        #expect(observed.port == 41234)
    }

    @Test("Без received внешний адрес неизвестен")
    func noObservedAddressWithoutReceived() throws {
        let via = try #require(SIPVia("SIP/2.0/TLS 10.0.0.5:5061;branch=z9hG4bK1"))
        #expect(via.observedAddress == nil)
    }

    @Test("requestRport добавляет флаг один раз")
    func requestRportIsIdempotent() throws {
        var via = try #require(SIPVia("SIP/2.0/UDP 10.0.0.5:5060;branch=z9hG4bK1"))
        via.requestRport()
        via.requestRport()
        #expect(via.parameters.filter { $0.name == "rport" }.count == 1)
        #expect(via.description.hasSuffix(";rport"))
    }

    @Test("IPv6 в скобках не путается с портом")
    func ipv6() throws {
        let via = try #require(SIPVia("SIP/2.0/TLS [2001:db8::1]:5061;branch=z9hG4bK1"))
        #expect(via.host == "2001:db8::1")
        #expect(via.port == 5061)
        #expect(via.description.contains("[2001:db8::1]:5061"))
    }

    @Test("Хост без порта разбирается")
    func hostWithoutPort() throws {
        let via = try #require(SIPVia("SIP/2.0/TLS pbx.example.com;branch=z9hG4bK1"))
        #expect(via.host == "pbx.example.com")
        #expect(via.port == nil)
    }

    @Test("Round-trip")
    func roundTrip() throws {
        for text in [
            "SIP/2.0/UDP 10.0.0.5:5060;branch=z9hG4bK1",
            "SIP/2.0/TLS pbx.example.com;branch=z9hG4bK2;received=1.2.3.4;rport=5060",
            "SIP/2.0/TCP [2001:db8::1]:5060;branch=z9hG4bK3",
        ] {
            let via = try #require(SIPVia(text))
            #expect(via.description == text)
        }
    }

    @Test("Мусор отвергается", arguments: [
        "",
        "SIP/2.0/UDP",                       // нет sent-by
        "HTTP/1.1/UDP host",                 // не SIP
        "SIP/1.0/UDP host",                  // не та версия
        "SIP/2.0/SCTP host",                 // неподдерживаемый транспорт
        "SIP/2.0/UDP host:99999",            // порт вне диапазона
    ])
    func rejectsGarbage(_ text: String) {
        #expect(SIPVia(text) == nil)
    }
}
