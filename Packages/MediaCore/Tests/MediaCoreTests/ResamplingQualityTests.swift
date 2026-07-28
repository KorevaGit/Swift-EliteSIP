import AVFoundation
import Foundation
import Testing
@testable import MediaCore

/// Качество пересчёта частоты — единственное место в тракте, где сигнал можно
/// испортить необратимо и молча. Тесты держат планку, потому что настройка
/// качества выглядит как мелочь и первой попадает под «упростить».
///
/// Звуковая карта здесь не нужна: `AVAudioConverter` — чистая функция, и это
/// ровно тот же объект, что стоит в захвате.
@Suite("Пересчёт частоты")
struct ResamplingQualityTests {

    /// Тот же конвертер, что собирает `VoiceAudioEngine.startCapture`.
    private func makeConverter(inputRate: Double, quality: AVAudioQuality) -> AVAudioConverter? {
        guard let input = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false
        ), let output = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 8000, channels: 1, interleaved: true
        ), let converter = AVAudioConverter(from: input, to: output) else {
            return nil
        }
        converter.sampleRateConverterQuality = Int(quality.rawValue)
        return converter
    }

    /// Уровень на частоте `probe` после прогона тона `tone` через пересчёт, в дБ
    /// относительно поданного.
    private func level(
        tone: Double,
        at probe: Double,
        inputRate: Double,
        quality: AVAudioQuality = .max
    ) -> Double {
        guard let converter = makeConverter(inputRate: inputRate, quality: quality),
              let inputFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false
              ),
              let outputFormat = AVAudioFormat(
                  commonFormat: .pcmFormatInt16, sampleRate: 8000, channels: 1, interleaved: true
              ) else {
            return .nan
        }

        let inputCount = Int(inputRate)
        guard let input = AVAudioPCMBuffer(
            pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(inputCount)
        ), let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat, frameCapacity: 8064
        ) else { return .nan }

        input.frameLength = AVAudioFrameCount(inputCount)
        let amplitude = 0.5
        for index in 0..<inputCount {
            input.floatChannelData![0][index] =
                Float(amplitude * sin(2 * .pi * tone * Double(index) / inputRate))
        }

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
        guard error == nil, output.frameLength > 400 else { return .nan }

        // Начало отбрасывается: там переходный процесс фильтра, и он завысил бы
        // уровень зеркал.
        let samples = UnsafeBufferPointer(start: output.int16ChannelData![0], count: Int(output.frameLength))
        let usable = Array(samples.dropFirst(400)).map { Double($0) / 32768.0 }

        return 20 * log10(max(goertzel(usable, frequency: probe, sampleRate: 8000), 1e-12) / amplitude)
    }

    /// Амплитуда на одной частоте. Полный спектр не нужен — интересны точки.
    private func goertzel(_ samples: [Double], frequency: Double, sampleRate: Double) -> Double {
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
        return 2 * sqrt(real * real + imaginary * imaginary) / Double(samples.count)
    }

    @Test("Зеркала подавлены не меньше чем на 50 дБ", arguments: [24000.0, 44100, 48000])
    func rejectsAliasing(inputRate: Double) {
        // Тон 5 кГц при прореживании до 8 кГц складывается в 3 кГц — в середину
        // речевой полосы. На качестве `.medium` он возвращается с уровнем
        // −14,9 дБ, и это слышно как подсвистывание на шипящих.
        let alias = level(tone: 5000, at: 3000, inputRate: inputRate)
        #expect(alias < -50, "зеркало 5 кГц → 3 кГц на входе \(Int(inputRate)) Гц: \(alias) дБ")
    }

    @Test("Речевая полоса проходит без завала", arguments: [300.0, 1000, 2000, 3000])
    func keepsSpeechBand(frequency: Double) {
        let passed = level(tone: frequency, at: frequency, inputRate: 48000)
        // −1,5 дБ — запас к замеру на 3 кГц (−1,25 дБ). На `.medium` там −3,73,
        // то есть тест поймал бы откат настройки.
        #expect(passed > -1.5, "на \(Int(frequency)) Гц потеряно \(passed) дБ")
    }

    @Test("Настройка качества действительно меняет результат")
    func qualitySettingMatters() {
        // Страховка от того, что настройку однажды перестанут применять: если
        // `.medium` и `.max` дадут одно и то же, значит присваивание потеряно.
        let medium = level(tone: 5000, at: 3000, inputRate: 48000, quality: .medium)
        let best = level(tone: 5000, at: 3000, inputRate: 48000, quality: .max)
        #expect(best < medium - 20, "medium \(medium) дБ, max \(best) дБ")
    }
}
