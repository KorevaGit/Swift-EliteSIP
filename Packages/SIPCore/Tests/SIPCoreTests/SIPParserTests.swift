import Foundation
import Testing
@testable import SIPCore

/// Собирает сообщение с правильными CRLF: в литерале их не видно, а ошибка в
/// переводах строк — самая частая причина «сервер молчит».
func sipMessage(_ lines: [String], body: String = "") -> Data {
    var text = lines.joined(separator: "\r\n")
    text += "\r\n\r\n"
    text += body
    return Data(text.utf8)
}

@Suite("Разбор сообщений")
struct SIPParserTests {

    @Test("Разбирает REGISTER")
    func parsesRegister() throws {
        let data = sipMessage([
            "REGISTER sip:127.0.0.1 SIP/2.0",
            "Via: SIP/2.0/UDP 192.168.1.50:5060;branch=z9hG4bKabc;rport",
            "Max-Forwards: 70",
            "From: \"Agent 100\" <sip:100@127.0.0.1>;tag=t1",
            "To: <sip:100@127.0.0.1>",
            "Call-ID: call-1@mac.local",
            "CSeq: 1 REGISTER",
            "Contact: <sip:100@192.168.1.50:5060>",
            "Expires: 300",
            "User-Agent: EliteSIP/0.1",
            "Content-Length: 0",
        ])

        let request = try #require(try SIPParser.parse(data).asRequest)
        #expect(request.method == .register)
        #expect(request.uri.host == "127.0.0.1")
        #expect(request.callID == "call-1@mac.local")
        #expect(request.cseq?.number == 1)
        #expect(request.cseq?.method == .register)
        #expect(request.from?.tag == "t1")
        #expect(request.from?.displayName == "Agent 100")
        #expect(request.to?.tag == nil)
        #expect(request.expires == 300)
        #expect(request.topVia?.branch == "z9hG4bKabc")
        #expect(request.contacts.count == 1)
        #expect(request.body.isEmpty)
    }

    @Test("Разбирает 401 от chan_sip")
    func parsesUnauthorized() throws {
        // Форма заголовка ровно такая, как её отдаёт chan_sip: algorithm первым,
        // без qop.
        let data = sipMessage([
            "SIP/2.0 401 Unauthorized",
            "Via: SIP/2.0/UDP 192.168.1.50:5060;branch=z9hG4bKabc;received=192.168.65.1;rport=54321",
            "From: \"Agent 100\" <sip:100@127.0.0.1>;tag=t1",
            "To: <sip:100@127.0.0.1>;tag=as5f0e9b1c",
            "Call-ID: call-1@mac.local",
            "CSeq: 1 REGISTER",
            "WWW-Authenticate: Digest algorithm=MD5, realm=\"asterisk\", nonce=\"1234abcd\"",
            "Content-Length: 0",
        ])

        let response = try #require(try SIPParser.parse(data).asResponse)
        #expect(response.statusCode == 401)
        #expect(response.reasonPhrase == "Unauthorized")
        #expect(response.isFinal)
        #expect(!response.isSuccess)
        #expect(response.isAuthenticationRequired)
        #expect(response.to?.tag == "as5f0e9b1c")
        #expect(response.topVia?.rport == 54321)
        #expect(response.topVia?.received == "192.168.65.1")

        let challenges = response.authenticationChallenges
        #expect(challenges.count == 1)
        #expect(challenges.first?.challenge.realm == "asterisk")
        #expect(challenges.first?.challenge.nonce == "1234abcd")
        #expect(challenges.first?.responseHeader == "Authorization")
    }

    @Test("Тело берётся по Content-Length, а не до конца буфера")
    func bodyRespectsContentLength() throws {
        let sdp = "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\n"
        var data = sipMessage([
            "SIP/2.0 200 OK",
            "Via: SIP/2.0/UDP host;branch=z9hG4bK1",
            "Call-ID: c1",
            "CSeq: 1 INVITE",
            "Content-Type: application/sdp",
            "Content-Length: \(sdp.utf8.count)",
        ], body: sdp)
        // Дописываем хвост, как это бывает при склейке в потоке.
        data.append(Data("МУСОР".utf8))

        let response = try #require(try SIPParser.parse(data).asResponse)
        #expect(response.body.count == sdp.utf8.count)
        #expect(String(data: response.body, encoding: .utf8) == sdp)
        #expect(response.contentType == "application/sdp")
    }

    @Test("Свёрнутые заголовки склеиваются")
    func unfoldsHeaders() throws {
        let text = [
            "SIP/2.0 200 OK",
            "Via: SIP/2.0/UDP host;branch=z9hG4bK1",
            "Call-ID: c1",
            "CSeq: 1 REGISTER",
            "Contact: <sip:100@host>",
            "\t;expires=300",
            "Content-Length: 0",
        ].joined(separator: "\r\n") + "\r\n\r\n"

        let response = try #require(try SIPParser.parse(Data(text.utf8)).asResponse)
        #expect(response.contacts.first?.expires == 300)
    }

    @Test("Переводы строк только LF тоже разбираются")
    func tolerantAboutLineEndings() throws {
        // Своё мы всегда пишем с CRLF, но снисходительность на приёме дешевле,
        // чем разбираться, почему звонок не идёт.
        let text = "SIP/2.0 100 Trying\nVia: SIP/2.0/UDP host;branch=z9hG4bK1\nCall-ID: c1\nCSeq: 1 INVITE\n\n"
        let response = try #require(try SIPParser.parse(Data(text.utf8)).asResponse)
        #expect(response.statusCode == 100)
        #expect(response.isProvisional)
    }

    @Test("Reason-phrase с пробелами не режется")
    func multiWordReasonPhrase() throws {
        let data = sipMessage([
            "SIP/2.0 480 Temporarily Unavailable",
            "Via: SIP/2.0/UDP host;branch=z9hG4bK1",
            "Call-ID: c1",
            "CSeq: 1 INVITE",
            "Content-Length: 0",
        ])
        let response = try #require(try SIPParser.parse(data).asResponse)
        #expect(response.reasonPhrase == "Temporarily Unavailable")
    }

    @Test("Категории кодов ответа")
    func responseCategories() {
        #expect(SIPResponse(statusCode: 100).category == .provisional)
        #expect(SIPResponse(statusCode: 200).category == .success)
        #expect(SIPResponse(statusCode: 302).category == .redirect)
        #expect(SIPResponse(statusCode: 401).category == .clientError)
        #expect(SIPResponse(statusCode: 503).category == .serverError)
        #expect(SIPResponse(statusCode: 603).category == .globalError)
        #expect(SIPResponse(statusCode: 200).reasonPhrase == "OK")
    }

    @Test("Ошибки разбора называются своими именами")
    func errors() {
        func kind(of data: Data) -> SIPParseError.Kind? {
            do {
                _ = try SIPParser.parse(data)
                return nil
            } catch let error as SIPParseError {
                return error.kind
            } catch {
                return nil
            }
        }

        #expect(kind(of: Data()) == .empty)
        #expect(kind(of: Data("REGISTER sip:host SIP/2.0\r\n".utf8)) == .missingHeaderTerminator)
        #expect(kind(of: sipMessage(["REGISTER sip:host SIP/1.0"])) == .unsupportedVersion)
        #expect(kind(of: sipMessage(["PUBLISH sip:host SIP/2.0"])) == .unknownMethod)
        #expect(kind(of: sipMessage(["SIP/2.0 999 Nope"])) == .invalidStatusCode)
        #expect(kind(of: sipMessage(["SIP/2.0 abc Nope"])) == .invalidStatusCode)
        #expect(kind(of: sipMessage(["REGISTER sip:host SIP/2.0", "БезДвоеточия"])) == .malformedHeader)
        #expect(
            kind(of: sipMessage(["SIP/2.0 200 OK", "Content-Length: 100"], body: "коротко")) == .truncatedBody,
            "объявленное тело длиннее фактического — это обрыв, а не пустое тело"
        )
    }

    @Test("Сериализация выставляет Content-Length по факту")
    func encodingFixesContentLength() throws {
        var request = SIPRequest(method: .invite, uri: SIPURI(host: "host"))
        request.headers.append("Call-ID", "c1")
        request.headers.append("Content-Length", "999")   // намеренно неверно
        request.body = Data("v=0\r\n".utf8)

        let encoded = request.encoded()
        let parsed = try #require(try SIPParser.parse(encoded).asRequest)
        #expect(parsed.headers.integer("Content-Length") == 5)
        #expect(parsed.body == request.body)
        #expect(parsed.headers.values("Content-Length").count == 1, "не должно остаться двух Content-Length")
    }

    @Test("Round-trip запроса и ответа")
    func roundTrip() throws {
        var request = SIPRequest(method: .register, uri: SIPURI(host: "127.0.0.1"))
        request.headers.append("Via", "SIP/2.0/TLS 10.0.0.5:5061;branch=\(SIPToken.branch())")
        request.headers.append("From", NameAddress(displayName: "Agent 100", uri: SIPURI(user: "100", host: "127.0.0.1"), parameters: [.init(name: "tag", value: "t1")]).description)
        request.headers.append("To", "<sip:100@127.0.0.1>")
        request.headers.append("Call-ID", SIPToken.callID())
        request.headers.append("CSeq", "1 REGISTER")
        request.headers.append("Max-Forwards", "70")

        let parsed = try #require(try SIPParser.parse(request.encoded()).asRequest)
        #expect(parsed.method == request.method)
        #expect(parsed.uri == request.uri)
        #expect(parsed.from == request.from)
        #expect(parsed.topVia == request.topVia)
        #expect(parsed.callID == request.callID)
    }
}
