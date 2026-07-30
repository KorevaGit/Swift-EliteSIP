import Darwin
import Foundation
import Testing
@testable import MediaCore

/// Пересборка потока на том же локальном порту.
///
/// Это единственное место M2, где сокеты закрываются и открываются заново
/// посреди разговора: собеседник поставил на удержание и вернулся с другого
/// порта, или звонок переехал после перевода. Поведение сокетов здесь
/// асинхронное, поэтому проверять его надо живыми сокетами — на структурах
/// ошибка не воспроизводится вовсе.
@Suite("Пересборка потока")
struct StreamRebuildTests {

    /// Отправляет датаграмму на локальный порт. Без Network.framework: тесту
    /// нужен именно чужой сокет, а не вторая копия нашего кода.
    ///
    /// Порт отправителя задаётся не для красоты: `NWConnection` привязывает
    /// UDP-сокет к конкретному собеседнику, и датаграммы с любого другого порта
    /// ядро выбрасывает до нас. Это и есть симметричный RTP.
    private func send(_ payload: Data, toLocalPort port: UInt16, fromLocalPort source: UInt16) throws {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        try #require(descriptor >= 0)
        defer { close(descriptor) }

        var sourceAddress = sockaddr_in()
        sourceAddress.sin_family = sa_family_t(AF_INET)
        sourceAddress.sin_port = source.bigEndian
        sourceAddress.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &sourceAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                bind(descriptor, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(bound == 0, "порт \(source) занят — тест не может изобразить собеседника")

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let sent = payload.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                    sendto(
                        descriptor,
                        bytes.baseAddress,
                        payload.count,
                        0,
                        rebound,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }
        #expect(sent == payload.count)
    }

    /// Повторяет отправку, пока условие не выполнится.
    ///
    /// Повторять обязательно, а не отправить один раз и подождать: `NWConnection`
    /// на UDP становится готов не мгновенно, и датаграммы, пришедшие до
    /// готовности, теряются. Замерено — на это уходят сотни миллисекунд. Живой
    /// собеседник шлёт пятьдесят пакетов в секунду, так что для него это
    /// незаметно, а тест, отправляющий один пакет сразу после запуска, проверял
    /// бы скорость готовности сокета вместо привязки к порту.
    private func pumpUntil(
        _ timeout: TimeInterval = 3,
        send: () throws -> Void,
        condition: () -> Bool
    ) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try send()
            usleep(50_000)
        }
        return condition()
    }

    @Test("RTP снова слышит поток на том же локальном порту после пересборки")
    func rtpRebindsSameLocalPortAfterRenegotiation() throws {
        let reservation = try RTPSession.reservePortPair()
        defer { reservation.release() }

        // Адрес собеседника до и после переезда. Порты заведомо никем не
        // слушаются: нам важен только приём на своей стороне.
        let negotiated = NegotiatedMedia(
            codec: .pcmu,
            payloadType: 0,
            remoteAddress: "127.0.0.1",
            remotePort: 40100
        )
        let session = try MediaSession(negotiated: negotiated, reservation: reservation)
        // Обычно это делает `start()`, но поднимать звуковую карту в тесте
        // нельзя: разрешение на микрофон в CI никто не выдаст.
        reservation.activate()

        var moved = negotiated
        moved.remotePort = 40102
        let outcome = try session.renegotiate(to: moved)
        #expect(outcome == .streamRebuilt, "смена порта собеседника обязана пересобрать поток")

        // Сокет, не переживший пересборку, привязку теряет молча: разговор идёт,
        // а принятого нет. Именно это и проверяется.
        var sequenceNumber: UInt16 = 1000
        let received = try pumpUntil(
            send: {
                let packet = RTPPacket(
                    payloadType: 0,
                    sequenceNumber: sequenceNumber,
                    timestamp: UInt32(sequenceNumber) * 160,
                    ssrc: 0x1234_5678,
                    payload: Data(repeating: 0xFF, count: 160)
                )
                sequenceNumber &+= 1
                try send(packet.encoded(), toLocalPort: session.localPort, fromLocalPort: moved.remotePort)
            },
            condition: { session.statistics.received > 0 }
        )
        #expect(received, "после пересборки поток не принимает пакеты на порту \(session.localPort)")

        session.stop()
    }

    @Test("RTCP занимает свой порт заново сразу после остановки")
    func rtcpRebindsSameLocalPortImmediatelyAfterStop() throws {
        let reservation = try RTPSession.reservePortPair()
        defer { reservation.release() }
        reservation.activate()

        let ssrc: UInt32 = 0x0A0B_0C0D
        let port = reservation.rtcpPort

        func makeSession() -> RTCPSession {
            RTCPSession(
                ssrc: ssrc,
                canonicalName: "test@\(port)",
                clockRate: 8000,
                localPort: port,
                remoteHost: "127.0.0.1",
                remotePort: 40104
            )
        }

        let first = makeSession()
        first.start()
        // `cancel()` асинхронный, и без ожидания внутри `stop()` следующий сокет
        // встаёт на ещё занятый порт. Провал привязки в UDP ничем не мешает
        // разговору — просто отчёты собеседника больше не приходят.
        first.stop()

        let second = makeSession()
        let sawReport = ReportFlag()
        second.onRemoteView = { _ in sawReport.raise() }
        second.start()
        defer { second.stop() }

        // Отчёт собеседника о НАШЕМ потоке: `publish` пропускает блоки про чужие
        // источники, поэтому sourceSSRC обязан совпадать с нашим.
        let report = RTCP.encode(RTCP.ReceiverReport(
            ssrc: 0x9999_9999,
            reports: [
                RTCP.ReportBlock(
                    sourceSSRC: ssrc,
                    fractionLost: 0,
                    cumulativeLost: 0,
                    highestSequenceNumber: 100,
                    jitter: 20,
                    lastSenderReport: 0,
                    delaySinceLastSenderReport: 0
                )
            ]
        ))
        let delivered = try pumpUntil(
            send: { try send(report, toLocalPort: port, fromLocalPort: 40104) },
            condition: { sawReport.isRaised }
        )
        #expect(delivered, "RTCP не принял отчёт на порту \(port) — сокет не переехал")
    }
}

/// Флаг «отчёт пришёл». Обработчик RTCP вызывается на своей очереди, поэтому
/// простая переменная здесь была бы гонкой.
private final class ReportFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func raise() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isRaised: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
