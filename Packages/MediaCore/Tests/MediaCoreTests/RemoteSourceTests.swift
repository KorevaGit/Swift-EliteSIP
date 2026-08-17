import Foundation
import Testing

@testable import MediaCore

/// Кого сессия слушает на своём порту.
///
/// Две ошибки, между которыми проходит граница, стоят разного, и обе дорого.
/// Принимать всех — значит отдать оператору чужой голос вперемешку с
/// собеседником. Не принимать никого, кроме первого, — значит однажды замолчать
/// навсегда: Asterisk меняет SSRC на смене моста, то есть ровно после перевода.
@Suite("Источник потока")
struct RemoteSourceTests {

    // MARK: - Решение

    @Test("Первый пакет задаёт источник")
    func firstPacketSetsSource() {
        var filter = RemoteSourceFilter()
        #expect(filter.accepted == nil)
        #expect(filter.admit(ssrc: 0x1111_1111) == .known)
        #expect(filter.accepted == 0x1111_1111)
    }

    @Test("Одиночный чужой пакет отбрасывается")
    func strayPacketIsDropped() {
        var filter = RemoteSourceFilter()
        _ = filter.admit(ssrc: 0x1111_1111)

        #expect(filter.admit(ssrc: 0xDEAD_BEEF) == .foreign)
        #expect(filter.accepted == 0x1111_1111, "собеседник не сменился от одного чужого пакета")
    }

    @Test("Настойчивый источник признаётся своим")
    func persistentSourceIsAdopted() {
        var filter = RemoteSourceFilter()
        _ = filter.admit(ssrc: 0x1111_1111)

        // Первые четыре — ещё не повод.
        for _ in 0..<(RemoteSourceFilter.adoptionRun - 1) {
            #expect(filter.admit(ssrc: 0x2222_2222) == .foreign)
        }
        #expect(filter.admit(ssrc: 0x2222_2222) == .adopted)
        #expect(filter.accepted == 0x2222_2222)

        // Дальше он обычный, а не «только что признанный»: буфер чистится один
        // раз на смену, а не на каждый пакет после неё.
        #expect(filter.admit(ssrc: 0x2222_2222) == .known)
    }

    @Test("Живой собеседник не даёт себя вытеснить")
    func aliveSourceResetsTheCandidate() {
        var filter = RemoteSourceFilter()
        _ = filter.admit(ssrc: 0x1111_1111)

        // Чужой поток идёт вперемешку с настоящим. Без обнуления счёта
        // кандидата он рано или поздно накопил бы свои пять пакетов и забрал
        // разговор себе — при живом и говорящем собеседнике.
        for _ in 0..<20 {
            #expect(filter.admit(ssrc: 0x2222_2222) == .foreign)
            #expect(filter.admit(ssrc: 0x1111_1111) == .known)
        }
        #expect(filter.accepted == 0x1111_1111)
    }

    @Test("Два чужих источника не складываются в один")
    func candidatesDoNotAccumulate() {
        var filter = RemoteSourceFilter()
        _ = filter.admit(ssrc: 0x1111_1111)

        // Счёт ведётся одному кандидату, а не «всем непонятным»: иначе два
        // разных чужих потока вместе набрали бы порог, которого ни один из них
        // сам по себе не набрал.
        for _ in 0..<10 {
            #expect(filter.admit(ssrc: 0x2222_2222) == .foreign)
            #expect(filter.admit(ssrc: 0x3333_3333) == .foreign)
        }
        #expect(filter.accepted == 0x1111_1111)
    }

    // MARK: - Живой поток

    @Test("Чужой поток не попадает в буфер, а сменившийся — попадает")
    func sessionFiltersIncomingBySource() throws {
        let sourcePort: UInt16 = 40310
        let reservation = try RTPSession.reservePortPair()
        defer { reservation.release() }

        let session = try MediaSession(
            negotiated: NegotiatedMedia(
                codec: .pcmu,
                payloadType: 0,
                remoteAddress: "127.0.0.1",
                remotePort: sourcePort
            ),
            reservation: reservation
        )
        defer { session.stop() }

        // Звуковую карту не трогаем: разрешения на микрофон в сборочной машине
        // никто не выдаст, а проверяется здесь приём, а не звук.
        session.startWithoutAudio()

        var sequence: UInt16 = 1
        func send(ssrc: UInt32, count: Int = 1) throws {
            for _ in 0..<count {
                try Self.send(
                    packet(sequence: sequence, ssrc: ssrc).encoded(),
                    toLocalPort: session.localPort,
                    fromLocalPort: sourcePort
                )
                sequence &+= 1
                // Такт настоящего разговора. Заодно приёму есть когда
                // разобрать пакет: очередь у сессии своя.
                usleep(20_000)
            }
            usleep(150_000)
        }

        // Сокет поднимается не мгновенно: резервация только что отпустила
        // проверочный сокет, а Network.framework ещё связывает свой. Пакет,
        // отправленный в этот зазор, ядру отдать некому — и «собеседником»
        // станет первый же чужой SSRC, пришедший позже. Поэтому источник
        // задаётся не одним пакетом на удачу, а до первого принятого.
        var attempts = 0
        while session.statistics.received == 0, attempts < 20 {
            try send(ssrc: 0x1111_1111)
            attempts += 1
        }
        let baseline = session.statistics.received
        #expect(baseline > 0, "поток RTP не поднялся — проверять нечего")

        try send(ssrc: 0xDEAD_BEEF, count: RemoteSourceFilter.adoptionRun - 1)
        #expect(session.statistics.received == baseline, "чужой поток до буфера не доходит")

        try send(ssrc: 0x1111_1111)
        #expect(session.statistics.received == baseline + 1, "собеседника слышно по-прежнему")

        // А теперь прежний источник замолчал, и новый идёт подряд — так
        // выглядит смена моста на стороне Asterisk.
        try send(ssrc: 0x2222_2222, count: RemoteSourceFilter.adoptionRun)
        #expect(
            session.statistics.received == baseline + 2,
            "признаётся только тот пакет, на котором источник сменился"
        )

        try send(ssrc: 0x2222_2222)
        #expect(session.statistics.received == baseline + 3, "дальше новый источник — обычный")
    }

    // MARK: - Оснастка

    private func packet(sequence: UInt16, ssrc: UInt32) -> RTPPacket {
        RTPPacket(
            payloadType: 0,
            sequenceNumber: sequence,
            timestamp: UInt32(sequence) &* 160,
            ssrc: ssrc,
            payload: Data(repeating: G711.muLawSilence, count: 160)
        )
    }

    /// Отправляет датаграмму на локальный порт с заданного локального порта.
    ///
    /// Исходный порт задаётся не для красоты: сокет RTP «подключён» к адресу
    /// собеседника, и датаграмму с другого порта ядро до нас не донесёт — то
    /// есть проверялся бы не фильтр, а сетевой стек.
    private static func send(_ data: Data, toLocalPort port: UInt16, fromLocalPort source: UInt16) throws {
        let handle = socket(AF_INET, SOCK_DGRAM, 0)
        guard handle >= 0 else { return }
        defer { close(handle) }

        var from = sockaddr_in()
        from.sin_family = sa_family_t(AF_INET)
        from.sin_port = source.bigEndian
        from.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        var destination = sockaddr_in()
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = port.bigEndian
        destination.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &destination) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(
                        handle,
                        bytes.baseAddress,
                        data.count,
                        0,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }
    }
}
