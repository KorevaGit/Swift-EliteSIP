import Compat
import Darwin
import Foundation

// не переводится: отказы стука — журнал.

/// Стук по портам перед регистрацией.
///
/// Что это такое и почему не VPN — в [docs/remote-access.md](../../../../docs/remote-access.md).
/// Коротко: шлюз заказчика (MikroTik) держит порты закрытыми и открывает их
/// адресу, от которого пришла условленная последовательность ICMP-пакетов
/// определённой длины. До сих пор её отправлял shell-скрипт, который сотрудник
/// запускал руками один раз за смену. Здесь то же самое делает клиент — вовремя,
/// повторно и с проверяемым результатом.
///
/// **Это механизм связности, а не защиты.** Стук решает, кого пускают, и ничего
/// не говорит о том, кто может прочитать: SIP и RTP как шли открытым UDP, так и
/// идут. Считать эту функцию закрытием риска M2d нельзя, и в журнале она поэтому
/// называется стуком, а не «защищённым подключением».
public actor PortKnocker: SIPPathOpener {

    public typealias Log = @Sendable (SIPLogLevel, String) -> Void

    private let serverHost: String
    private let sequence: PortKnockSequence
    private let log: Log

    private var throttle: PortKnockThrottle

    /// Идентификатор эха. При `SOCK_DGRAM` ядро подставляет своё значение, но
    /// заполнить поле всё равно надо — пакет обязан быть корректным ICMP.
    private let identifier = UInt16.random(in: 0...UInt16.max)
    private var nextSequenceNumber: UInt16 = 0

    /// Отдельная очередь под блокирующие вызовы: `getaddrinfo` умеет думать
    /// секундами, и делать это на кооперативном пуле Swift Concurrency нельзя —
    /// там ограниченное число потоков, и один заблокированный отнимает их у
    /// звука и у транзакций.
    private static let queue = DispatchQueue(label: "com.elitesip.portknock")

    /// Отказ сокета, о котором уже сказали в журнал. Повторять «не удалось
    /// создать сокет» каждые десять минут бессмысленно: если ICMP запрещён, он
    /// запрещён навсегда, а журнал нужен читаемым.
    private var reportedSocketFailure = false

    public init(
        serverHost: String,
        sequence: PortKnockSequence = .production,
        log: @escaping Log
    ) {
        self.serverHost = serverHost
        self.sequence = sequence
        self.log = log
        self.throttle = PortKnockThrottle(
            minimumInterval: .seconds(sequence.repeatIntervalSeconds)
        )
    }

    /// Создаёт стучащего, только если стучать надо.
    ///
    /// `nil` для офисного рабочего места — это и есть требование «стучать,
    /// если сотрудник работает не во внутренней сети». Ветка живёт в одном
    /// месте, а не расползается проверками по коду регистрации. Откуда
    /// работают, берётся из профиля; `.automatic` оставляет решение адресу.
    public static func forServer(
        _ serverHost: String,
        site: SIPProfileSite = .automatic,
        sequence: PortKnockSequence = .production,
        log: @escaping Log
    ) -> PortKnocker? {
        guard PortKnockPolicy.needsKnocking(serverHost: serverHost, site: site) else { return nil }
        guard !sequence.isEmpty else { return nil }
        return PortKnocker(serverHost: serverHost, sequence: sequence, log: log)
    }

    /// Сеть сменилась — прошлый стук больше ничего не значит.
    public func invalidate() {
        throttle.invalidate()
    }

    public func openPath(reason: SIPPathOpenReason) async {
        let now = Date()
        guard throttle.shouldKnock(reason: reason, now: now) else { return }
        // Отметка ставится до отправки, а не после: иначе повтор регистрации,
        // пришедший в середине семисекундной последовательности, начал бы
        // вторую поверх первой и перемешал порядок пакетов.
        throttle.recordKnock(at: now)

        log(.debug, "стук: \(sequence.packetCount) пакетов, повод \(reason)")

        var sent = 0
        for step in sequence.steps {
            let host = step.resolvedHost(server: serverHost)
            let address: String
            do {
                address = try await resolve(host)
            } catch {
                log(.debug, "стук: адрес \(host) не разрешён (\(error))")
                continue
            }

            for _ in 0..<max(0, step.count) {
                if sent > 0 {
                    do {
                        try await Task.sleep(.seconds(sequence.spacingSeconds))
                    } catch {
                        return
                    }
                }
                do {
                    try await send(to: address, payloadBytes: step.payloadBytes)
                    sent += 1
                } catch {
                    report(error)
                    return
                }
            }
        }

        // Ответы не ждём и не проверяем: правило на шлюзе срабатывает на
        // исходящий пакет, а эхо-ответ может быть и запрещён. Единственная
        // настоящая проверка успеха — прошедший следом REGISTER, и её делает
        // регистрация, а не стук. Именно этим он отличается от скрипта, который
        // печатал «Successfully connected!» безусловно.
        if sent == sequence.packetCount {
            log(.debug, "стук отправлен")
        } else {
            log(.debug, "стук отправлен частично: \(sent) из \(sequence.packetCount)")
        }
    }

    private func report(_ error: Error) {
        guard !reportedSocketFailure else { return }
        reportedSocketFailure = true
        log(.warning, "стук не отправлен: \(error)")
    }

    // MARK: - Блокирующая часть

    private func resolve(_ host: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                continuation.resume(with: Result { try ICMPEcho.resolveIPv4(host) })
            }
        }
    }

    private func send(to address: String, payloadBytes: Int) async throws {
        nextSequenceNumber &+= 1
        let sequenceNumber = nextSequenceNumber
        let identifier = identifier
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                continuation.resume(
                    with: Result {
                        try ICMPEcho.send(
                            toIPv4: address,
                            payloadBytes: payloadBytes,
                            identifier: identifier,
                            sequenceNumber: sequenceNumber
                        )
                    }
                )
            }
        }
    }
}

/// Отправка ICMP echo request. Ровно то, что делает `ping -c 1 -s N`.
///
/// Через `SOCK_DGRAM`, а не `SOCK_RAW`: Darwin разрешает такой сокет без
/// привилегий (на этом построен апловский SimplePing), и приложению не нужен ни
/// root, ни setuid. Ядро само подставляет идентификатор и пересчитывает
/// контрольную сумму, но пакет мы собираем целиком и корректно — полагаться на
/// правку ядра там, где важен каждый байт длины, не стоит.
enum ICMPEcho {

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func resolveIPv4(_ host: String) throws -> String {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else {
            throw Failure(description: String(cString: gai_strerror(status)))
        }
        defer { freeaddrinfo(result) }

        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let converted = first.pointee.ai_addr.withMemoryRebound(
            to: sockaddr_in.self, capacity: 1
        ) { pointer -> String? in
            var address = pointer.pointee.sin_addr
            guard inet_ntop(AF_INET, &address, &text, socklen_t(INET_ADDRSTRLEN)) != nil else {
                return nil
            }
            return String(cString: text)
        }
        guard let converted else {
            throw Failure(description: "адрес не преобразуется в текст")
        }
        return converted
    }

    static func send(
        toIPv4 address: String,
        payloadBytes: Int,
        identifier: UInt16,
        sequenceNumber: UInt16
    ) throws {
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = 0
        guard inet_pton(AF_INET, address, &destination.sin_addr) == 1 else {
            throw Failure(description: "неверный адрес \(address)")
        }

        let handle = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard handle >= 0 else {
            throw Failure(description: "сокет ICMP недоступен: \(errorText())")
        }
        defer { close(handle) }

        let packet = makePacket(
            payloadBytes: payloadBytes,
            identifier: identifier,
            sequenceNumber: sequenceNumber
        )

        let written = packet.withUnsafeBytes { buffer -> Int in
            withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    sendto(
                        handle,
                        buffer.baseAddress,
                        buffer.count,
                        0,
                        address,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }
        guard written == packet.count else {
            throw Failure(description: "отправка не удалась: \(errorText())")
        }
    }

    /// Восьмибайтовый заголовок эха плюс `payloadBytes` данных.
    ///
    /// Заполнение данных повторяет `ping`: байт равен своему номеру по модулю
    /// 256. Содержимое правилу на шлюзе безразлично — оно смотрит на длину, —
    /// но пакет, неотличимый от привычного шлюзу, дешевле объяснять, чем пакет
    /// из нулей.
    static func makePacket(
        payloadBytes: Int,
        identifier: UInt16,
        sequenceNumber: UInt16
    ) -> [UInt8] {
        let payloadCount = max(0, payloadBytes)
        var packet = [UInt8](repeating: 0, count: 8 + payloadCount)
        packet[0] = 8  // echo request
        packet[1] = 0  // code
        packet[2] = 0  // контрольная сумма считается по нулевому полю
        packet[3] = 0
        packet[4] = UInt8(truncatingIfNeeded: identifier >> 8)
        packet[5] = UInt8(truncatingIfNeeded: identifier)
        packet[6] = UInt8(truncatingIfNeeded: sequenceNumber >> 8)
        packet[7] = UInt8(truncatingIfNeeded: sequenceNumber)
        for index in 0..<payloadCount {
            packet[8 + index] = UInt8(truncatingIfNeeded: index)
        }

        let sum = checksum(packet)
        packet[2] = UInt8(truncatingIfNeeded: sum >> 8)
        packet[3] = UInt8(truncatingIfNeeded: sum)
        return packet
    }

    /// Контрольная сумма интернета по RFC 1071: сумма 16-битных слов в обратном
    /// коде, инвертированная.
    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count {
            sum += UInt32(bytes[index]) << 8
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return ~UInt16(truncatingIfNeeded: sum)
    }

    private static func errorText() -> String {
        String(cString: strerror(errno))
    }
}
