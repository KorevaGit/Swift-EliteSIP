import Foundation
import Testing
@testable import MediaCore

/// Удержание: повторное предложение и разбор чужого.
///
/// Удержание в SIP — это не команда, а пересогласование медиа, и вся его логика
/// живёт в SDP. Здесь проверяется именно она: что мы отправляем, ставя разговор
/// на удержание, и как опознаём, что на удержание поставили нас — во всех трёх
/// записях, которые встречаются у Asterisk.
@Suite("Удержание")
struct HoldTests {

    private func offer(port: UInt16 = 16000) -> SessionDescription {
        SDPNegotiator.makeOffer(address: "192.168.1.50", port: port)
    }

    private func secureOffer() -> SessionDescription {
        SDPNegotiator.makeOffer(address: "192.168.1.50", port: 16000, security: .sdesRequired)
    }

    // MARK: - Наше удержание

    @Test("Повторное предложение меняет только направление")
    func reofferKeepsEverythingButDirection() throws {
        let original = offer()
        let held = SDPNegotiator.makeReoffer(from: original, direction: .sendonly)

        let before = try #require(original.audio)
        let after = try #require(held.audio)

        // Порт объявлен и занят, кодеки согласованы. Всё, что меняется при
        // удержании, — одна строка направления.
        #expect(after.port == before.port)
        #expect(after.formats == before.formats)
        #expect(after.protocolName == before.protocolName)
        #expect(after.direction == .sendonly)
        #expect(before.direction == .sendrecv)
    }

    @Test("Версия сессии растёт: без этого предложение можно не заметить")
    func reofferBumpsSessionVersion() {
        let original = offer()
        let held = SDPNegotiator.makeReoffer(from: original, direction: .sendonly)
        let resumed = SDPNegotiator.makeReoffer(from: held, direction: .sendrecv)

        #expect(held.origin.sessionVersion == original.origin.sessionVersion + 1)
        #expect(resumed.origin.sessionVersion == original.origin.sessionVersion + 2)
        #expect(held.origin.sessionID == original.origin.sessionID, "сессия та же — меняется только её версия")
    }

    @Test("Возврат с удержания не оставляет второго направления")
    func resumeReplacesDirectionAttribute() throws {
        let held = SDPNegotiator.makeReoffer(from: offer(), direction: .sendonly)
        let resumed = SDPNegotiator.makeReoffer(from: held, direction: .sendrecv)

        let audio = try #require(resumed.audio)
        let directions = audio.attributes.filter { attribute in
            MediaDirection.allCases.contains { $0.rawValue == attribute.name }
        }
        // Два направления в одной секции — это описание, которое собеседник
        // прочитает по первому попавшемуся, и удержание останется висеть.
        #expect(directions.count == 1)
        #expect(audio.direction == .sendrecv)
    }

    @Test("Ключ SRTP при удержании не перевыпускается")
    func reofferKeepsCryptoKey() throws {
        let original = secureOffer()
        let held = SDPNegotiator.makeReoffer(from: original, direction: .sendonly)

        let before = try #require(original.audio?.sdesCryptoAttributes.first)
        let after = try #require(held.audio?.sdesCryptoAttributes.first)

        // Новый ключ ради смены строки направления означал бы пересборку
        // контекстов на обеих сторонах — и тишину, если собеседник не успеет.
        #expect(after.key == before.key)
        #expect(after.tag == before.tag)
    }

    // MARK: - Удержание с той стороны

    @Test("Удержание по a=sendonly: нам нельзя отправлять, но адрес живой")
    func recognisesModernHold() throws {
        let answer = """
            v=0\r
            o=root 1 2 IN IP4 172.17.0.2\r
            c=IN IP4 172.17.0.2\r
            t=0 0\r
            m=audio 14002 RTP/AVP 0\r
            a=rtpmap:0 PCMU/8000\r
            a=sendonly\r
            \r
            """
        let media = try SDPNegotiator.resolveAnswer(
            try SessionDescription(parsing: answer), toOffer: offer()
        )

        #expect(media.direction == .recvonly)
        #expect(media.isHeld)
        // Адрес при этом рабочий: музыку ожидания оттуда и слушают.
        #expect(!media.isStreamDisabled)
        #expect(media.remotePort == 14002)
    }

    @Test("Удержание по c=0.0.0.0: старая запись, которую chan_sip шлёт до сих пор")
    func recognisesLegacyHold() throws {
        let answer = """
            v=0\r
            o=root 1 2 IN IP4 172.17.0.2\r
            c=IN IP4 0.0.0.0\r
            t=0 0\r
            m=audio 14002 RTP/AVP 0\r
            a=rtpmap:0 PCMU/8000\r
            a=sendrecv\r
            \r
            """
        let media = try SDPNegotiator.resolveAnswer(
            try SessionDescription(parsing: answer), toOffer: offer()
        )

        // Направление тут врёт: оно осталось sendrecv. Опознать удержание можно
        // только по адресу, и проверка одного направления пропустила бы его.
        #expect(media.direction == .sendrecv)
        #expect(media.isStreamDisabled)
        #expect(media.isHeld)
    }

    @Test("Удержание по a=inactive глушит обе стороны")
    func recognisesInactiveHold() throws {
        let answer = """
            v=0\r
            o=root 1 2 IN IP4 172.17.0.2\r
            c=IN IP4 172.17.0.2\r
            t=0 0\r
            m=audio 14002 RTP/AVP 0\r
            a=rtpmap:0 PCMU/8000\r
            a=inactive\r
            \r
            """
        let media = try SDPNegotiator.resolveAnswer(
            try SessionDescription(parsing: answer), toOffer: offer()
        )

        #expect(media.direction == .inactive)
        #expect(media.isHeld)
        #expect(!media.direction.sendsAudio)
        #expect(!media.direction.receivesAudio)
    }

    @Test("Обычный разговор удержанием не считается")
    func activeCallIsNotHeld() throws {
        let answer = """
            v=0\r
            o=root 1 1 IN IP4 172.17.0.2\r
            c=IN IP4 172.17.0.2\r
            t=0 0\r
            m=audio 14002 RTP/AVP 0\r
            a=rtpmap:0 PCMU/8000\r
            a=sendrecv\r
            \r
            """
        let media = try SDPNegotiator.resolveAnswer(
            try SessionDescription(parsing: answer), toOffer: offer()
        )
        #expect(!media.isHeld)
        #expect(!media.isStreamDisabled)
    }

    // MARK: - Ответ на чужое удержание

    @Test("На чужое удержание отвечаем встречным направлением и своим портом")
    func answersHoldOffer() throws {
        let held = """
            v=0\r
            o=root 1 2 IN IP4 172.17.0.2\r
            c=IN IP4 172.17.0.2\r
            t=0 0\r
            m=audio 14002 RTP/AVP 0 101\r
            a=rtpmap:0 PCMU/8000\r
            a=rtpmap:101 telephone-event/8000\r
            a=sendonly\r
            \r
            """
        let negotiated = try SDPNegotiator.makeAnswer(
            to: try SessionDescription(parsing: held),
            address: "192.168.1.50",
            port: 16000
        )

        // Порт в ответе обязан остаться прежним: он объявлен в начале разговора
        // и занят нашим сокетом, а пересогласование его не освобождает.
        #expect(negotiated.answer.audio?.port == 16000)
        #expect(negotiated.answer.audio?.direction == .recvonly)
        #expect(negotiated.media.direction == .recvonly)
        #expect(negotiated.media.isHeld)
        #expect(negotiated.media.telephoneEventPayloadType == 101)
    }
}
