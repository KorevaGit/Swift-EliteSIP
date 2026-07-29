import Foundation
import Testing
@testable import MediaCore

/// SDP ровно в том виде, в каком его присылает chan_sip из Asterisk 13.
private let asteriskOffer = """
v=0\r
o=root 1962650862 1962650862 IN IP4 172.17.0.2\r
s=Asterisk PBX 13.38.3\r
c=IN IP4 172.17.0.2\r
t=0 0\r
m=audio 14028 RTP/AVP 0 8 101\r
a=rtpmap:0 PCMU/8000\r
a=rtpmap:8 PCMA/8000\r
a=rtpmap:101 telephone-event/8000\r
a=fmtp:101 0-16\r
a=maxptime:150\r
a=sendrecv\r

"""

@Suite("SDP")
struct SDPTests {

    @Test("Разбирает предложение от chan_sip")
    func parsesAsteriskOffer() throws {
        let sdp = try SessionDescription(parsing: asteriskOffer)

        #expect(sdp.origin.username == "root")
        #expect(sdp.origin.sessionID == 1962650862)
        #expect(sdp.connection?.address == "172.17.0.2")
        #expect(sdp.sessionName == "Asterisk PBX 13.38.3")

        let audio = try #require(sdp.audio)
        #expect(audio.port == 14028)
        #expect(audio.protocolName == "RTP/AVP")
        #expect(audio.formats == [0, 8, 101])
        #expect(audio.direction == .sendrecv)

        let maps = audio.rtpMaps
        #expect(maps[0]?.encodingName == "PCMU")
        #expect(maps[8]?.encodingName == "PCMA")
        #expect(maps[101]?.isTelephoneEvent == true)
        #expect(maps[101]?.clockRate == 8000)

        // Незнакомые строки не теряются — иначе при отладке непонятно, что
        // прислал сервер.
        #expect(audio.attribute("maxptime") == "150")
    }

    @Test("Направление по умолчанию — sendrecv")
    func defaultDirection() throws {
        let text = """
        v=0\r
        o=- 1 1 IN IP4 10.0.0.1\r
        s=-\r
        c=IN IP4 10.0.0.1\r
        t=0 0\r
        m=audio 4000 RTP/AVP 0\r
        a=rtpmap:0 PCMU/8000\r

        """
        let sdp = try SessionDescription(parsing: text)
        // RFC 4566 §6: отсутствие атрибута равносильно sendrecv.
        #expect(sdp.audio?.direction == .sendrecv)
    }

    @Test("Читает удержание как sendonly и порт 0")
    func parsesHold() throws {
        let text = """
        v=0\r
        o=- 1 2 IN IP4 10.0.0.1\r
        s=-\r
        c=IN IP4 10.0.0.1\r
        t=0 0\r
        m=audio 0 RTP/AVP 0\r
        a=rtpmap:0 PCMU/8000\r
        a=sendonly\r

        """
        let sdp = try SessionDescription(parsing: text)
        #expect(sdp.audio?.direction == .sendonly)
        #expect(sdp.audio?.port == 0)
    }

    @Test("Round-trip сохраняет смысл")
    func roundTrip() throws {
        let original = try SessionDescription(parsing: asteriskOffer)
        let reparsed = try SessionDescription(parsing: original.encoded)

        #expect(reparsed.origin == original.origin)
        #expect(reparsed.connection == original.connection)
        #expect(reparsed.audio?.port == original.audio?.port)
        #expect(reparsed.audio?.formats == original.audio?.formats)
        #expect(reparsed.audio?.rtpMaps == original.audio?.rtpMaps)
        #expect(reparsed.audio?.direction == original.audio?.direction)
    }

    @Test("Сериализация соблюдает порядок строк по RFC 4566")
    func encodingOrder() {
        let sdp = SDPNegotiator.makeOffer(address: "10.0.0.5", port: 10000, sessionID: 42)
        let lines = sdp.encoded
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n")
            .map(String.init)

        // Часть реализаций разбирает SDP последовательно и на перестановке
        // строк ломается, поэтому порядок проверяется явно.
        #expect(lines[0] == "v=0")
        #expect(lines[1].hasPrefix("o="))
        #expect(lines[2].hasPrefix("s="))
        #expect(lines[3].hasPrefix("c="))
        #expect(lines[4].hasPrefix("t="))
        let mediaIndex = try? #require(lines.firstIndex { $0.hasPrefix("m=") })
        #expect(mediaIndex == 5)
        // Все a= после m= относятся к секции.
        #expect(lines.dropFirst(6).allSatisfy { $0.hasPrefix("a=") || $0.isEmpty })
        #expect(sdp.encoded.hasSuffix("\r\n"))
    }

    @Test("Ошибки разбора называются своими именами")
    func errors() {
        func kind(of text: String) -> SDPParseError.Kind? {
            do {
                _ = try SessionDescription(parsing: text)
                return nil
            } catch let error as SDPParseError {
                return error.kind
            } catch {
                return nil
            }
        }

        #expect(kind(of: "") == .empty)
        #expect(kind(of: "s=нет origin\r\n") == .missingOrigin)
        #expect(kind(of: "v=1\r\n") == .unsupportedVersion)
        #expect(kind(of: "v=0\r\no=мало полей\r\n") == .malformedOrigin)
        #expect(kind(of: "v=0\r\no=- 1 1 IN IP4 h\r\nm=audio плохо RTP/AVP 0\r\n") == .malformedMedia)
    }

    @Test("Адрес с TTL и порт с числом каналов не ломают разбор")
    func toleratesSuffixes() throws {
        let text = """
        v=0\r
        o=- 1 1 IN IP4 10.0.0.1\r
        s=-\r
        c=IN IP4 224.0.0.1/127\r
        t=0 0\r
        m=audio 5004/2 RTP/AVP 0\r

        """
        let sdp = try SessionDescription(parsing: text)
        #expect(sdp.connection?.address == "224.0.0.1")
        #expect(sdp.audio?.port == 5004)
    }

    @Test("Строка c= внутри секции важнее сессионной")
    func perMediaConnectionWins() throws {
        let text = """
        v=0\r
        o=- 1 1 IN IP4 10.0.0.1\r
        s=-\r
        c=IN IP4 10.0.0.1\r
        t=0 0\r
        m=audio 4000 RTP/AVP 0\r
        c=IN IP4 192.168.1.77\r
        a=rtpmap:0 PCMU/8000\r

        """
        let sdp = try SessionDescription(parsing: text)
        #expect(sdp.connection?.address == "10.0.0.1")
        #expect(sdp.audio?.connection?.address == "192.168.1.77")

        let media = try SDPNegotiator.resolveAnswer(
            sdp,
            toOffer: SDPNegotiator.makeOffer(address: "10.0.0.5", port: 10000)
        )
        #expect(media.remoteAddress == "192.168.1.77", "медиа надо отправлять по адресу секции")
    }
}

@Suite("Согласование SDP")
struct SDPNegotiationTests {

    @Test("Защищённое предложение использует RTP/SAVP и валидный SDES")
    func secureOfferContents() throws {
        let offer = SDPNegotiator.makeOffer(
            address: "10.0.0.5",
            port: 10000,
            security: .sdesRequired
        )
        let audio = try #require(offer.audio)
        let crypto = try #require(audio.sdesCryptoAttributes.first)

        #expect(audio.protocolName == "RTP/SAVP")
        #expect(crypto.tag == 1)
        #expect(crypto.suite == .aesCM128HMACSHA1_80)
        #expect(crypto.key.bytes.count == 30)
        #expect(offer.encoded.contains("a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:"))
    }

    @Test("SDES согласует разные ключи направлений")
    func resolvesSecureAnswer() throws {
        let offer = SDPNegotiator.makeOffer(
            address: "10.0.0.5",
            port: 10000,
            security: .sdesRequired
        )
        let local = try #require(offer.audio?.sdesCryptoAttributes.first)
        let remoteKey = SRTPMasterKey.random()
        let answer = try SessionDescription(parsing: """
        v=0\r
        o=root 1 1 IN IP4 172.17.0.2\r
        s=Asterisk\r
        c=IN IP4 172.17.0.2\r
        t=0 0\r
        m=audio 14028 RTP/SAVP 0\r
        a=rtpmap:0 PCMU/8000\r
        a=crypto:\(SDESCryptoAttribute(tag: local.tag, key: remoteKey).value)\r

        """)

        let media = try SDPNegotiator.resolveAnswer(answer, toOffer: offer)
        #expect(media.security == .sdes(local: local.key, remote: remoteKey))
    }

    @Test("SRTP не откатывается на открытый RTP")
    func secureOfferRejectsPlainAnswer() throws {
        let offer = SDPNegotiator.makeOffer(
            address: "10.0.0.5",
            port: 10000,
            security: .sdesRequired
        )
        let answer = try SessionDescription(parsing: """
        v=0\r
        o=root 1 1 IN IP4 172.17.0.2\r
        s=Asterisk\r
        c=IN IP4 172.17.0.2\r
        t=0 0\r
        m=audio 14028 RTP/AVP 0\r
        a=rtpmap:0 PCMU/8000\r

        """)

        #expect(throws: SDPNegotiationError.secureMediaRequired) {
            _ = try SDPNegotiator.resolveAnswer(answer, toOffer: offer)
        }
    }

    @Test("Предложение содержит всё, чего ждёт Asterisk")
    func offerContents() throws {
        let offer = SDPNegotiator.makeOffer(address: "10.0.0.5", port: 10000, sessionID: 7)
        let audio = try #require(offer.audio)

        #expect(
            audio.formats == [9, 0, 8, 101],
            "G.722 первым — единственный широкополосный; дальше PCMU, как настроен боевой пир"
        )
        #expect(audio.rtpMaps[0]?.encodingName == "PCMU")
        #expect(audio.rtpMaps[9]?.encodingName == "G722")
        // В SDP у G.722 объявляется частота 8000, хотя оцифровывает он на
        // 16 000. Это ошибка RFC 1890, оставленная в RFC 3551 §4.5.2 ради
        // совместимости: серверы ждут именно 8000, и «исправление» здесь
        // ломает согласование.
        #expect(audio.rtpMaps[9]?.clockRate == 8000)
        #expect(audio.rtpMaps[101]?.isTelephoneEvent == true)
        // Без fmtp часть серверов не понимает, какие события мы принимаем,
        // и отбрасывает DTMF.
        #expect(audio.attribute("fmtp") == "101 0-16")
        #expect(audio.attribute("ptime") == "20")
        #expect(audio.direction == .sendrecv)
        #expect(offer.connection?.address == "10.0.0.5")
    }

    @Test("Разбирает ответ Asterisk и выбирает кодек по его порядку")
    func resolvesAnswer() throws {
        let offer = SDPNegotiator.makeOffer(address: "10.0.0.5", port: 10000)
        let answerText = """
        v=0\r
        o=root 1 1 IN IP4 172.17.0.2\r
        s=Asterisk PBX 13.38.3\r
        c=IN IP4 172.17.0.2\r
        t=0 0\r
        m=audio 14028 RTP/AVP 8 101\r
        a=rtpmap:8 PCMA/8000\r
        a=rtpmap:101 telephone-event/8000\r
        a=ptime:20\r
        a=sendrecv\r

        """
        let answer = try SessionDescription(parsing: answerText)
        let media = try SDPNegotiator.resolveAnswer(answer, toOffer: offer)

        // Мы предлагали PCMU первым, сервер выбрал PCMA — слушаемся сервера.
        #expect(media.codec == .pcma)
        #expect(media.payloadType == 8)
        #expect(media.telephoneEventPayloadType == 101)
        #expect(media.remoteAddress == "172.17.0.2")
        #expect(media.remotePort == 14028)
        #expect(media.direction == .sendrecv)
        #expect(!media.isHeld)
    }

    @Test("Опознаёт статический payload type без rtpmap")
    func staticPayloadTypeWithoutRTPMap() throws {
        // chan_sip иногда не присылает rtpmap для 0 и 8: RFC 3551 закрепляет их
        // жёстко. Требовать rtpmap в этом случае — значит рвать совместимость.
        let answerText = """
        v=0\r
        o=root 1 1 IN IP4 172.17.0.2\r
        s=-\r
        c=IN IP4 172.17.0.2\r
        t=0 0\r
        m=audio 14028 RTP/AVP 0\r

        """
        let media = try SDPNegotiator.resolveAnswer(
            try SessionDescription(parsing: answerText),
            toOffer: SDPNegotiator.makeOffer(address: "10.0.0.5", port: 10000)
        )
        #expect(media.codec == .pcmu)
        #expect(media.payloadType == 0)
        #expect(media.telephoneEventPayloadType == nil)
    }

    @Test("Отсутствие общего кодека — явная ошибка")
    func noCommonCodec() throws {
        let answerText = """
        v=0\r
        o=root 1 1 IN IP4 172.17.0.2\r
        s=-\r
        c=IN IP4 172.17.0.2\r
        t=0 0\r
        m=audio 14028 RTP/AVP 18\r
        a=rtpmap:18 G729/8000\r

        """
        let answer = try SessionDescription(parsing: answerText)
        // G.729 требует лицензии и отдельного модуля — мы его не предлагаем и
        // принять не можем.
        #expect(throws: SDPNegotiationError.noCommonCodec(offered: [18])) {
            _ = try SDPNegotiator.resolveAnswer(
                answer,
                toOffer: SDPNegotiator.makeOffer(address: "10.0.0.5", port: 10000)
            )
        }
    }

    @Test("Порт 0 в ответе означает удержание")
    func detectsHold() throws {
        let answerText = """
        v=0\r
        o=root 1 2 IN IP4 172.17.0.2\r
        s=-\r
        c=IN IP4 172.17.0.2\r
        t=0 0\r
        m=audio 0 RTP/AVP 0\r
        a=rtpmap:0 PCMU/8000\r
        a=sendonly\r

        """
        let media = try SDPNegotiator.resolveAnswer(
            try SessionDescription(parsing: answerText),
            toOffer: SDPNegotiator.makeOffer(address: "10.0.0.5", port: 10000)
        )
        #expect(media.isHeld)
        #expect(media.direction == .recvonly, "собеседник только отправляет — значит мы только слушаем")
    }

    @Test("Составляет ответ на чужое предложение")
    func makesAnswer() throws {
        let offer = try SessionDescription(parsing: asteriskOffer)
        let (answer, media) = try SDPNegotiator.makeAnswer(to: offer, address: "10.0.0.5", port: 10500)

        let audio = try #require(answer.audio)
        #expect(audio.port == 10500)
        #expect(audio.formats.first == 0, "берём первый общий кодек в порядке предложения")
        #expect(audio.formats.contains(101), "telephone-event подтверждаем, если его предложили")
        #expect(answer.connection?.address == "10.0.0.5")
        #expect(audio.direction == .sendrecv)

        #expect(media.codec == .pcmu)
        #expect(media.remoteAddress == "172.17.0.2")
        #expect(media.remotePort == 14028)
    }

    @Test("Ответ на удержание разворачивает направление")
    func answersHold() throws {
        let holdOffer = try SessionDescription(parsing: """
        v=0\r
        o=root 1 2 IN IP4 172.17.0.2\r
        s=-\r
        c=IN IP4 172.17.0.2\r
        t=0 0\r
        m=audio 14028 RTP/AVP 0\r
        a=rtpmap:0 PCMU/8000\r
        a=sendonly\r

        """)
        let (answer, media) = try SDPNegotiator.makeAnswer(to: holdOffer, address: "10.0.0.5", port: 10500)
        // Собеседник только отправляет — значит мы обязаны объявить recvonly.
        #expect(answer.audio?.direction == .recvonly)
        #expect(media.direction == .recvonly)
    }

    @Test("Ответная сессия занимает порт и отдаёт его в SDP")
    func mediaSessionAnswerReservesPort() throws {
        let offer = try SessionDescription(parsing: asteriskOffer)
        let result = try MediaSession.makeAnswer(to: offer, localAddress: "10.0.0.5")

        #expect(result.answer.audio?.port == result.port)
        #expect(result.port.isMultiple(of: 2), "RTCP живёт на порту плюс один — значит наш обязан быть чётным")
        #expect(result.media.codec == .pcmu)
    }

    @Test("Обязательный SRTP не принимает открытое предложение")
    func mediaSessionAnswerRefusesPlainOfferWhenSecured() throws {
        let offer = try SessionDescription(parsing: asteriskOffer)
        // Молча ответить открытым RTP на TLS-профиле — это незаметный downgrade
        // ровно того рода, от которого закрывались в M2b.
        #expect(throws: SDPNegotiationError.secureMediaRequired) {
            try MediaSession.makeAnswer(to: offer, localAddress: "10.0.0.5", security: .sdesRequired)
        }
    }

    @Test("Таблица пересечения направлений")
    func directionIntersection() {
        #expect(SDPNegotiator.intersect(ours: .sendrecv, theirs: .sendrecv) == .sendrecv)
        #expect(SDPNegotiator.intersect(ours: .sendrecv, theirs: .sendonly) == .recvonly)
        #expect(SDPNegotiator.intersect(ours: .sendrecv, theirs: .recvonly) == .sendonly)
        #expect(SDPNegotiator.intersect(ours: .sendrecv, theirs: .inactive) == .inactive)
        #expect(SDPNegotiator.intersect(ours: .sendonly, theirs: .sendonly) == .inactive)
        #expect(SDPNegotiator.intersect(ours: .recvonly, theirs: .sendrecv) == .recvonly)
        #expect(SDPNegotiator.intersect(ours: .inactive, theirs: .sendrecv) == .inactive)
    }
}
