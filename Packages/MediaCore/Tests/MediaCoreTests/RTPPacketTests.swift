import Foundation
import Testing
@testable import MediaCore

@Suite("Пакеты RTP")
struct RTPPacketTests {

    /// Заголовок настоящего пакета: V=2, PT=0 (PCMU), seq=1000, ts=160000,
    /// ssrc=0x12345678, плюс 160 байт тишины µ-law.
    private var sampleHeader: [UInt8] {
        [0x80, 0x00, 0x03, 0xE8, 0x00, 0x02, 0x71, 0x00, 0x12, 0x34, 0x56, 0x78]
    }

    @Test("Разбирает пакет с фиксированным заголовком")
    func parsesFixedHeader() throws {
        var bytes = sampleHeader
        bytes.append(contentsOf: [UInt8](repeating: G711.muLawSilence, count: 160))

        let packet = try RTPPacket(parsing: Data(bytes))
        #expect(packet.payloadType == 0)
        #expect(packet.sequenceNumber == 1000)
        #expect(packet.timestamp == 160_000)
        #expect(packet.ssrc == 0x1234_5678)
        #expect(!packet.marker)
        #expect(packet.csrcs.isEmpty)
        #expect(packet.payload.count == 160)
    }

    @Test("Round-trip байт в байт")
    func roundTrip() throws {
        let packet = RTPPacket(
            payloadType: 8,
            sequenceNumber: 65_535,
            timestamp: 4_294_967_295,
            ssrc: 0xDEAD_BEEF,
            marker: true,
            payload: Data([1, 2, 3, 4])
        )
        let encoded = packet.encoded()
        #expect(encoded.count == RTPPacket.headerByteCount + 4)

        let decoded = try RTPPacket(parsing: encoded)
        #expect(decoded == packet)
    }

    @Test("Маркер и payload type не путаются между собой")
    func markerBitDoesNotLeakIntoPayloadType() throws {
        // Маркер живёт в старшем бите того же байта, что и payload type.
        // Классическая ошибка — прочитать PT как 0x80|PT.
        let marked = RTPPacket(payloadType: 101, sequenceNumber: 1, timestamp: 0, ssrc: 1, marker: true, payload: Data())
        let decoded = try RTPPacket(parsing: marked.encoded())
        #expect(decoded.payloadType == 101)
        #expect(decoded.marker)

        let plain = RTPPacket(payloadType: 101, sequenceNumber: 1, timestamp: 0, ssrc: 1, marker: false, payload: Data())
        #expect(try RTPPacket(parsing: plain.encoded()).marker == false)
    }

    @Test("Отбрасывает дополнение")
    func stripsPadding() throws {
        var bytes = sampleHeader
        bytes[0] |= 0b0010_0000                       // флаг P
        bytes.append(contentsOf: [0xAA, 0xBB])        // полезная нагрузка
        bytes.append(contentsOf: [0x00, 0x00, 0x03])  // 3 байта дополнения

        let packet = try RTPPacket(parsing: Data(bytes))
        #expect(packet.payload == Data([0xAA, 0xBB]), "дополнение не должно попасть в звук")
    }

    @Test("Перешагивает расширение заголовка")
    func skipsExtension() throws {
        var bytes = sampleHeader
        bytes[0] |= 0b0001_0000                                   // флаг X
        bytes.append(contentsOf: [0xBE, 0xDE, 0x00, 0x01])        // профиль + длина 1 слово
        bytes.append(contentsOf: [0x01, 0x02, 0x03, 0x04])        // само расширение
        bytes.append(contentsOf: [0x11, 0x22])                    // полезная нагрузка

        let packet = try RTPPacket(parsing: Data(bytes))
        // Если расширение не перешагнуть, первые байты звука окажутся мусором.
        #expect(packet.payload == Data([0x11, 0x22]))
    }

    @Test("Читает список CSRC")
    func parsesCSRC() throws {
        var bytes = sampleHeader
        bytes[0] |= 2                                              // CC = 2
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x02])
        bytes.append(0xFF)

        let packet = try RTPPacket(parsing: Data(bytes))
        #expect(packet.csrcs == [1, 2])
        #expect(packet.payload == Data([0xFF]))
    }

    @Test("Мусор отвергается с понятной ошибкой")
    func rejectsGarbage() {
        #expect(throws: RTPPacket.ParseError.tooShort(byteCount: 4)) {
            _ = try RTPPacket(parsing: Data([0x80, 0x00, 0x00, 0x00]))
        }

        var wrongVersion = sampleHeader
        wrongVersion[0] = 0x40   // V = 1
        #expect(throws: RTPPacket.ParseError.unsupportedVersion(1)) {
            _ = try RTPPacket(parsing: Data(wrongVersion))
        }

        var truncatedCSRC = sampleHeader
        truncatedCSRC[0] |= 3    // обещаны три CSRC, а их нет
        #expect(throws: RTPPacket.ParseError.truncatedCSRC) {
            _ = try RTPPacket(parsing: Data(truncatedCSRC))
        }
    }
}

@Suite("События telephone-event")
struct TelephoneEventTests {

    @Test("Round-trip полезной нагрузки")
    func roundTrip() throws {
        let payload = TelephoneEventPayload(event: 5, isEnd: true, volume: 10, duration: 1600)
        let decoded = try #require(TelephoneEventPayload(parsing: payload.encoded))
        #expect(decoded == payload)
        #expect(payload.encoded.count == TelephoneEventPayload.byteCount)
    }

    @Test("Флаг конца и громкость лежат в одном байте и не мешают друг другу")
    func endFlagAndVolume() throws {
        let notEnded = TelephoneEventPayload(event: 1, isEnd: false, volume: 63, duration: 160)
        let decoded = try #require(TelephoneEventPayload(parsing: notEnded.encoded))
        #expect(!decoded.isEnd)
        #expect(decoded.volume == 63)

        let ended = TelephoneEventPayload(event: 1, isEnd: true, volume: 0, duration: 160)
        #expect(try #require(TelephoneEventPayload(parsing: ended.encoded)).isEnd)
    }

    @Test("Громкость не выходит за пределы шести бит")
    func volumeIsClamped() {
        #expect(TelephoneEventPayload(event: 0, volume: 200, duration: 0).volume == 63)
    }

    @Test("Коды событий по RFC 4733")
    func eventCodes() {
        #expect(TelephoneEventPayload.event(for: "0") == 0)
        #expect(TelephoneEventPayload.event(for: "9") == 9)
        #expect(TelephoneEventPayload.event(for: "*") == 10)
        #expect(TelephoneEventPayload.event(for: "#") == 11)
        #expect(TelephoneEventPayload.event(for: "A") == 12)
        #expect(TelephoneEventPayload.event(for: "D") == 15)
        #expect(TelephoneEventPayload.event(for: "Z") == nil)

        // Обратное преобразование пригодится для входящего DTMF.
        for character in "0123456789*#ABCD" {
            let code = TelephoneEventPayload.event(for: character)
            let back = code.flatMap { TelephoneEventPayload.character(for: $0) }
            #expect(back == character, "\(character) не выжил round-trip")
        }
    }

    @Test("Весь набор кодов из нашего предложения разбирается")
    func supportedRangeIsConsistent() {
        // В SDP мы объявляем 0-16, значит все эти коды должны быть осмысленными.
        for code in UInt8(0)...UInt8(15) {
            #expect(TelephoneEventPayload.character(for: code) != nil, "код \(code) не отображается")
        }
    }
}
