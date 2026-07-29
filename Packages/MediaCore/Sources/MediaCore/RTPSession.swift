import Foundation
import Network

/// Медиа-поток одного разговора: приём и отправка RTP по UDP.
///
/// Сокет один и тот же на приём и на отправку — это симметричный RTP, и он не
/// прихоть: Asterisk у нас настроен с `nat=force_rport,comedia`, то есть шлёт
/// медиа туда, откуда его получил. Слушать на одном порту, а отправлять с
/// другого — надёжный способ получить звук в одну сторону.
public final class RTPSession: @unchecked Sendable {

    public struct Configuration: Sendable {
        public var codec: AudioCodec
        public var payloadType: UInt8
        public var packetTimeMilliseconds: Int
        public var telephoneEventPayloadType: UInt8?
        public var security: MediaSecurity

        public init(
            codec: AudioCodec = .pcmu,
            payloadType: UInt8 = 0,
            packetTimeMilliseconds: Int = defaultPacketTimeMilliseconds,
            telephoneEventPayloadType: UInt8? = TelephoneEvent.defaultPayloadType,
            security: MediaSecurity = .none
        ) {
            self.codec = codec
            self.payloadType = payloadType
            self.packetTimeMilliseconds = packetTimeMilliseconds
            self.telephoneEventPayloadType = telephoneEventPayloadType
            self.security = security
        }

        public init(negotiated: NegotiatedMedia) {
            self.init(
                codec: negotiated.codec,
                payloadType: negotiated.payloadType,
                packetTimeMilliseconds: negotiated.packetTimeMilliseconds,
                telephoneEventPayloadType: negotiated.telephoneEventPayloadType,
                security: negotiated.security
            )
        }

        /// На сколько растёт метка времени за пакет.
        ///
        /// Названо через метку времени, а не через отсчёты, намеренно: у G.722
        /// это 160 при 320 отсчётах звука в том же пакете, и всякий, кто
        /// прочитает здесь «отсчёты», рано или поздно подставит не то число.
        var timestampIncrement: UInt32 {
            codec.timestampIncrement(forPacketTime: packetTimeMilliseconds)
        }
    }

    public enum SessionError: Error, Sendable, LocalizedError {
        case noFreePort(range: ClosedRange<UInt16>)
        case notStarted

        public var errorDescription: String? {
            switch self {
            case .noFreePort(let range):
                "Не удалось занять порт для RTP в диапазоне \(range.lowerBound)–\(range.upperBound)."
            case .notStarted:
                "Медиа-сессия не запущена."
            }
        }
    }

    /// Пришедший пакет. Вызывается на очереди сессии — не блокировать.
    public var onReceivedPacket: (@Sendable (RTPPacket) -> Void)?
    public var onFailure: (@Sendable (String) -> Void)?

    public let localPort: UInt16
    private let configuration: Configuration
    private let queue = DispatchQueue(label: "com.elite.EliteSIP.rtp")
    private let connection: NWConnection
    private let outboundSRTP: SRTPContext?
    private let inboundSRTP: SRTPContext?

    /// Состояние отправителя. Трогается только на `queue`.
    private var sequenceNumber: UInt16
    private var timestamp: UInt32
    private let ssrc: UInt32
    /// Первый пакет разговора помечается маркером — так принято, и по нему
    /// принимающая сторона понимает начало речи после тишины.
    private var needsMarker = true
    private var isStopped = false

    /// Сигналит, когда сокет действительно закрыт и порт свободен.
    private let released = DispatchSemaphore(value: 0)

    /// Счётчики для отчётов RTCP. Растут на той же очереди, что и отправка.
    private var packetsSent: UInt32 = 0
    private var octetsSent: UInt32 = 0

    public init(
        configuration: Configuration,
        localPort: UInt16,
        remoteHost: String,
        remotePort: UInt16
    ) throws {
        self.configuration = configuration
        self.localPort = localPort

        switch configuration.security {
        case .none:
            outboundSRTP = nil
            inboundSRTP = nil
        case .sdes(let local, let remote):
            outboundSRTP = try SRTPContext(masterKey: local)
            inboundSRTP = try SRTPContext(masterKey: remote)
        }

        // Начальные значения случайны по RFC 3550 §5.1: предсказуемые номера
        // упрощают подмешивание чужого звука в поток.
        var generator = SystemRandomNumberGenerator()
        sequenceNumber = UInt16.random(in: 0...UInt16.max, using: &generator)
        timestamp = UInt32.random(in: 0...UInt32.max, using: &generator)
        ssrc = UInt32.random(in: 1...UInt32.max, using: &generator)

        let parameters = NWParameters.udp
        parameters.prohibitedInterfaceTypes = []
        // Привязка к конкретному локальному порту — то, что делает RTP
        // симметричным: ответный поток придёт на этот же сокет.
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
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed(let error) = state {
                self.onFailure?(error.localizedDescription)
            }
        }
        connection.start(queue: queue)
        receiveNext()
    }

    /// Закрывает поток и дожидается, пока порт действительно освободится.
    ///
    /// Ждать приходится ради пересогласования: при удержании собеседник может
    /// вернуться с другого адреса, и тогда поток пересобирается на том же
    /// локальном порту. `cancel()` асинхронный, и без ожидания новый сокет
    /// встаёт на ещё занятый порт — звонок при этом продолжается, а звука нет.
    public func stop(waitingForReleaseUpTo timeout: DispatchTimeInterval = .milliseconds(500)) {
        let started: Bool = queue.sync {
            guard !isStopped else { return false }
            isStopped = true
            connection.stateUpdateHandler = { [weak self] state in
                if case .cancelled = state { self?.released.signal() }
            }
            connection.cancel()
            return true
        }
        guard started else { return }
        _ = released.wait(timeout: .now() + timeout)
    }

    // MARK: - Отправка

    /// Отправляет кадр звука. Номер и метка времени наращиваются сами.
    public func send(encodedFrame payload: Data) {
        queue.async { [self] in
            guard !isStopped else { return }

            let packet = RTPPacket(
                payloadType: configuration.payloadType,
                sequenceNumber: sequenceNumber,
                timestamp: timestamp,
                ssrc: ssrc,
                marker: needsMarker,
                payload: payload
            )
            needsMarker = false
            sequenceNumber &+= 1
            timestamp &+= configuration.timestampIncrement
            packetsSent &+= 1
            // По RFC 3550 считается только полезная нагрузка, без заголовков.
            octetsSent &+= UInt32(payload.count)

            do {
                let data = try outboundSRTP?.protect(packet) ?? packet.encoded()
                connection.send(content: data, completion: .idempotent)
            } catch {
                onFailure?(error.localizedDescription)
            }
        }
    }

    /// Отправляет пакет события DTMF (RFC 4733).
    ///
    /// Метка времени НЕ наращивается в течение всего события: все пакеты одного
    /// нажатия несут время его начала, а растёт только поле duration. Если
    /// наращивать timestamp, приёмник услышит серию отдельных коротких тонов
    /// вместо одного длинного.
    public func send(event: TelephoneEventPayload, isFirst: Bool) {
        guard let eventPayloadType = configuration.telephoneEventPayloadType else { return }

        queue.async { [self] in
            guard !isStopped else { return }

            let packet = RTPPacket(
                payloadType: eventPayloadType,
                sequenceNumber: sequenceNumber,
                timestamp: timestamp,
                ssrc: ssrc,
                marker: isFirst,
                payload: event.encoded
            )
            sequenceNumber &+= 1
            do {
                let data = try outboundSRTP?.protect(packet) ?? packet.encoded()
                connection.send(content: data, completion: .idempotent)
            } catch {
                onFailure?(error.localizedDescription)
            }
        }
    }

    /// Завершает событие DTMF и возвращает поток к звуку.
    ///
    /// Метка времени сдвигается на всю длительность тона, а не на один пакет:
    /// внутри события она не росла, но время шло, и без этого сдвига весь
    /// остаток разговора уедет назад относительно часов отправителя.
    public func finishEvent(advancingTimestampBy ticks: UInt32? = nil) {
        queue.async { [self] in
            timestamp &+= ticks ?? configuration.timestampIncrement
            needsMarker = true
        }
    }

    /// Наш SSRC. Отчёты RTCP подписываются им же.
    public var synchronizationSource: UInt32 { ssrc }

    /// Поток защищён SRTP.
    public var isSecured: Bool { outboundSRTP != nil }

    /// Что мы отправили — для отчётов RTCP.
    ///
    /// Читается синхронно на очереди сессии: счётчики растут там же, и
    /// отдавать их из-под чужого потока значило бы читать рваные значения.
    public var sendStatistics: (packets: UInt32, octets: UInt32, timestamp: UInt32, ssrc: UInt32) {
        queue.sync { (packetsSent, octetsSent, timestamp, ssrc) }
    }

    // MARK: - Приём

    private func receiveNext() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }

            if let error {
                self.onFailure?(error.localizedDescription)
                return
            }

            if let data, !data.isEmpty {
                // Битый или чужой пакет молча пропускаем: на открытый UDP-порт
                // прилетает что угодно, и рвать разговор из-за этого нельзя.
                let packet = if let inboundSRTP {
                    try? inboundSRTP.unprotect(data)
                } else {
                    try? RTPPacket(parsing: data)
                }
                if let packet {
                    self.onReceivedPacket?(packet)
                }
            }

            guard !self.isStopped else { return }
            self.receiveNext()
        }
    }
}

// MARK: - Выбор порта

public extension RTPSession {

    /// Диапазон портов должен совпадать с `rtp.conf` на сервере и с публикацией
    /// портов в docker-compose лаборатории.
    static let defaultPortRange: ClosedRange<UInt16> = 16384...16482

    /// Находит свободный чётный порт.
    ///
    /// Чётный не по эстетике: по RFC 3550 §11 за RTP-портом следует RTCP на
    /// порт+1, и нечётный порт ломает это соглашение.
    static func reserveEvenPort(in range: ClosedRange<UInt16> = defaultPortRange) throws -> UInt16 {
        var candidate = range.lowerBound.isMultiple(of: 2) ? range.lowerBound : range.lowerBound + 1

        while candidate < range.upperBound {
            if isPortAvailable(candidate) {
                return candidate
            }
            candidate += 2
        }
        throw SessionError.noFreePort(range: range)
    }

    private static func isPortAvailable(_ port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_ANY

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                bind(descriptor, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
