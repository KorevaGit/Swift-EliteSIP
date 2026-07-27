import Foundation

/// Пакет RTP по RFC 3550.
///
/// Заголовок фиксированной части — 12 байт:
///
/// ```
///  0                   1                   2                   3
///  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |V=2|P|X|  CC   |M|     PT      |       sequence number         |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                           timestamp                           |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |            synchronization source (SSRC) identifier           |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// ```
public struct RTPPacket: Sendable, Hashable {

    public static let version: UInt8 = 2
    public static let headerByteCount = 12

    public var payloadType: UInt8
    public var sequenceNumber: UInt16
    public var timestamp: UInt32
    public var ssrc: UInt32
    /// Маркер. Для аудио означает первый пакет после тишины, для DTMF —
    /// начало события.
    public var marker: Bool
    public var csrcs: [UInt32]
    public var payload: Data

    public init(
        payloadType: UInt8,
        sequenceNumber: UInt16,
        timestamp: UInt32,
        ssrc: UInt32,
        marker: Bool = false,
        csrcs: [UInt32] = [],
        payload: Data
    ) {
        self.payloadType = payloadType
        self.sequenceNumber = sequenceNumber
        self.timestamp = timestamp
        self.ssrc = ssrc
        self.marker = marker
        self.csrcs = csrcs
        self.payload = payload
    }

    // MARK: - Разбор

    public enum ParseError: Error, Sendable, Equatable {
        case tooShort(byteCount: Int)
        case unsupportedVersion(UInt8)
        case truncatedCSRC
        case truncatedExtension
        case invalidPadding(UInt8)
    }

    public init(parsing data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= Self.headerByteCount else {
            throw ParseError.tooShort(byteCount: bytes.count)
        }

        let version = (bytes[0] & 0b1100_0000) >> 6
        guard version == Self.version else {
            throw ParseError.unsupportedVersion(version)
        }

        let hasPadding = (bytes[0] & 0b0010_0000) != 0
        let hasExtension = (bytes[0] & 0b0001_0000) != 0
        let csrcCount = Int(bytes[0] & 0b0000_1111)

        marker = (bytes[1] & 0b1000_0000) != 0
        payloadType = bytes[1] & 0b0111_1111
        sequenceNumber = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        timestamp = Self.readUInt32(bytes, at: 4)
        ssrc = Self.readUInt32(bytes, at: 8)

        var offset = Self.headerByteCount

        guard bytes.count >= offset + csrcCount * 4 else {
            throw ParseError.truncatedCSRC
        }
        var csrcs: [UInt32] = []
        csrcs.reserveCapacity(csrcCount)
        for _ in 0..<csrcCount {
            csrcs.append(Self.readUInt32(bytes, at: offset))
            offset += 4
        }
        self.csrcs = csrcs

        if hasExtension {
            // Расширение мы не используем, но обязаны его перешагнуть: иначе
            // первые байты полезной нагрузки окажутся мусором в звуке.
            guard bytes.count >= offset + 4 else { throw ParseError.truncatedExtension }
            let words = Int(UInt16(bytes[offset + 2]) << 8 | UInt16(bytes[offset + 3]))
            offset += 4 + words * 4
            guard bytes.count >= offset else { throw ParseError.truncatedExtension }
        }

        var end = bytes.count
        if hasPadding {
            // Последний байт — количество байт дополнения, включая сам себя.
            guard let padding = bytes.last, padding > 0, offset + Int(padding) <= end else {
                throw ParseError.invalidPadding(bytes.last ?? 0)
            }
            end -= Int(padding)
        }

        payload = Data(bytes[offset..<end])
    }

    // MARK: - Сборка

    public func encoded() -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(Self.headerByteCount + csrcs.count * 4 + payload.count)

        // Дополнение не используем: пакеты у нас всегда кратны нужному размеру,
        // а флаг P потребовал бы согласованной длины у принимающей стороны.
        bytes.append((Self.version << 6) | UInt8(csrcs.count & 0x0F))
        bytes.append((marker ? 0b1000_0000 : 0) | (payloadType & 0b0111_1111))
        bytes.append(UInt8(sequenceNumber >> 8))
        bytes.append(UInt8(sequenceNumber & 0xFF))
        Self.append(timestamp, to: &bytes)
        Self.append(ssrc, to: &bytes)
        for csrc in csrcs {
            Self.append(csrc, to: &bytes)
        }

        var data = Data(bytes)
        data.append(payload)
        return data
    }

    // MARK: - Порядок байтов

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }

    private static func append(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }
}

/// Полезная нагрузка события telephone-event по RFC 4733 — четыре байта.
///
/// ```
///  0                   1                   2                   3
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |     event     |E|R| volume    |          duration             |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// ```
public struct TelephoneEventPayload: Sendable, Hashable {

    public static let byteCount = 4

    /// Код события: 0–9 это цифры, 10 — «*», 11 — «#», 12–15 — A–D.
    public var event: UInt8
    /// Конец события. Последние три пакета события обязаны иметь этот флаг.
    public var isEnd: Bool
    /// Громкость в -dBm0, от 0 до 63. Меньше — громче.
    public var volume: UInt8
    /// Длительность в тактах часов кодека (8000 Гц), нарастающая.
    public var duration: UInt16

    public init(event: UInt8, isEnd: Bool = false, volume: UInt8 = 10, duration: UInt16) {
        self.event = event
        self.isEnd = isEnd
        self.volume = min(volume, 63)
        self.duration = duration
    }

    public init?(parsing data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= Self.byteCount else { return nil }
        event = bytes[0]
        isEnd = (bytes[1] & 0b1000_0000) != 0
        volume = bytes[1] & 0b0011_1111
        duration = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
    }

    public var encoded: Data {
        Data([
            event,
            (isEnd ? 0b1000_0000 : 0) | (volume & 0b0011_1111),
            UInt8(duration >> 8),
            UInt8(duration & 0xFF),
        ])
    }

    /// Код события для символа на клавиатуре.
    public static func event(for character: Character) -> UInt8? {
        switch character {
        case "0"..."9": character.wholeNumberValue.map { UInt8($0) }
        case "*": 10
        case "#": 11
        case "A", "a": 12
        case "B", "b": 13
        case "C", "c": 14
        case "D", "d": 15
        default: nil
        }
    }

    public static func character(for event: UInt8) -> Character? {
        switch event {
        case 0...9: Character(String(event))
        case 10: "*"
        case 11: "#"
        case 12: "A"
        case 13: "B"
        case 14: "C"
        case 15: "D"
        default: nil
        }
    }
}
