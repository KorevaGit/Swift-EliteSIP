import Foundation

/// Пакеты RTCP по RFC 3550: отчёты о качестве в обе стороны.
///
/// Зачем они нужны здесь. Собственная статистика показывает только то, что мы
/// приняли; что происходит с нашим потоком у собеседника — не видно вообще.
/// RTCP отвечает ровно на этот вопрос: в отчёте приёмника приезжают доля
/// потерь, джиттер и задержка кругового обхода, посчитанные той стороной.
/// Практически это разница между «у нас всё хорошо, а клиент жалуется» и
/// «видим, что до клиента не доходит четверть пакетов».
///
/// Разбор и сборка — чистые функции над байтами: сеть тут ни при чём, и всё
/// проверяется тестами.
public enum RTCP {

    /// Типы пакетов, которые нас касаются.
    public enum PacketType: UInt8, Sendable {
        case senderReport = 200
        case receiverReport = 201
        case sourceDescription = 202
        case goodbye = 203
    }

    /// Блок отчёта об одном источнике — сердце RTCP.
    public struct ReportBlock: Sendable, Hashable {
        public var sourceSSRC: UInt32
        /// Доля потерь с прошлого отчёта, 0…1.
        public var fractionLost: Double
        /// Накопленное число потерянных пакетов. Знаковое: дубликаты могут
        /// увести его в минус, и это по стандарту, а не ошибка.
        public var cumulativeLost: Int32
        public var highestSequenceNumber: UInt32
        /// Джиттер в единицах часов RTP.
        public var jitter: UInt32
        /// Средняя часть метки NTP из последнего отчёта отправителя.
        public var lastSenderReport: UInt32
        /// Задержка с момента получения того отчёта, в 1/65536 секунды.
        public var delaySinceLastSenderReport: UInt32

        public init(
            sourceSSRC: UInt32,
            fractionLost: Double,
            cumulativeLost: Int32,
            highestSequenceNumber: UInt32,
            jitter: UInt32,
            lastSenderReport: UInt32,
            delaySinceLastSenderReport: UInt32
        ) {
            self.sourceSSRC = sourceSSRC
            self.fractionLost = fractionLost
            self.cumulativeLost = cumulativeLost
            self.highestSequenceNumber = highestSequenceNumber
            self.jitter = jitter
            self.lastSenderReport = lastSenderReport
            self.delaySinceLastSenderReport = delaySinceLastSenderReport
        }

        /// Задержка кругового обхода, если её можно посчитать.
        ///
        /// Считается по RFC 3550 §6.4.1: из текущего времени вычитается метка
        /// нашего отчёта, которую собеседник вернул, и время, которое отчёт у
        /// него пролежал. Возвращает nil, пока собеседник ещё ни одного нашего
        /// отчёта не видел.
        public func roundTripTime(now: UInt32) -> TimeInterval? {
            guard lastSenderReport != 0 else { return nil }
            let elapsed = now &- lastSenderReport &- delaySinceLastSenderReport
            // Значения в формате 16.16 секунды.
            return TimeInterval(elapsed) / 65536
        }
    }

    /// Отчёт отправителя: что мы (или собеседник) отправили.
    public struct SenderReport: Sendable, Hashable {
        public var ssrc: UInt32
        /// Метка NTP в формате 32.32.
        public var ntpTimestamp: UInt64
        public var rtpTimestamp: UInt32
        public var packetCount: UInt32
        public var octetCount: UInt32
        public var reports: [ReportBlock]

        public init(
            ssrc: UInt32,
            ntpTimestamp: UInt64,
            rtpTimestamp: UInt32,
            packetCount: UInt32,
            octetCount: UInt32,
            reports: [ReportBlock] = []
        ) {
            self.ssrc = ssrc
            self.ntpTimestamp = ntpTimestamp
            self.rtpTimestamp = rtpTimestamp
            self.packetCount = packetCount
            self.octetCount = octetCount
            self.reports = reports
        }
    }

    /// Отчёт приёмника: что мы (или собеседник) приняли.
    public struct ReceiverReport: Sendable, Hashable {
        public var ssrc: UInt32
        public var reports: [ReportBlock]

        public init(ssrc: UInt32, reports: [ReportBlock] = []) {
            self.ssrc = ssrc
            self.reports = reports
        }
    }

    public enum Packet: Sendable, Hashable {
        case senderReport(SenderReport)
        case receiverReport(ReceiverReport)
        case goodbye(ssrc: UInt32)
        /// Разобрать не смогли или он нам неинтересен. Тип сохраняется: по нему
        /// видно, что именно шлёт сервер.
        case other(type: UInt8)
    }

    public enum ParsingError: Error, Sendable, Equatable {
        case tooShort
        case unsupportedVersion(UInt8)
    }

    // MARK: - Сборка

    /// Собирает составной пакет: отчёт плюс описание источника.
    ///
    /// Отдельный SDES обязателен по RFC 3550 §6.1 — приёмник вправе выбросить
    /// отчёт без CNAME. Asterisk именно так и делает, и без SDES статистика на
    /// его стороне остаётся пустой при внешне исправном обмене.
    public static func compound(report: Data, ssrc: UInt32, canonicalName: String) -> Data {
        report + sourceDescription(ssrc: ssrc, canonicalName: canonicalName)
    }

    public static func encode(_ report: SenderReport) -> Data {
        var body = Data()
        body.appendBigEndian(report.ssrc)
        body.appendBigEndian(report.ntpTimestamp)
        body.appendBigEndian(report.rtpTimestamp)
        body.appendBigEndian(report.packetCount)
        body.appendBigEndian(report.octetCount)
        for block in report.reports {
            body.append(encode(block))
        }
        return header(type: .senderReport, count: report.reports.count, bodyLength: body.count) + body
    }

    public static func encode(_ report: ReceiverReport) -> Data {
        var body = Data()
        body.appendBigEndian(report.ssrc)
        for block in report.reports {
            body.append(encode(block))
        }
        return header(type: .receiverReport, count: report.reports.count, bodyLength: body.count) + body
    }

    private static func encode(_ block: ReportBlock) -> Data {
        var data = Data()
        data.appendBigEndian(block.sourceSSRC)
        // Доля потерь — восьмибитная дробь, старший байт слова; в остальных
        // трёх байтах накопленные потери со знаком.
        let fraction = UInt8(min(max(block.fractionLost * 256, 0), 255))
        let cumulative = UInt32(bitPattern: block.cumulativeLost) & 0x00FF_FFFF
        data.appendBigEndian(UInt32(fraction) << 24 | cumulative)
        data.appendBigEndian(block.highestSequenceNumber)
        data.appendBigEndian(block.jitter)
        data.appendBigEndian(block.lastSenderReport)
        data.appendBigEndian(block.delaySinceLastSenderReport)
        return data
    }

    /// Минимальный SDES с одним CNAME.
    private static func sourceDescription(ssrc: UInt32, canonicalName: String) -> Data {
        var chunk = Data()
        chunk.appendBigEndian(ssrc)
        let name = Array(canonicalName.utf8.prefix(255))
        chunk.append(1)                      // CNAME
        chunk.append(UInt8(name.count))
        chunk.append(contentsOf: name)
        chunk.append(0)                      // конец списка элементов

        // Кусок дополняется нулями до границы в четыре байта.
        while chunk.count % 4 != 0 { chunk.append(0) }

        return header(type: .sourceDescription, count: 1, bodyLength: chunk.count) + chunk
    }

    private static func header(type: PacketType, count: Int, bodyLength: Int) -> Data {
        var data = Data()
        // Версия 2, без дополнения, счётчик отчётов в младших пяти битах.
        data.append(0x80 | UInt8(min(count, 31)))
        data.append(type.rawValue)
        // Длина в 32-битных словах, не считая первого. Заголовок — 4 байта.
        data.appendBigEndian(UInt16((bodyLength + 4) / 4 - 1))
        return data
    }

    // MARK: - Разбор

    /// Разбирает составной пакет.
    ///
    /// Именно составной: RTCP почти никогда не приходит по одному пакету, и
    /// разбирать только первый значит терять отчёт, который приехал вторым.
    public static func parse(_ data: Data) throws -> [Packet] {
        var packets: [Packet] = []
        var offset = data.startIndex

        while data.distance(from: offset, to: data.endIndex) >= 4 {
            let first = data[offset]
            guard first >> 6 == 2 else { throw ParsingError.unsupportedVersion(first >> 6) }

            let reportCount = Int(first & 0x1F)
            let type = data[data.index(offset, offsetBy: 1)]
            let words = Int(data.bigEndianUInt16(at: data.index(offset, offsetBy: 2)))
            let length = (words + 1) * 4

            guard data.distance(from: offset, to: data.endIndex) >= length else {
                throw ParsingError.tooShort
            }
            let body = data[data.index(offset, offsetBy: 4)..<data.index(offset, offsetBy: length)]

            switch PacketType(rawValue: type) {
            case .senderReport:
                packets.append(.senderReport(try parseSenderReport(body, reportCount: reportCount)))
            case .receiverReport:
                packets.append(.receiverReport(try parseReceiverReport(body, reportCount: reportCount)))
            case .goodbye:
                guard body.count >= 4 else { throw ParsingError.tooShort }
                packets.append(.goodbye(ssrc: body.bigEndianUInt32(at: body.startIndex)))
            default:
                packets.append(.other(type: type))
            }

            offset = data.index(offset, offsetBy: length)
        }

        return packets
    }

    private static func parseSenderReport(_ body: Data, reportCount: Int) throws -> SenderReport {
        guard body.count >= 20 else { throw ParsingError.tooShort }
        var cursor = body.startIndex

        let ssrc = body.bigEndianUInt32(at: cursor)
        cursor = body.index(cursor, offsetBy: 4)
        let ntp = body.bigEndianUInt64(at: cursor)
        cursor = body.index(cursor, offsetBy: 8)
        let rtp = body.bigEndianUInt32(at: cursor)
        cursor = body.index(cursor, offsetBy: 4)
        let packets = body.bigEndianUInt32(at: cursor)
        cursor = body.index(cursor, offsetBy: 4)
        let octets = body.bigEndianUInt32(at: cursor)
        cursor = body.index(cursor, offsetBy: 4)

        return SenderReport(
            ssrc: ssrc,
            ntpTimestamp: ntp,
            rtpTimestamp: rtp,
            packetCount: packets,
            octetCount: octets,
            reports: parseBlocks(body, from: cursor, count: reportCount)
        )
    }

    private static func parseReceiverReport(_ body: Data, reportCount: Int) throws -> ReceiverReport {
        guard body.count >= 4 else { throw ParsingError.tooShort }
        let ssrc = body.bigEndianUInt32(at: body.startIndex)
        return ReceiverReport(
            ssrc: ssrc,
            reports: parseBlocks(body, from: body.index(body.startIndex, offsetBy: 4), count: reportCount)
        )
    }

    private static func parseBlocks(_ body: Data, from start: Data.Index, count: Int) -> [ReportBlock] {
        var blocks: [ReportBlock] = []
        var cursor = start

        for _ in 0..<count {
            guard body.distance(from: cursor, to: body.endIndex) >= 24 else { break }

            let source = body.bigEndianUInt32(at: cursor)
            let lossWord = body.bigEndianUInt32(at: body.index(cursor, offsetBy: 4))
            // Накопленные потери — 24-битное число со знаком; знак надо
            // растянуть вручную, иначе потеря одного пакета выглядит как
            // шестнадцать миллионов.
            var cumulative = Int32(lossWord & 0x00FF_FFFF)
            if cumulative & 0x0080_0000 != 0 {
                cumulative -= 0x0100_0000
            }

            blocks.append(ReportBlock(
                sourceSSRC: source,
                fractionLost: Double(lossWord >> 24) / 256,
                cumulativeLost: cumulative,
                highestSequenceNumber: body.bigEndianUInt32(at: body.index(cursor, offsetBy: 8)),
                jitter: body.bigEndianUInt32(at: body.index(cursor, offsetBy: 12)),
                lastSenderReport: body.bigEndianUInt32(at: body.index(cursor, offsetBy: 16)),
                delaySinceLastSenderReport: body.bigEndianUInt32(at: body.index(cursor, offsetBy: 20))
            ))
            cursor = body.index(cursor, offsetBy: 24)
        }

        return blocks
    }

    // MARK: - Время

    /// Текущее время в формате NTP: секунды с 1900 года, 32.32.
    public static func ntpTimestamp(for date: Date = Date()) -> UInt64 {
        // Разница между эпохами Unix и NTP — семьдесят лет с семнадцатью
        // високосными днями.
        let secondsFrom1900To1970 = 2_208_988_800.0
        let seconds = date.timeIntervalSince1970 + secondsFrom1900To1970
        let whole = UInt64(seconds)
        let fraction = UInt64((seconds - Double(whole)) * 4_294_967_296)
        return whole << 32 | fraction
    }

    /// Средние 32 бита метки NTP — то, что кладётся в поле «последний отчёт
    /// отправителя» и возвращается собеседником для расчёта задержки.
    public static func middleBits(of ntp: UInt64) -> UInt32 {
        UInt32((ntp >> 16) & 0xFFFF_FFFF)
    }
}

// MARK: - Чтение и запись чисел

extension Data {

    mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) {
            append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    mutating func appendBigEndian(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    func bigEndianUInt16(at index: Index) -> UInt16 {
        UInt16(self[index]) << 8 | UInt16(self[self.index(index, offsetBy: 1)])
    }

    func bigEndianUInt32(at index: Index) -> UInt32 {
        var result: UInt32 = 0
        for offset in 0..<4 {
            result = result << 8 | UInt32(self[self.index(index, offsetBy: offset)])
        }
        return result
    }

    func bigEndianUInt64(at index: Index) -> UInt64 {
        var result: UInt64 = 0
        for offset in 0..<8 {
            result = result << 8 | UInt64(self[self.index(index, offsetBy: offset)])
        }
        return result
    }
}
