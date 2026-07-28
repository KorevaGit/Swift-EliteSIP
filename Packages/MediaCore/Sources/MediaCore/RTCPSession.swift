import Foundation
import Network

/// Обмен отчётами RTCP на соседнем порту.
///
/// По RFC 3550 §11 RTCP живёт на порту RTP плюс один — именно поэтому порт под
/// RTP выбирается чётным.
///
/// Что это даёт на практике. Своя статистика отвечает только на вопрос «что мы
/// приняли». Жалоба почти всегда обратная: «меня плохо слышно», — и проверить
/// её нечем, потому что наш собственный поток мы не слышим. В отчёте приёмника
/// от собеседника приезжают доля потерь нашего потока, джиттер и время
/// кругового обхода, посчитанные им. Это же готовая телеметрия для EliteDash.
public final class RTCPSession: @unchecked Sendable {

    /// Что видит собеседник про наш поток.
    public struct RemoteView: Sendable, Hashable {
        /// Доля потерь за последний интервал, 0…1.
        public var fractionLost: Double
        public var cumulativeLost: Int32
        /// Джиттер в миллисекундах.
        public var jitterMilliseconds: Double
        /// Задержка кругового обхода, если её удалось посчитать.
        public var roundTripTime: TimeInterval?
        public var updatedAt: Date

        public var summary: String {
            var parts = [
                String(format: "потери %.1f %%", fractionLost * 100),
                String(format: "джиттер %.1f мс", jitterMilliseconds),
            ]
            if let roundTripTime {
                parts.append(String(format: "круг %.0f мс", roundTripTime * 1000))
            }
            return parts.joined(separator: ", ")
        }
    }

    /// Что нужно знать, чтобы составить отчёт. Заполняет владелец потока.
    public struct LocalStatistics: Sendable {
        public var packetsSent: UInt32 = 0
        public var octetsSent: UInt32 = 0
        public var rtpTimestamp: UInt32 = 0
        public var remoteSSRC: UInt32?
        /// Доля потерь принятого потока, 0…1.
        public var fractionLost: Double = 0
        public var cumulativeLost: Int32 = 0
        public var highestSequenceNumber: UInt32 = 0
        /// Джиттер принятого потока в единицах часов RTP.
        public var jitter: UInt32 = 0

        public init() {}
    }

    /// Как часто слать отчёты.
    ///
    /// Пять секунд — минимум, разрешённый RFC 3550 §6.2 для двусторонней
    /// сессии. Чаще не нужно и вредно: RTCP не должен занимать больше пяти
    /// процентов полосы разговора.
    public static let reportInterval: TimeInterval = 5

    public var onRemoteView: (@Sendable (RemoteView) -> Void)?
    public var onDiagnostic: (@Sendable (String) -> Void)?

    /// Откуда брать свежую статистику в момент отправки отчёта.
    public var statisticsProvider: (@Sendable () -> LocalStatistics)?

    private let ssrc: UInt32
    private let canonicalName: String
    private let clockRate: UInt32
    private let queue = DispatchQueue(label: "com.elite.EliteSIP.rtcp")
    private let connection: NWConnection

    /// Метка последнего отчёта собеседника и время его получения — из них
    /// считается задержка, которую мы возвращаем ему обратно.
    private var lastRemoteReport: (middleBits: UInt32, receivedAt: Date)?
    private var timer: DispatchSourceTimer?
    private var isStopped = false

    public init(
        ssrc: UInt32,
        canonicalName: String,
        clockRate: UInt32,
        localPort: UInt16,
        remoteHost: String,
        remotePort: UInt16
    ) {
        self.ssrc = ssrc
        self.canonicalName = canonicalName
        self.clockRate = clockRate

        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.any),
            port: NWEndpoint.Port(rawValue: localPort) ?? .any
        )
        connection = NWConnection(
            host: NWEndpoint.Host(remoteHost),
            port: NWEndpoint.Port(rawValue: remotePort) ?? .any,
            using: parameters
        )
    }

    // MARK: - Жизненный цикл

    public func start() {
        connection.start(queue: queue)
        receiveNext()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Первый отчёт с задержкой: сразу после установления соединения слать
        // нечего — ни одного пакета ещё не принято.
        timer.schedule(
            deadline: .now() + Self.reportInterval,
            repeating: Self.reportInterval
        )
        timer.setEventHandler { [weak self] in self?.sendReport() }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        queue.sync {
            guard !isStopped else { return }
            isStopped = true
            timer?.cancel()
            timer = nil
            // Прощание по RFC 3550 §6.6: собеседник сразу освобождает состояние
            // источника, а не ждёт истечения таймаута.
            sendGoodbye()
            connection.cancel()
        }
    }

    // MARK: - Отправка

    private func sendReport() {
        guard !isStopped, let statistics = statisticsProvider?() else { return }

        let ntp = RTCP.ntpTimestamp()
        var blocks: [RTCP.ReportBlock] = []

        if let remoteSSRC = statistics.remoteSSRC {
            // Задержка с момента получения последнего отчёта собеседника — в
            // 1/65536 секунды. По ней он и посчитает время кругового обхода.
            let delay: UInt32
            if let last = lastRemoteReport {
                delay = UInt32(min(Date().timeIntervalSince(last.receivedAt) * 65536, Double(UInt32.max)))
            } else {
                delay = 0
            }

            blocks.append(RTCP.ReportBlock(
                sourceSSRC: remoteSSRC,
                fractionLost: statistics.fractionLost,
                cumulativeLost: statistics.cumulativeLost,
                highestSequenceNumber: statistics.highestSequenceNumber,
                jitter: statistics.jitter,
                lastSenderReport: lastRemoteReport?.middleBits ?? 0,
                delaySinceLastSenderReport: lastRemoteReport == nil ? 0 : delay
            ))
        }

        // Отчёт отправителя, если мы говорим, и приёмника, если только слушаем.
        let report: Data = statistics.packetsSent > 0
            ? RTCP.encode(RTCP.SenderReport(
                ssrc: ssrc,
                ntpTimestamp: ntp,
                rtpTimestamp: statistics.rtpTimestamp,
                packetCount: statistics.packetsSent,
                octetCount: statistics.octetsSent,
                reports: blocks
            ))
            : RTCP.encode(RTCP.ReceiverReport(ssrc: ssrc, reports: blocks))

        connection.send(
            content: RTCP.compound(report: report, ssrc: ssrc, canonicalName: canonicalName),
            completion: .idempotent
        )
    }

    private func sendGoodbye() {
        var data = Data()
        data.append(0x81)                       // версия 2, один источник
        data.append(RTCP.PacketType.goodbye.rawValue)
        data.appendBigEndian(UInt16(1))
        data.appendBigEndian(ssrc)
        connection.send(content: data, completion: .idempotent)
    }

    // MARK: - Приём

    private func receiveNext() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if error != nil { return }

            if let data, !data.isEmpty {
                // Чужой или битый пакет молча пропускаем: на открытый UDP-порт
                // прилетает что угодно, и рвать разговор из-за этого нельзя.
                if let packets = try? RTCP.parse(data) {
                    self.handle(packets)
                }
            }

            guard !self.isStopped else { return }
            self.receiveNext()
        }
    }

    private func handle(_ packets: [RTCP.Packet]) {
        for packet in packets {
            switch packet {
            case .senderReport(let report):
                // Запоминаем метку: собеседник ждёт её обратно, чтобы посчитать
                // время кругового обхода со своей стороны.
                lastRemoteReport = (RTCP.middleBits(of: report.ntpTimestamp), Date())
                report.reports.forEach(publish)

            case .receiverReport(let report):
                report.reports.forEach(publish)

            case .goodbye:
                onDiagnostic?("собеседник закрыл поток RTCP")

            case .other(let type):
                onDiagnostic?("RTCP: пакет типа \(type) пропущен")
            }
        }
    }

    private func publish(_ block: RTCP.ReportBlock) {
        // Отчёты про чужие источники нас не касаются: в конференции их может
        // приехать несколько, а интересен только наш собственный поток.
        guard block.sourceSSRC == ssrc else { return }

        onRemoteView?(RemoteView(
            fractionLost: block.fractionLost,
            cumulativeLost: block.cumulativeLost,
            jitterMilliseconds: Double(block.jitter) / Double(clockRate) * 1000,
            roundTripTime: block.roundTripTime(now: RTCP.middleBits(of: RTCP.ntpTimestamp())),
            updatedAt: Date()
        ))
    }
}
