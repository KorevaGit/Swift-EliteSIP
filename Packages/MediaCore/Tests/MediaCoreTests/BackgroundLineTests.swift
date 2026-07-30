import Foundation
import Testing
@testable import MediaCore

/// Линия, ушедшая в фон.
///
/// Аудиотракт у оператора один — один микрофон, один выход, одна обработка
/// голоса, — а разговоров до трёх. Фоновая линия обязана отпустить звуковую
/// карту и при этом не отпустить ничего из того, чем она держится в диалоге:
/// пару портов, сокет RTP и договорённость о медиа. Отпущенный порт означает
/// установленный звонок без звука после возврата — симптом, который в этом
/// проекте уже стоил недели.
@Suite("Фоновая линия")
struct BackgroundLineTests {

    private func negotiated(port: UInt16) -> NegotiatedMedia {
        NegotiatedMedia(
            codec: .pcmu,
            payloadType: 0,
            remoteAddress: "127.0.0.1",
            remotePort: port
        )
    }

    @Test("Три линии готовятся одновременно и не делят порты")
    func threeLinesHoldDistinctPorts() throws {
        var reservations: [RTPPortReservation] = []
        defer { reservations.forEach { $0.release() } }

        for _ in 0..<3 {
            reservations.append(try RTPSession.reservePortPair())
        }

        let rtp = Set(reservations.map(\.rtpPort))
        let rtcp = Set(reservations.map(\.rtcpPort))
        #expect(rtp.count == 3)
        #expect(rtcp.count == 3)
        #expect(rtp.isDisjoint(with: rtcp), "RTCP одной линии не имеет права попасть на RTP другой")
    }

    @Test("Уход в фон не отпускает пару портов")
    func suspendKeepsPortPair() throws {
        let reservation = try RTPSession.reservePortPair()
        defer { reservation.release() }

        let session = try MediaSession(
            negotiated: negotiated(port: 40200),
            reservation: reservation
        )
        // Обычно это делает `start()`, но поднимать звуковую карту в тесте
        // нельзя: разрешение на микрофон в CI никто не выдаст.
        reservation.activate()

        session.suspendAudio()
        #expect(!session.isAudioActive)
        #expect(session.isHeld, "фоновая линия обязана молчать в обе стороны")
        #expect(session.negotiated != nil, "договорённость о медиа переживает уход в фон")

        // Двадцать попыток занять пару подряд: если фоновая линия свой порт
        // отпустила, одна из них на него попадёт.
        var taken: [RTPPortReservation] = []
        defer { taken.forEach { $0.release() } }
        for _ in 0..<20 {
            taken.append(try RTPSession.reservePortPair())
        }
        #expect(!taken.contains { $0.rtpPort == session.localPort })
        #expect(!taken.contains { $0.rtcpPort == session.localPort + 1 })

        session.stop()
    }

    @Test("Фоновая линия не копит принятое")
    func suspendedLineDropsIncomingAudio() throws {
        let reservation = try RTPSession.reservePortPair()
        defer { reservation.release() }
        reservation.activate()

        let session = try MediaSession(
            negotiated: negotiated(port: 40202),
            reservation: reservation
        )
        session.suspendAudio()

        // Музыка ожидания, накопленная за время консультации, к возврату уже
        // безнадёжно старая: проиграть её оператору — значит отдать ему минуту
        // прошлого вместо собеседника.
        let packet = RTPPacket(
            payloadType: 0,
            sequenceNumber: 1,
            timestamp: 160,
            ssrc: 0x1111_2222,
            payload: Data(repeating: G711.muLawSilence, count: 160)
        )
        try send(packet.encoded(), toLocalPort: session.localPort, fromLocalPort: 40202)
        usleep(200_000)

        #expect(session.statistics.received == 0)

        session.stop()
    }

    /// Отправляет датаграмму на локальный порт с заданного локального порта.
    private func send(_ data: Data, toLocalPort port: UInt16, fromLocalPort source: UInt16) throws {
        let socket = socket(AF_INET, SOCK_DGRAM, 0)
        guard socket >= 0 else { return }
        defer { close(socket) }

        var from = sockaddr_in()
        from.sin_family = sa_family_t(AF_INET)
        from.sin_port = source.bigEndian
        from.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        var destination = sockaddr_in()
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = port.bigEndian
        destination.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &destination) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socket, bytes.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}
