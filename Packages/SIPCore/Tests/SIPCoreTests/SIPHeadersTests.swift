import Testing
@testable import SIPCore

@Suite("Заголовки")
struct SIPHeadersTests {

    @Test("Компактные формы разворачиваются в канонические имена")
    func compactForms() {
        #expect(SIPHeaderName.canonical("v") == "Via")
        #expect(SIPHeaderName.canonical("f") == "From")
        #expect(SIPHeaderName.canonical("t") == "To")
        #expect(SIPHeaderName.canonical("i") == "Call-ID")
        #expect(SIPHeaderName.canonical("m") == "Contact")
        #expect(SIPHeaderName.canonical("l") == "Content-Length")
        #expect(SIPHeaderName.canonical("c") == "Content-Type")
    }

    @Test("Регистр в имени не важен, написание нормализуется")
    func canonicalSpelling() {
        #expect(SIPHeaderName.canonical("call-id") == "Call-ID")
        #expect(SIPHeaderName.canonical("CSEQ") == "CSeq")
        #expect(SIPHeaderName.canonical("www-authenticate") == "WWW-Authenticate")
        #expect(SIPHeaderName.canonical("  Max-Forwards  ") == "Max-Forwards")
        // Незнакомый заголовок хотя бы приводится к однородному виду.
        #expect(SIPHeaderName.canonical("x-custom-thing") == "X-Custom-Thing")
    }

    @Test("Поиск работает по любому написанию имени")
    func lookupIsCaseInsensitive() {
        var headers = SIPHeaders()
        headers.append("Call-ID", "abc@host")
        #expect(headers["call-id"] == "abc@host")
        #expect(headers["i"] == "abc@host")
        #expect(headers.contains("CALL-ID"))
    }

    @Test("Via через запятую разворачивается в отдельные значения")
    func commaSeparatedViaIsSplit() {
        var headers = SIPHeaders()
        headers.append("Via", "SIP/2.0/UDP first.example.com;branch=z9hG4bK1, SIP/2.0/UDP second.example.com;branch=z9hG4bK2")
        let values = headers.values("Via")
        #expect(values.count == 2)
        #expect(values[0].contains("first.example.com"))
        #expect(values[1].contains("second.example.com"))
    }

    @Test("WWW-Authenticate по запятым НЕ разрезается")
    func authenticateIsNotSplit() {
        // Это главная причина, по которой список разрешённых заголовков белый,
        // а не чёрный: здесь запятая разделяет параметры одного значения.
        var headers = SIPHeaders()
        headers.append("WWW-Authenticate", #"Digest realm="asterisk", nonce="1234abcd", algorithm=MD5"#)
        let values = headers.values("WWW-Authenticate")
        #expect(values.count == 1)
        #expect(values[0].contains("realm=") && values[0].contains("nonce="))
    }

    @Test("Запятая внутри кавычек и угловых скобок не разделяет значения")
    func splittingRespectsQuotingAndAngles() {
        var headers = SIPHeaders()
        headers.append("Contact", #""Петров, Иван" <sip:100@host>;expires=300"#)
        #expect(headers.values("Contact").count == 1)

        var routes = SIPHeaders()
        routes.append("Route", "<sip:a@proxy1;lr>, <sip:b@proxy2;lr>")
        #expect(routes.values("Route").count == 2)
    }

    @Test("set заменяет все одноимённые и идемпотентен")
    func setReplacesAll() {
        var headers = SIPHeaders()
        headers.append("Via", "SIP/2.0/UDP a")
        headers.append("Via", "SIP/2.0/UDP b")
        headers.append("From", "<sip:100@host>")

        headers.set("Via", to: "SIP/2.0/TLS c")
        #expect(headers.values("Via") == ["SIP/2.0/TLS c"])
        #expect(headers.fields.count == 2, "остальные заголовки не должны пострадать")

        headers.set("Via", to: "SIP/2.0/TLS c")
        #expect(headers.fields.count == 2, "повторный set не должен размножать заголовок")
    }

    @Test("Порядок одноимённых заголовков сохраняется, prepend кладёт наверх")
    func orderIsPreserved() {
        var headers = SIPHeaders()
        headers.append("Via", "SIP/2.0/UDP inner")
        headers.prepend("Via", "SIP/2.0/UDP outer")
        // Свой Via всегда сверху стека — иначе ответ уйдёт не туда.
        #expect(headers.values("Via") == ["SIP/2.0/UDP outer", "SIP/2.0/UDP inner"])
    }

    @Test("remove убирает все вхождения")
    func removeDropsAll() {
        var headers = SIPHeaders()
        headers.append("Via", "a")
        headers.append("v", "b")
        headers.remove("VIA")
        #expect(headers.values("Via").isEmpty)
    }

    @Test("Сериализация даёт канонические имена и CRLF")
    func encoding() {
        var headers = SIPHeaders()
        headers.append("i", "abc")
        headers.append("l", "0")
        #expect(headers.encoded == "Call-ID: abc\r\nContent-Length: 0\r\n")
    }
}
