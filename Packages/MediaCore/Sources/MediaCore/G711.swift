/// Кодеки G.711: µ-law и A-law.
///
/// Алгоритм — референсная реализация из ITU-T G.711 (в виде, известном по
/// public-domain `g711.c` от Sun Microsystems). Он логарифмический и работает
/// не над полными 16 битами: µ-law квантует 14-битную сетку, A-law — 13-битную,
/// поэтому в кодировщиках стоят сдвиги `>> 2` и `>> 3`. Это не потеря точности
/// по недосмотру, а часть стандарта.
public enum G711 {

    // Верхние границы сегментов логарифмической шкалы.
    private static let muLawSegmentEnd: [Int32] = [0x3F, 0x7F, 0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF, 0x1FFF]
    private static let aLawSegmentEnd: [Int32] = [0x1F, 0x3F, 0x7F, 0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF]

    private static let muLawBias: Int32 = 0x84
    private static let muLawClip: Int32 = 8159

    /// Байт, которым кодируется тишина. Пригодится, когда надо отправить
    /// комфортный шум или заполнить дырку в джиттер-буфере.
    public static let muLawSilence: UInt8 = 0xFF
    public static let aLawSilence: UInt8 = 0xD5

    private static func segment(of value: Int32, in table: [Int32]) -> Int32 {
        for (index, upperBound) in table.enumerated() where value <= upperBound {
            return Int32(index)
        }
        return Int32(table.count)
    }

    // MARK: - µ-law

    public static func encodeMuLaw(_ sample: Int16) -> UInt8 {
        var value = Int32(sample) >> 2
        let mask: Int32
        if value < 0 {
            value = -value
            mask = 0x7F
        } else {
            mask = 0xFF
        }
        if value > muLawClip { value = muLawClip }
        value += muLawBias >> 2

        let segment = segment(of: value, in: muLawSegmentEnd)
        guard segment < 8 else { return UInt8(0x7F ^ mask) }

        let encoded = (segment << 4) | ((value >> (segment + 1)) & 0x0F)
        return UInt8(encoded ^ mask)
    }

    public static func decodeMuLaw(_ byte: UInt8) -> Int16 {
        let value = Int32(~byte)
        var magnitude = ((value & 0x0F) << 3) + muLawBias
        magnitude <<= (value & 0x70) >> 4
        let sample = (value & 0x80) != 0 ? (muLawBias - magnitude) : (magnitude - muLawBias)
        return Int16(truncatingIfNeeded: sample)
    }

    // MARK: - A-law

    public static func encodeALaw(_ sample: Int16) -> UInt8 {
        var value = Int32(sample) >> 3
        let mask: Int32
        if value >= 0 {
            mask = 0xD5
        } else {
            mask = 0x55
            value = -value - 1
        }

        let segment = segment(of: value, in: aLawSegmentEnd)
        guard segment < 8 else { return UInt8(0x7F ^ mask) }

        var encoded = segment << 4
        // Первые два сегмента линейные, у них шаг квантования одинаковый.
        encoded |= segment < 2 ? ((value >> 1) & 0x0F) : ((value >> segment) & 0x0F)
        return UInt8(encoded ^ mask)
    }

    public static func decodeALaw(_ byte: UInt8) -> Int16 {
        let value = Int32(byte ^ 0x55)
        var magnitude = (value & 0x0F) << 4
        let segment = (value & 0x70) >> 4
        switch segment {
        case 0:
            magnitude += 8
        case 1:
            magnitude += 0x108
        default:
            magnitude += 0x108
            magnitude <<= segment - 1
        }
        return Int16(truncatingIfNeeded: (value & 0x80) != 0 ? magnitude : -magnitude)
    }

    // MARK: - Буферы

    public static func encode(_ samples: [Int16], as codec: AudioCodec) -> [UInt8] {
        switch codec {
        case .pcmu: samples.map(encodeMuLaw)
        case .pcma: samples.map(encodeALaw)
        }
    }

    public static func decode(_ bytes: [UInt8], as codec: AudioCodec) -> [Int16] {
        switch codec {
        case .pcmu: bytes.map(decodeMuLaw)
        case .pcma: bytes.map(decodeALaw)
        }
    }

    public static func silenceByte(for codec: AudioCodec) -> UInt8 {
        switch codec {
        case .pcmu: muLawSilence
        case .pcma: aLawSilence
        }
    }
}
