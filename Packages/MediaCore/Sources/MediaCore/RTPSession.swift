import Foundation
import Network

// не переводится: отказ уходит в журнал через localizedDescription.

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

    /// Сколько отказов приёма подряд, без единого удавшегося.
    private var consecutiveReceiveFailures = 0

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

            let payload = event.encoded
            let packet = RTPPacket(
                payloadType: eventPayloadType,
                sequenceNumber: sequenceNumber,
                timestamp: timestamp,
                ssrc: ssrc,
                marker: isFirst,
                payload: payload
            )
            sequenceNumber &+= 1
            // Событие — такой же отправленный RTP-пакет, как и кадр звука, и в
            // счёт отправителя оно входит наравне с ним (RFC 3550 §6.4.1: счёт
            // ведётся по всем отправленным пакетам данных). Не считать их значит
            // занизить свой же Sender Report ровно на набранные цифры.
            packetsSent &+= 1
            octetsSent &+= UInt32(payload.count)
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

    /// Сколько отказов приёма подряд терпим, прежде чем перестать слушать.
    ///
    /// Выходить из приёма после первого нельзя. На UDP сокет «подключён», и
    /// каждая ICMP port unreachable приходит сюда ошибкой — а присылает их
    /// перезапускаемый Asterisk на каждый наш кадр, то есть полсотни раз в
    /// секунду. Разговор при этом жив и через пару секунд продолжится; молча
    /// выйти из цикла значит потерять его насовсем, и выглядеть это будет как
    /// «звонок идёт, звука нет» — симптом, который в этом проекте уже трижды
    /// уводил разбор не туда.
    ///
    /// Потолок всё-таки нужен: у соединения в состоянии `.failed` completion
    /// приходит с ошибкой немедленно, и приём без предела превратился бы в
    /// холостой цикл на всю мощность ядра.
    static let maximumConsecutiveReceiveFailures = 16

    private func receiveNext() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.isStopped else { return }

            if let error {
                self.handleReceiveFailure(error)
                return
            }

            // Приём состоялся — значит череда отказов кончилась, и считать её
            // дальше незачем.
            self.consecutiveReceiveFailures = 0

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

            self.receiveNext()
        }
    }

    /// Разбирает отказ приёма и решает, слушать ли дальше.
    ///
    /// Выполняется на `queue`, как и сам приём.
    private func handleReceiveFailure(_ error: NWError) {
        consecutiveReceiveFailures += 1

        // Говорим о первом отказе в череде и о том, на котором сдались.
        // Строка на каждый отказ залила бы журнал одним и тем же текстом
        // полсотни раз в секунду — то есть сделала бы его бесполезным ровно
        // там, где он нужен.
        if consecutiveReceiveFailures == 1 {
            onFailure?("приём RTP: \(error.localizedDescription)")
        }

        guard consecutiveReceiveFailures < Self.maximumConsecutiveReceiveFailures else {
            onFailure?(
                "приём RTP остановлен: \(consecutiveReceiveFailures) отказов подряд"
                    + " (\(error.localizedDescription))"
            )
            return
        }
        receiveNext()
    }
}

// MARK: - Резервирование портов

/// Владение парой локальных портов RTP/RTCP.
///
/// Одного номера недостаточно: между сборкой SDP и ответом на INVITE проходят
/// секунды, а будущие линии M6 готовятся параллельно. Резервация держит оба UDP-
/// сокета связанными до запуска Network.framework и дополнительно не даёт
/// сессиям этого процесса выбрать ту же пару до завершения разговора.
public final class RTPPortReservation: @unchecked Sendable {

    /// Диапазон должен совпадать с `rtp.conf` и публикацией портов лаборатории.
    public static let defaultPortRange: ClosedRange<UInt16> = 16384...16482

    public let rtpPort: UInt16
    public var rtcpPort: UInt16 { rtpPort + 1 }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var claimedPorts = Set<UInt16>()

    private let stateLock = NSLock()
    private var descriptors: [Int32]
    private var isReleased = false

    private init(rtpPort: UInt16, descriptors: [Int32]) {
        self.rtpPort = rtpPort
        self.descriptors = descriptors
    }

    deinit {
        release()
    }

    /// Занимает сразу RTP и следующий за ним RTCP-порт.
    public static func reserve(
        in range: ClosedRange<UInt16> = defaultPortRange
    ) throws -> RTPPortReservation {
        registryLock.lock()
        defer { registryLock.unlock() }

        var candidate = range.lowerBound.isMultiple(of: 2)
            ? range.lowerBound
            : range.lowerBound + 1

        // Пара обязана целиком лечь в диапазон: RTCP живёт на порту RTP плюс
        // один. Условие написано именно так, чтобы это было видно на месте —
        // из `candidate < upperBound` тот же смысл вычитается не сразу, и при
        // следующей правке границы легко получить пару, у которой второй порт
        // уже снаружи. Верхний порт диапазона при этом остаётся неиспользуемым
        // как RTP, и это правильно, а не потеря.
        while candidate + 1 <= range.upperBound {
            if !claimedPorts.contains(candidate),
               let rtp = boundDatagramSocket(port: candidate) {
                if let rtcp = boundDatagramSocket(port: candidate + 1) {
                    claimedPorts.insert(candidate)
                    return RTPPortReservation(
                        rtpPort: candidate,
                        descriptors: [rtp, rtcp]
                    )
                }
                close(rtp)
            }
            candidate += 2
        }
        throw RTPSession.SessionError.noFreePort(range: range)
    }

    /// Освобождает проверочные сокеты непосредственно перед запуском RTP/RTCP.
    ///
    /// Логическое владение парой остаётся за объектом до `release()`, поэтому
    /// другая линия этого процесса не сможет забрать порт в коротком зазоре,
    /// пока Network.framework создаёт рабочие сокеты.
    public func activate() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isReleased else { return }
        descriptors.forEach { close($0) }
        descriptors.removeAll()
    }

    /// Снимает и системную, и внутрипроцессную резервацию.
    public func release() {
        stateLock.lock()
        guard !isReleased else {
            stateLock.unlock()
            return
        }
        isReleased = true
        let heldDescriptors = descriptors
        descriptors.removeAll()
        stateLock.unlock()

        heldDescriptors.forEach { close($0) }
        _ = Self.registryLock.withLock {
            Self.claimedPorts.remove(rtpPort)
        }
    }

    private static func boundDatagramSocket(port: UInt16) -> Int32? {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { return nil }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_ANY

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                bind(descriptor, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }
}

public extension RTPSession {

    static let defaultPortRange = RTPPortReservation.defaultPortRange

    static func reservePortPair(
        in range: ClosedRange<UInt16> = defaultPortRange
    ) throws -> RTPPortReservation {
        try RTPPortReservation.reserve(in: range)
    }
}
