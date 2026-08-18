import Foundation

/// Кодеки G.711: µ-law и A-law.
///
/// Алгоритм — референсная реализация из ITU-T G.711 (в виде, известном по
/// public-domain `g711.c` от Sun Microsystems). Он логарифмический и работает
/// не над полными 16 битами: µ-law квантует 14-битную сетку, A-law — 13-битную,
/// поэтому в кодировщиках стоят сдвиги `>> 2` и `>> 3`. Это не потеря точности
/// по недосмотру, а часть стандарта.
///
/// Считает кодек по таблицам, а не по формулам: боевой Asterisk отдаёт
/// `(ulaw|alaw|gsm|g726|g722)` и выбирает первый, который умеет сам, поэтому
/// каждый разговор идёт на G.711 — это единственный кодек, чей внутренний цикл
/// выполняется постоянно. Референсный кодировщик на каждый отсчёт линейно ищет
/// сегмент по таблице границ; таблица заменяет поиск одним чтением. Цена —
/// 24 КБ на процесс (см. `Tables`), меньше, чем занимает один кадр захвата на
/// 96 кГц.
///
/// Честный размер выигрыша: замерено в 3,3 раза быстрее (7,7 нс на отсчёт
/// против 2,3 на M-серии, релизная сборка), то есть **сорок микросекунд на
/// секунду разговора**. Само по себе это не стоило бы переписывания — телефон
/// не упирался в кодек и раньше. Переписано ради двух других вещей: кадр
/// перестал ходить через промежуточные массивы (одно выделение памяти на пакет
/// вместо трёх, а выделение на потоке подачи — это потенциальный щелчок), и
/// цикл кодирования перестал ветвиться, то есть стал предсказуемым по времени.
/// Ровный расход важнее среднего там, где опоздание слышно.
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

    // MARK: - Референсные формулы
    //
    // Остаются в коде и остаются доступными: по ним строятся таблицы, и они же
    // служат образцом в тесте. Заменить их таблицами «насовсем» значило бы
    // потерять то, с чем таблицы сверяются, — и первая же опечатка в индексе
    // стала бы невоспроизводимым хрипом в линии.

    static func referenceEncodeMuLaw(_ sample: Int16) -> UInt8 {
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

    static func referenceDecodeMuLaw(_ byte: UInt8) -> Int16 {
        let value = Int32(~byte)
        var magnitude = ((value & 0x0F) << 3) + muLawBias
        magnitude <<= (value & 0x70) >> 4
        let sample = (value & 0x80) != 0 ? (muLawBias - magnitude) : (magnitude - muLawBias)
        return Int16(truncatingIfNeeded: sample)
    }

    static func referenceEncodeALaw(_ sample: Int16) -> UInt8 {
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

    static func referenceDecodeALaw(_ byte: UInt8) -> Int16 {
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

    // MARK: - Таблицы

    /// Готовые таблицы кодирования и декодирования.
    ///
    /// Индексом служит не сам отсчёт, а то, что от него остаётся после сдвига,
    /// с которого начинается референсный кодировщик: µ-law отбрасывает два
    /// младших бита, A-law — три. Поэтому таблицы получаются не по 64 КБ, а по
    /// 16 и 8: обе целиком помещаются в кэш первого уровня, и чтение из них
    /// стоит дешевле, чем ветвление, которое они заменили.
    ///
    /// Сдвиг обязательно арифметический (`Int(sample) >> 2`), а не логический
    /// по битовому образцу: у отрицательных отсчётов это разные числа, и на
    /// логическом сдвиге таблица разъедется ровно на половине шкалы —
    /// собеседник услышит хрип только на громких звуках.
    enum Tables {
        static let muLawEncode: [UInt8] = (0..<16_384).map { index in
            referenceEncodeMuLaw(Int16(clamping: (index - 8_192) << 2))
        }
        static let aLawEncode: [UInt8] = (0..<8_192).map { index in
            referenceEncodeALaw(Int16(clamping: (index - 4_096) << 3))
        }
        static let muLawDecode: [Int16] = (0...255).map { referenceDecodeMuLaw(UInt8($0)) }
        static let aLawDecode: [Int16] = (0...255).map { referenceDecodeALaw(UInt8($0)) }

        /// Смещение индекса: сдвинутый отсчёт лежит в диапазоне со знаком, а
        /// индекс таблицы — нет.
        static let muLawIndexBias = 8_192
        static let aLawIndexBias = 4_096
    }

    // MARK: - Отдельные отсчёты

    public static func encodeMuLaw(_ sample: Int16) -> UInt8 {
        Tables.muLawEncode[(Int(sample) >> 2) + Tables.muLawIndexBias]
    }

    public static func decodeMuLaw(_ byte: UInt8) -> Int16 {
        Tables.muLawDecode[Int(byte)]
    }

    public static func encodeALaw(_ sample: Int16) -> UInt8 {
        Tables.aLawEncode[(Int(sample) >> 3) + Tables.aLawIndexBias]
    }

    public static func decodeALaw(_ byte: UInt8) -> Int16 {
        Tables.aLawDecode[Int(byte)]
    }

    // MARK: - Буферы
    //
    // Пакет живёт двадцать миллисекунд, и на каждый уходит по одному проходу в
    // каждую сторону. Проходы написаны через сырые указатели не ради
    // микросекунд, а чтобы на кадр приходилось ровно одно выделение памяти
    // вместо трёх: раньше это были `map` в массив, копия в `Data` при отправке
    // и обратная копия в массив при разборе. Выделение на потоке подачи — это
    // то, что при неудачном стечении обстоятельств слышно как щелчок.

    /// Кодирует кадр сразу в `Data` — в том виде, в каком он уедет в RTP.
    public static func encode(_ samples: [Int16], as codec: AudioCodec) -> Data {
        let table: [UInt8]
        let shift: Int
        let bias: Int
        switch codec {
        case .pcmu:
            table = Tables.muLawEncode
            shift = 2
            bias = Tables.muLawIndexBias
        case .pcma:
            table = Tables.aLawEncode
            shift = 3
            bias = Tables.aLawIndexBias
        case .g722:
            // Пустота, а не падение. Сюда не приходят: и `AudioFrameEncoder`, и
            // `silencePayload` разводят G.722 отдельной веткой, а прямых
            // вызовов из боевого кода нет. Но проект уже падал ровно здесь —
            // на живом `sipcheck --answer`, где G.722 идёт первым, — и цена
            // ошибки не должна быть падением процесса посреди разговора.
            // Пустой кадр слышен как заминка, и это несравнимо дешевле.
            return Data()
        }

        var encoded = Data(count: samples.count)
        encoded.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
            table.withUnsafeBufferPointer { table in
                samples.withUnsafeBufferPointer { source in
                    for index in 0..<source.count {
                        destination[index] = table[(Int(source[index]) >> shift) + bias]
                    }
                }
            }
        }
        return encoded
    }

    /// Разбирает пришедший кадр в отсчёты.
    public static func decode(_ payload: Data, as codec: AudioCodec) -> [Int16] {
        let table: [Int16]
        switch codec {
        case .pcmu: table = Tables.muLawDecode
        case .pcma: table = Tables.aLawDecode
        // Пустота по той же причине, что и в `encode`: тишина вместо крэша.
        case .g722: return []
        }

        return [Int16](unsafeUninitializedCapacity: payload.count) { destination, initialized in
            table.withUnsafeBufferPointer { table in
                payload.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                    for index in 0..<source.count {
                        destination[index] = table[Int(source[index])]
                    }
                }
            }
            initialized = payload.count
        }
    }

    /// Вариант для тестов и разборов, где кадр удобнее держать массивом.
    /// Перегрузка различается типом аргумента, а не типом возврата: разойтись
    /// по возвращаемому типу — верный способ получить неоднозначность на первом
    /// же `encode(...)[0]`.
    public static func decode(_ bytes: [UInt8], as codec: AudioCodec) -> [Int16] {
        decode(Data(bytes), as: codec)
    }

    public static func silenceByte(for codec: AudioCodec) -> UInt8 {
        switch codec {
        case .pcmu: muLawSilence
        case .pcma: aLawSilence
        // У G.722 постоянного байта тишины нет — это ADPCM с состоянием, и
        // нули дают щелчки, а не тишину. Правильный путь — `silencePayload`,
        // который кодирует нули честным кодером. Здесь остаётся байт G.711
        // как заведомо безвредная заглушка: заявлением о том, что у G.722
        // тишина такая, он не является, и звук через него не идёт.
        case .g722: muLawSilence
        }
    }
}
