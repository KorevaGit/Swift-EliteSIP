import AVFoundation
import Foundation
import MediaCore

/// Замеры качества сигнала без звуковой карты.
///
/// Всё, что делает тракт с сигналом между микрофоном и сетью, — это пересчёт
/// частоты и G.711. Оба шага чистые функции, поэтому их можно измерить точно и
/// повторяемо, не полагаясь на слух и не занимая устройство.
///
/// Главный вопрос здесь — подавление зеркал. При переходе с 48 кГц на 8 кГц всё,
/// что выше 4 кГц, обязано быть отфильтровано ДО прореживания. Если фильтра нет
/// или он слабый, шипящие согласные и звон складываются обратно в полосу как
/// посторонний тон — на слух это «булькающий», «жестяной» голос, причём тем
/// сильнее, чем чище микрофон.
enum QualityProbe {

    static func run(arguments: [String]) {
        print("Пересчёт 48 000 → 8 000 Гц, вход float32 моно, выход int16 моно.")
        print("Тон подаётся на полной шкале; в таблице — уровень того, что вышло.\n")

        let qualities: [(String, AVAudioQuality)] = [
            ("medium (по умолчанию)", .medium),
            ("max", .max),
        ]

        print("── Полоса пропускания (сколько теряется полезного) ──")
        print(String(format: "%-10s %22s %22s", ("вход" as NSString).utf8String!,
                     ("medium" as NSString).utf8String!, ("max" as NSString).utf8String!))
        for frequency in [200.0, 300, 500, 1000, 2000, 3000, 3400, 3800] {
            var cells: [String] = []
            for (_, quality) in qualities {
                let level = measure(tone: frequency, at: frequency, quality: quality)
                cells.append(String(format: "%+7.2f дБ", level))
            }
            print(String(format: "%7.0f Гц %20@ %20@", frequency,
                         cells[0] as NSString, cells[1] as NSString))
        }

        print("\n── Зеркала (что прилетает в полосу из-за прореживания) ──")
        print("тон выше 4 кГц складывается в полосу; чем ниже уровень, тем лучше фильтр")
        for frequency in [4500.0, 5000, 6000, 7000, 9000, 12000, 15000, 20000] {
            let alias = aliasFrequency(of: frequency, sampleRate: 8000)
            var cells: [String] = []
            for (_, quality) in qualities {
                let level = measure(tone: frequency, at: alias, quality: quality)
                cells.append(String(format: "%+7.2f дБ", level))
            }
            print(String(
                format: "%7.0f Гц → зеркало %6.0f Гц:  medium %@   max %@",
                frequency, alias, cells[0] as NSString, cells[1] as NSString
            ))
        }

        print("\n── Зеркала на разных частотах входа (тон 5 кГц → 3 кГц) ──")
        print("24 кГц — AirPods, 44,1 — многие USB, 48 — встроенный микрофон")
        for inputRate in [24000.0, 44100, 48000] {
            let medium = measure(tone: 5000, at: 3000, quality: .medium, inputRate: inputRate)
            let best = measure(tone: 5000, at: 3000, quality: .max, inputRate: inputRate)
            print(String(format: "%7.0f Гц:  medium %+7.2f дБ   max %+7.2f дБ", inputRate, medium, best))
        }

        print("\n── Цена по времени (пересчёт идёт на потоке захвата) ──")
        for inputRate in [24000.0, 48000] {
            for (label, quality) in qualities {
                let microseconds = conversionCost(inputRate: inputRate, quality: quality)
                // Блок отвода — 100 мс. Всё, что сильно меньше, безопасно.
                print(String(
                    format: "%5.0f Гц, %-22@: %6.1f мкс на блок 100 мс (%.3f %% бюджета)",
                    inputRate, label as NSString, microseconds, microseconds / 100_000 * 100
                ))
            }
        }

        print("\n── Собственный шум G.711 (предел кодека, ниже не будет) ──")
        for level in [0.0, -10.0, -20.0, -30.0] {
            let snr = codecSignalToNoise(toneLevelDB: level)
            print(String(format: "сигнал %+5.0f дБ → отношение сигнал/шум %5.1f дБ", level, snr))
        }
    }

    /// Куда сложится тон после прореживания до `sampleRate`.
    static func aliasFrequency(of frequency: Double, sampleRate: Double) -> Double {
        let folded = frequency.truncatingRemainder(dividingBy: sampleRate)
        return folded > sampleRate / 2 ? sampleRate - folded : folded
    }

    /// Прогоняет тон через тот же конвертер, что стоит в захвате, и меряет
    /// уровень на заданной частоте.
    static func measure(
        tone frequency: Double,
        at probe: Double,
        quality: AVAudioQuality,
        inputRate: Double = 48000
    ) -> Double {
        let outputRate = 8000.0
        let seconds = 1.0

        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false
        ), let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: outputRate, channels: 1, interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return .nan
        }
        converter.sampleRateConverterQuality = Int(quality.rawValue)

        let inputCount = Int(inputRate * seconds)
        guard let input = AVAudioPCMBuffer(
            pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(inputCount)
        ) else { return .nan }
        input.frameLength = AVAudioFrameCount(inputCount)

        // Амплитуда 0.5, а не 1.0: у самой шкалы µ-law своя нелинейность, и
        // мерить фильтр на клиппинге значит мерить не фильтр.
        let channel = input.floatChannelData![0]
        for index in 0..<inputCount {
            channel[index] = Float(0.5 * sin(2 * .pi * frequency * Double(index) / inputRate))
        }

        let outputCount = Int(outputRate * seconds) + 64
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(outputCount)
        ) else { return .nan }

        var delivered = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if delivered {
                status.pointee = .noDataNow
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, output.frameLength > 0 else { return .nan }

        let samples = UnsafeBufferPointer(start: output.int16ChannelData![0], count: Int(output.frameLength))
        // Первые отсчёты — переходный процесс фильтра; они бы завысили зеркала.
        let usable = Array(samples.dropFirst(400)).map { Double($0) / 32768.0 }
        guard usable.count > 100 else { return .nan }

        let magnitude = goertzel(usable, frequency: probe, sampleRate: outputRate)
        // Опорный уровень — та же амплитуда 0.5, то есть 0 дБ означает «прошло
        // без потерь».
        return 20 * log10(max(magnitude, 1e-12) / 0.5)
    }

    /// Сколько времени занимает пересчёт блока в 100 мс — столько отдаёт отвод
    /// микрофона за раз. Считается на потоке захвата, поэтому цена важна.
    static func conversionCost(inputRate: Double, quality: AVAudioQuality) -> Double {
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false
        ), let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 8000, channels: 1, interleaved: true
        ) else { return .nan }

        let blockFrames = Int(inputRate / 10)
        var elapsed: [Double] = []

        for _ in 0..<50 {
            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return .nan }
            converter.sampleRateConverterQuality = Int(quality.rawValue)

            guard let input = AVAudioPCMBuffer(
                pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(blockFrames)
            ), let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(blockFrames)
            ) else { return .nan }
            input.frameLength = AVAudioFrameCount(blockFrames)
            for index in 0..<blockFrames {
                input.floatChannelData![0][index] =
                    Float(0.4 * sin(2 * .pi * 1000 * Double(index) / inputRate))
            }

            var delivered = false
            var error: NSError?
            let started = CFAbsoluteTimeGetCurrent()
            converter.convert(to: output, error: &error) { _, status in
                if delivered { status.pointee = .noDataNow; return nil }
                delivered = true
                status.pointee = .haveData
                return input
            }
            elapsed.append((CFAbsoluteTimeGetCurrent() - started) * 1_000_000)
        }

        // Медиана, а не среднее: первый прогон греет кэши и завышает всё.
        return elapsed.sorted()[elapsed.count / 2]
    }

    /// Отношение сигнал/шум самого G.711 на тоне 1 кГц.
    static func codecSignalToNoise(toneLevelDB: Double) -> Double {
        let amplitude = pow(10, toneLevelDB / 20) * 0.9
        let count = 8000
        var original = [Int16](repeating: 0, count: count)
        for index in 0..<count {
            original[index] = Int16(amplitude * 32000 * sin(2 * .pi * 1000 * Double(index) / 8000))
        }

        let restored = G711.decode(G711.encode(original, as: .pcmu), as: .pcmu)
        var signal = 0.0
        var noise = 0.0
        for index in 0..<count {
            let clean = Double(original[index])
            let error = Double(restored[index]) - clean
            signal += clean * clean
            noise += error * error
        }
        return 10 * log10(signal / max(noise, 1e-12))
    }

    /// Гёрцель: точная амплитуда на одной частоте. Полное преобразование здесь
    /// не нужно — интересуют считаные точки, а не спектр целиком.
    static func goertzel(_ samples: [Double], frequency: Double, sampleRate: Double) -> Double {
        let count = samples.count
        let omega = 2 * Double.pi * frequency / sampleRate
        let coefficient = 2 * cos(omega)

        var previous = 0.0
        var beforePrevious = 0.0
        for sample in samples {
            let current = sample + coefficient * previous - beforePrevious
            beforePrevious = previous
            previous = current
        }

        let real = previous - beforePrevious * cos(omega)
        let imaginary = beforePrevious * sin(omega)
        return 2 * sqrt(real * real + imaginary * imaginary) / Double(count)
    }
}
