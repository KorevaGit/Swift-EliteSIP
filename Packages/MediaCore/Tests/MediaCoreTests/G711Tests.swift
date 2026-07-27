import Foundation
import Testing
@testable import MediaCore

@Suite("G.711")
struct G711Tests {

    @Test("Тишина кодируется каноническими байтами")
    func silenceHasStandardEncoding() {
        // 0xFF и 0xD5 — то, чем забивают тишину все реализации G.711.
        // Если здесь разъедется, Asterisk услышит постоянный треск.
        #expect(G711.encodeMuLaw(0) == 0xFF)
        #expect(G711.encodeALaw(0) == 0xD5)
        #expect(G711.encodeMuLaw(0) == G711.silenceByte(for: .pcmu))
        #expect(G711.encodeALaw(0) == G711.silenceByte(for: .pcma))
        #expect(G711.decodeMuLaw(G711.muLawSilence) == 0)
        // В A-law кода точного нуля не существует: 0xD5 и 0x55 — это ±8,
        // ближайшие к нулю уровни шкалы. Проверяем минимальность, не равенство.
        #expect(abs(Int(G711.decodeALaw(G711.aLawSilence))) == 8)
        #expect(abs(Int(G711.decodeALaw(0x55))) == 8)
    }

    @Test("Кодирование устойчиво: повторный проход не смещает значение", arguments: AudioCodec.allCases)
    func encodingIsStable(codec: AudioCodec) {
        // Проверяем decode → encode → decode, а не побайтовое равенство:
        // у µ-law есть два кода нуля (0x7F и 0xFF), и после первого прохода
        // "минус ноль" законно превращается в обычный ноль. Значение при этом
        // не меняется — именно это и важно, чтобы звук не дрейфовал.
        for raw in UInt8.min...UInt8.max {
            let decoded = G711.decode([raw], as: codec)[0]
            let reencoded = G711.encode([decoded], as: codec)[0]
            let again = G711.decode([reencoded], as: codec)[0]
            #expect(again == decoded, "код \(raw) сместился: \(decoded) -> \(again)")
        }
    }

    @Test("Каждый код декодируется в своё значение", arguments: AudioCodec.allCases)
    func decodingIsInjective(codec: AudioCodec) {
        let decoded = (UInt8.min...UInt8.max).map { G711.decode([$0], as: codec)[0] }
        let unique = Set(decoded)
        // 256 кодов на 255 значений: одно значение (ноль) занято дважды.
        #expect(unique.count >= 255, "кодек теряет уровни: уникальных значений \(unique.count)")
    }

    @Test("Знак сохраняется", arguments: AudioCodec.allCases)
    func signIsPreserved(codec: AudioCodec) {
        for magnitude in stride(from: 64, through: 32000, by: 337) {
            let positive = G711.decode(G711.encode([Int16(magnitude)], as: codec), as: codec)[0]
            let negative = G711.decode(G711.encode([Int16(-magnitude)], as: codec), as: codec)[0]
            #expect(positive > 0, "\(magnitude) потерял знак")
            #expect(negative < 0, "-\(magnitude) потерял знак")
        }
    }

    @Test("Монотонность: рост входа не даёт падения выхода", arguments: AudioCodec.allCases)
    func encodingIsMonotonic(codec: AudioCodec) {
        var previous = Int16.min
        for value in stride(from: -32768, through: 32767, by: 97) {
            let decoded = G711.decode(G711.encode([Int16(value)], as: codec), as: codec)[0]
            #expect(decoded >= previous, "провал монотонности на \(value)")
            previous = decoded
        }
    }

    @Test("Отношение сигнал/шум на синусе не хуже 30 дБ", arguments: AudioCodec.allCases)
    func signalToNoiseRatio(codec: AudioCodec) {
        // Практический критерий качества: G.711 даёт около 38 дБ. Порог 30
        // ловит перепутанные сдвиги и сегменты, но не срабатывает на законной
        // логарифмической ошибке квантования.
        let sampleCount = 8000
        let amplitude = 0.8 * Double(Int16.max)
        let original: [Int16] = (0..<sampleCount).map { index in
            let phase = 2 * Double.pi * 1000 * Double(index) / 8000
            return Int16(amplitude * sin(phase))
        }

        let restored = G711.decode(G711.encode(original, as: codec), as: codec)

        var signalEnergy = 0.0
        var noiseEnergy = 0.0
        for (source, result) in zip(original, restored) {
            let clean = Double(source)
            let error = Double(result) - clean
            signalEnergy += clean * clean
            noiseEnergy += error * error
        }

        let snr = 10 * log10(signalEnergy / noiseEnergy)
        #expect(snr > 30, "SNR \(codec.sdpName) = \(String(format: "%.1f", snr)) дБ")
    }

    @Test("Крайние значения не переполняются", arguments: AudioCodec.allCases)
    func extremesDoNotOverflow(codec: AudioCodec) {
        // Int16.min нельзя просто отрицать — это классический источник краха
        // в кодировщиках G.711.
        for sample in [Int16.min, Int16.min + 1, -1, 0, 1, Int16.max - 1, Int16.max] {
            let encoded = G711.encode([sample], as: codec)
            #expect(encoded.count == 1)
            let decoded = G711.decode(encoded, as: codec)[0]
            #expect(decoded != 0 || sample == 0 || abs(Int(sample)) < 8, "потеряли \(sample)")
        }
    }

    @Test("Длина буфера сохраняется")
    func bufferLengthIsPreserved() {
        let samples = [Int16](repeating: 1234, count: 160)
        for codec in AudioCodec.allCases {
            let encoded = G711.encode(samples, as: codec)
            #expect(encoded.count == 160, "20 мс G.711 — это ровно 160 байт")
            #expect(encoded.count == codec.byteCount(forPacketTime: defaultPacketTimeMilliseconds))
            #expect(G711.decode(encoded, as: codec).count == samples.count)
        }
        #expect(G711.encode([], as: .pcmu).isEmpty)
        #expect(G711.decode([], as: .pcma).isEmpty)
    }
}
