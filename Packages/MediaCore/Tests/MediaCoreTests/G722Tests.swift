import Foundation
import Testing
@testable import MediaCore

/// G.722 проверить сложнее, чем G.711: он с состоянием и с потерями, поэтому
/// «раскодировалось в то же самое» здесь не работает в принципе. Проверяется то,
/// что имеет смысл: скорость потока, отношение сигнал/шум, полоса — и главное,
/// ради чего он взят, — что верхняя половина полосы вообще доезжает.
@Suite("G.722")
struct G722Tests {

    /// Синус на 16 кГц.
    private func tone(_ frequency: Double, seconds: Double = 0.5, amplitude: Double = 0.4) -> [Int16] {
        let count = Int(16000 * seconds)
        return (0..<count).map { index in
            Int16(amplitude * 32000 * sin(2 * .pi * frequency * Double(index) / 16000))
        }
    }

    private func roundTrip(_ samples: [Int16]) -> [Int16] {
        var encoder = G722.Encoder()
        var decoder = G722.Decoder()
        return decoder.decode(encoder.encode(samples))
    }

    /// Уровень на частоте, в долях полной шкалы.
    private func level(_ samples: [Int16], at frequency: Double) -> Double {
        let values = samples.map { Double($0) / 32768.0 }
        let omega = 2 * Double.pi * frequency / 16000
        let coefficient = 2 * cos(omega)
        var previous = 0.0
        var beforePrevious = 0.0
        for value in values {
            let current = value + coefficient * previous - beforePrevious
            beforePrevious = previous
            previous = current
        }
        let real = previous - beforePrevious * cos(omega)
        let imaginary = beforePrevious * sin(omega)
        return 2 * sqrt(real * real + imaginary * imaginary) / Double(values.count)
    }

    @Test("Байт на пару отсчётов — то есть те же 64 кбит/с")
    func producesOneBytePerSamplePair() {
        var encoder = G722.Encoder()
        let encoded = encoder.encode(tone(1000, seconds: 0.02))

        #expect(encoded.count == 160, "кадр 20 мс: 320 отсчётов на 16 кГц → 160 байт")
        #expect(AudioCodec.g722.byteCount(forPacketTime: 20) == 160)
        #expect(AudioCodec.g722.sampleCount(forPacketTime: 20) == 320)
    }

    @Test("Метка времени растёт вдвое медленнее числа отсчётов")
    func timestampIncrementFollowsRFC3551() {
        // Ошибка RFC 1890, оставленная в RFC 3551 §4.5.2: у G.722 частота часов
        // объявлена 8000 при выборке 16 000. Кто нарастит метку на 320, получит
        // от собеседника либо ускоренную речь, либо тишину.
        #expect(AudioCodec.g722.timestampIncrement(forPacketTime: 20) == 160)
        #expect(AudioCodec.g722.rtpClockRate == 8000)
        #expect(AudioCodec.g722.sampleRate == 16000)
        #expect(AudioCodec.g722.isWideband)
    }

    @Test("Тон восстанавливается на своей частоте и своём уровне", arguments: [300.0, 1000, 2000, 3000])
    func preservesLowBand(frequency: Double) {
        let original = tone(frequency)
        // Начало отбрасывается: квадратурный фильтр и предсказатель на первых
        // отсчётах ещё не установились.
        let restored = Array(roundTrip(original).dropFirst(1000))

        let expected = level(Array(original.dropFirst(1000)), at: frequency)
        let actual = level(restored, at: frequency)
        let deviation = 20 * log10(actual / expected)

        #expect(abs(deviation) < 1.5, "на \(Int(frequency)) Гц уровень уехал на \(deviation) дБ")
    }

    @Test("Верхняя половина полосы доезжает — ради неё кодек и взят", arguments: [4500.0, 5000, 6000])
    func preservesHighBand(frequency: Double) {
        // Именно это G.711 не умеет физически: у него потолок 4 кГц. Если
        // верхняя полоса собирается неправильно, тест поймает и это — тон либо
        // пропадёт, либо вылезет не на своей частоте.
        let original = tone(frequency)
        let restored = Array(roundTrip(original).dropFirst(1000))

        let expected = level(Array(original.dropFirst(1000)), at: frequency)
        let actual = level(restored, at: frequency)
        let deviation = 20 * log10(actual / expected)

        #expect(abs(deviation) < 3, "на \(Int(frequency)) Гц уровень уехал на \(deviation) дБ")
    }

    @Test("Отношение сигнал/шум не хуже G.711")
    func signalToNoiseBeatsNarrowband() {
        let original = tone(1000, seconds: 1.0)
        let restored = roundTrip(original)

        // Первые отсчёты пропускаем и сравниваем с задержкой фильтра: у
        // квадратурного банка она есть, и без выравнивания «шумом» окажется
        // сдвиг, а не шум.
        let offset = 22
        var signal = 0.0
        var noise = 0.0
        for index in 2000..<(original.count - offset) {
            let clean = Double(original[index])
            let error = Double(restored[index + offset]) - clean
            signal += clean * clean
            noise += error * error
        }
        let snr = 10 * log10(signal / max(noise, 1e-12))
        #expect(snr > 20, "отношение сигнал/шум \(snr) дБ")
    }

    @Test("Тишина остаётся тишиной")
    func silenceStaysSilent() {
        let restored = roundTrip([Int16](repeating: 0, count: 8000))
        let peak = restored.map { abs(Int($0)) }.max() ?? 0
        #expect(peak < 64, "на тишине вылезло \(peak)")
    }

    @Test("Состояние переживает нарезку на кадры")
    func stateSurvivesFraming() {
        // В разговоре кодек вызывается кадрами по 20 мс, а не одним куском.
        // Если состояние где-то теряется, на каждой границе будет щелчок.
        let original = tone(1000, seconds: 0.5)
        let whole = roundTrip(original)

        var encoder = G722.Encoder()
        var decoder = G722.Decoder()
        var framed: [Int16] = []
        for start in stride(from: 0, to: original.count, by: 320) {
            let end = min(start + 320, original.count)
            framed.append(contentsOf: decoder.decode(encoder.encode(Array(original[start..<end]))))
        }

        #expect(framed == whole, "нарезка на кадры не должна ничего менять")
    }

    @Test("Кодер и декодер разговора выбирают G.722 по кодеку")
    func frameCodersDispatchOnCodec() {
        var encoder = AudioFrameEncoder(codec: .g722)
        var decoder = AudioFrameDecoder(codec: .g722)

        let samples = tone(1000, seconds: 0.02)
        let payload = encoder.encode(samples)
        #expect(payload.count == 160)
        #expect(decoder.decode(payload).count == 320)

        // А G.711 остаётся один байт на отсчёт.
        var narrow = AudioFrameEncoder(codec: .pcmu)
        #expect(narrow.encode([Int16](repeating: 0, count: 160)).count == 160)
    }

    @Test("Молчащий кадр имеет правильную длину в обоих кодеках")
    func silencePayloadMatchesFrameSize() {
        #expect(AudioCodec.g722.silencePayload(forPacketTime: 20).count == 160)
        #expect(AudioCodec.pcmu.silencePayload(forPacketTime: 20).count == 160)
        #expect(AudioCodec.pcma.silencePayload(forPacketTime: 20).count == 160)
    }

    @Test("Полоса восстанавливается ровно по всей ширине")
    func qmfReconstructsFlat() {
        // Этот тест существует ради одной конкретной ошибки: если в
        // квадратурном фильтре перепутать развязку чётных и нечётных отводов,
        // кодек продолжает работать. Ниже 1 кГц потерь почти нет, речь
        // разборчива, ничего не падает — но на 3 и 5 кГц появляется провал в
        // 13,8 дБ, и голос звучит глухо. Поймать это на слух, не зная, что
        // искать, практически невозможно.
        //
        // Ровность здесь проверяется по всей полосе сразу: у верной сборки
        // разброс держится в пределах пары децибел, у перепутанной — рушится
        // ровно на серединах полос.
        for frequency in [300.0, 1000, 2000, 3000, 3800, 4200, 5000, 6000, 7000] {
            let original = tone(frequency, seconds: 0.5)
            let restored = Array(roundTrip(original).dropFirst(2000))

            let expected = level(Array(original.dropFirst(2000)), at: frequency)
            let actual = level(restored, at: frequency)
            let deviation = 20 * log10(actual / expected)

            #expect(abs(deviation) < 3.5, "на \(Int(frequency)) Гц отклонение \(deviation) дБ")
        }
    }
}
