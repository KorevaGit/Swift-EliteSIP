import Foundation
import Testing
@testable import MediaCore

@Suite("Медиа-сессия")
struct RTPSessionTests {

    @Test("Занимает чётный порт из диапазона")
    func reservesEvenPort() throws {
        let reservation = try RTPSession.reservePortPair()
        defer { reservation.release() }
        let port = reservation.rtpPort

        // Чётность не эстетика: по RFC 3550 §11 за RTP-портом идёт RTCP на
        // порт+1, и нечётный порт ломает это соглашение.
        #expect(port.isMultiple(of: 2), "порт \(port) нечётный")
        #expect(RTPSession.defaultPortRange.contains(port))
        #expect(reservation.rtcpPort == port + 1)
    }

    @Test("Две подготовленные линии удерживают разные пары портов")
    func simultaneousReservationsAreDistinct() throws {
        let first = try RTPSession.reservePortPair()
        defer { first.release() }
        let second = try RTPSession.reservePortPair()
        defer { second.release() }

        #expect(first.rtpPort != second.rtpPort)
        #expect(first.rtcpPort != second.rtcpPort)
    }

    @Test("Диапазон по умолчанию согласован с лабораторией")
    func portRangeMatchesLab() {
        // Диапазон должен помещаться в тот, что опубликован в docker-compose и
        // прописан в rtp.conf. Разъезд здесь означает звук в одну сторону.
        #expect(RTPSession.defaultPortRange.lowerBound >= 16384)
        #expect(RTPSession.defaultPortRange.count >= 50, "слишком узко для нескольких линий")
    }

    @Test("Пустой диапазон даёт понятную ошибку, а не молчание")
    func emptyRangeThrows() {
        // Заведомо занятый системой диапазон из одного нечётного порта.
        #expect(throws: RTPSession.SessionError.self) {
            _ = try RTPSession.reservePortPair(in: 1...1)
        }
    }

    @Test("Настройки строятся из результата согласования SDP")
    func configurationFromNegotiation() {
        let negotiated = NegotiatedMedia(
            codec: .pcma,
            payloadType: 8,
            telephoneEventPayloadType: 101,
            remoteAddress: "172.17.0.2",
            remotePort: 14028,
            packetTimeMilliseconds: 20
        )
        let configuration = RTPSession.Configuration(negotiated: negotiated)

        #expect(configuration.codec == .pcma)
        #expect(configuration.payloadType == 8)
        #expect(configuration.telephoneEventPayloadType == 101)
        // 20 мс при 8 кГц — это 160 отсчётов, и на столько же растёт метка
        // времени в каждом пакете.
        #expect(configuration.timestampIncrement == 160)

        // У G.722 отсчётов вдвое больше, а метка растёт на те же 160: частота
        // часов RTP у него объявлена 8000 при выборке 16 000 (RFC 3551 §4.5.2).
        let wideband = RTPSession.Configuration(codec: .g722, payloadType: 9)
        #expect(wideband.timestampIncrement == 160)
        #expect(AudioCodec.g722.sampleCount(forPacketTime: 20) == 320)
    }
}
