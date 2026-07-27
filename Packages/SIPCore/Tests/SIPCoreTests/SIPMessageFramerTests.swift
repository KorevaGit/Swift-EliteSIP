import Foundation
import Testing
@testable import SIPCore

@Suite("Фреймер потока")
struct SIPMessageFramerTests {

    private func options(callID: String, body: String = "") -> Data {
        sipMessage([
            "OPTIONS sip:100@10.0.0.5 SIP/2.0",
            "Via: SIP/2.0/TLS pbx;branch=z9hG4bK\(callID)",
            "Call-ID: \(callID)",
            "CSeq: 1 OPTIONS",
            "Content-Length: \(body.utf8.count)",
        ], body: body)
    }

    @Test("Два сообщения в одном чанке разбираются по отдельности")
    func splitsConcatenatedMessages() throws {
        var framer = SIPMessageFramer()
        var chunk = options(callID: "one")
        chunk.append(options(callID: "two"))
        framer.append(chunk)

        let messages = try framer.drainMessages()
        #expect(messages.count == 2)
        #expect(messages[0].asRequest?.callID == "one")
        #expect(messages[1].asRequest?.callID == "two")
        #expect(framer.bufferedByteCount == 0)
    }

    @Test("Сообщение, разорванное по байту, собирается целиком")
    func reassemblesByteByByte() throws {
        var framer = SIPMessageFramer()
        let message = options(callID: "slow", body: "v=0\r\n")

        var delivered: [SIPMessage] = []
        for byte in message {
            framer.append(Data([byte]))
            delivered.append(contentsOf: try framer.drainMessages())
        }

        #expect(delivered.count == 1)
        #expect(delivered.first?.asRequest?.callID == "slow")
        #expect(framer.bufferedByteCount == 0)
    }

    @Test("Ждёт тело, если по Content-Length его ещё не всё")
    func waitsForBody() throws {
        var framer = SIPMessageFramer()
        let full = options(callID: "partial", body: "v=0\r\ns=x\r\n")
        framer.append(full.prefix(full.count - 4))

        #expect(try framer.nextMessageData() == nil, "тело не дошло — сообщение отдавать нельзя")

        framer.append(full.suffix(4))
        #expect(try framer.nextMessageData() != nil)
    }

    @Test("Одинокие CRLF между сообщениями выбрасываются")
    func skipsKeepAlivePings() throws {
        // На TLS Asterisk и клиенты гоняют CRLF как keep-alive. Если не
        // выбросить их здесь, парсер решит, что соединение сломано.
        var framer = SIPMessageFramer()
        framer.append(Data("\r\n\r\n\r\n".utf8))
        framer.append(options(callID: "after-ping"))

        let messages = try framer.drainMessages()
        #expect(messages.count == 1)
        #expect(messages.first?.asRequest?.callID == "after-ping")
    }

    @Test("Только keep-alive и ничего больше — не сообщение и не ошибка")
    func pingOnlyYieldsNothing() throws {
        var framer = SIPMessageFramer()
        framer.append(Data("\r\n".utf8))
        #expect(try framer.nextMessageData() == nil)
        #expect(framer.bufferedByteCount == 0)
    }

    @Test("Слишком большое сообщение не растит буфер бесконечно")
    func rejectsOversizedMessage() {
        var framer = SIPMessageFramer(maximumMessageSize: 512)
        // Заголовки, которые никогда не кончатся.
        framer.append(Data(String(repeating: "X: y\r\n", count: 200).utf8))

        #expect(throws: SIPMessageFramer.FramingError.self) {
            _ = try framer.nextMessageData()
        }
    }

    @Test("Битый Content-Length — явная ошибка, а не тишина")
    func rejectsMalformedContentLength() {
        var framer = SIPMessageFramer()
        framer.append(sipMessage([
            "OPTIONS sip:host SIP/2.0",
            "Call-ID: c1",
            "Content-Length: не число",
        ]))

        #expect(throws: SIPMessageFramer.FramingError.self) {
            _ = try framer.nextMessageData()
        }
    }
}
