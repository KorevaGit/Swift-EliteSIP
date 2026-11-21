import Foundation
import Testing
@testable import MediaCore

/// Обработка голоса, перенесённая из Windows 0.1.73: приглушение голосов
/// вокруг, выравнивание приёма, ограничитель и итог обработки. Проверки — те
/// же, что в `VoiceProcessorTests` и `ReceiveLevelingTests` на Windows.
@Suite("Обработка голоса")
struct VoiceProcessingTests {

    /// Кадр голосоподобного сигнала: гармоники с плавающим тоном и слоговой
    /// огибающей, RMS около `levelDb`. Возвращает фазу для следующего кадра.
    private static func speech(
        _ frame: inout [Float], index: Int, rate: Int, levelDb: Double, pitch: Double, phase: Double
    ) -> Double {
        var phase = phase
        let amplitude = pow(10, levelDb / 20) * 2.2
        for i in frame.indices {
            let t = (Double(index) * Double(frame.count) + Double(i)) / Double(rate)
            let tone = pitch + 0.2 * pitch * sin(2 * .pi * 0.7 * t)
            phase += 2 * .pi * tone / Double(rate)
            let syllable = 0.5 + 0.5 * sin(2 * .pi * 4 * t)
            var voice = 0.0
            for harmonic in 1...6 {
                voice += sin(Double(harmonic) * phase) / Double(harmonic)
            }
            frame[i] = Float(voice * syllable * amplitude)
        }
        return phase
    }

    private static func energy(_ frame: [Float]) -> Double {
        frame.reduce(0) { $0 + Double($1) * Double($1) }
    }

    /// Оператор говорит полторы секунды, полторы молчит; в его паузах говорит
    /// сосед на 26 дБ тише. Уровни после первых четырёх секунд.
    private static func operatorAndNeighbour(rate: Int, gate: Bool) -> (operator: Double, neighbour: Double) {
        var voiceGate = BackgroundVoiceGate()
        let size = rate / 100
        var near = [Float](repeating: 0, count: size)
        var neighbour = [Float](repeating: 0, count: size)
        var generator = SystemRandomNumberGenerator()
        var operatorPhase = 0.0
        var neighbourPhase = 0.0
        var operatorEnergy = 0.0
        var neighbourEnergy = 0.0
        var operatorCount = 0
        var neighbourCount = 0

        for f in 0..<2000 {
            let talking = f % 300 < 150
            operatorPhase = speech(&near, index: f, rate: rate, levelDb: talking ? -24 : -200,
                                   pitch: 125, phase: operatorPhase)
            neighbourPhase = speech(&neighbour, index: f, rate: rate, levelDb: talking ? -200 : -50,
                                    pitch: 205, phase: neighbourPhase)
            for i in 0..<size {
                // Остаток фона после Voice Processing — около −80 дБ.
                near[i] += neighbour[i] + Float.random(in: -0.00015...0.00015, using: &generator)
            }

            var slice = near[...]
            if gate { voiceGate.process(&slice) }
            let output = Array(slice)

            // Края реплик не мерятся: там удержание блока.
            let phaseInCycle = f % 150
            if f < 400 || phaseInCycle < 40 || phaseInCycle > 140 { continue }
            if talking {
                operatorEnergy += energy(output)
                operatorCount += size
            } else {
                neighbourEnergy += energy(output)
                neighbourCount += size
            }
        }
        return (10 * log10(operatorEnergy / Double(operatorCount)),
                10 * log10(neighbourEnergy / Double(neighbourCount)))
    }

    @Test("Голоса вокруг приглушаются, а голос оператора нет", arguments: [8_000, 16_000, 48_000])
    func neighbourSuppressed(rate: Int) {
        let off = Self.operatorAndNeighbour(rate: rate, gate: false)
        let on = Self.operatorAndNeighbour(rate: rate, gate: true)
        #expect(off.neighbour - on.neighbour >= 18, "сосед: \(off.neighbour) → \(on.neighbour) дБ")
        #expect(abs(on.operator - off.operator) <= 1.5, "оператор: \(off.operator) → \(on.operator) дБ")
    }

    @Test("Без голоса оператора ничего не приглушается")
    func nothingBeforeOperatorHeard() {
        var gate = BackgroundVoiceGate()
        let rate = 16_000
        var frame = [Float](repeating: 0, count: rate / 100)
        var phase = 0.0
        var energyIn = 0.0
        var energyOut = 0.0
        for f in 0..<300 {
            phase = Self.speech(&frame, index: f, rate: rate, levelDb: -50, pitch: 210, phase: phase)
            energyIn += Self.energy(frame)
            var slice = frame[...]
            gate.process(&slice)
            energyOut += Self.energy(Array(slice))
        }
        let change = 10 * log10(energyOut / energyIn)
        #expect(change >= -1 && change <= 0.1, "изменение \(change) дБ")
    }

    @Test("Щелчок не закрывает голос оператора")
    func clickDoesNotRaiseVoice() throws {
        var gate = BackgroundVoiceGate()
        let rate = 16_000
        var frame = [Float](repeating: 0, count: rate / 100)
        var phase = 0.0
        for f in 0..<200 {
            phase = Self.speech(&frame, index: f, rate: rate, levelDb: -26, pitch: 130, phase: phase)
            var slice = frame[...]
            gate.process(&slice)
        }
        let before = try #require(gate.voiceDb)
        for _ in 0..<2 {
            var click = [Float](repeating: 0.9, count: rate / 100)[...]
            gate.process(&click)
        }
        let after = try #require(gate.voiceDb)
        #expect(after - before <= 1.01, "щелчок поднял голос с \(before) до \(after) дБ")
    }

    // MARK: - Приём

    /// Гонит речь заданного уровня через регулятор приёма и возвращает его
    /// прибавку в конце.
    private static func leveledGain(levelDb: Double, seconds: Int = 20) -> Double {
        var leveler = SpeechGainControl()
        let rate = 8_000
        var frame = [Float](repeating: 0, count: rate / 100)
        var phase = 0.0
        for f in 0..<(seconds * 100) {
            phase = speech(&frame, index: f, rate: rate, levelDb: levelDb, pitch: 140, phase: phase)
            var slice = frame[...]
            leveler.process(&slice)
        }
        return leveler.gainDb
    }

    @Test("Тихая линия поднимается на +10 дБ и не больше")
    func quietLineBoostCapped() {
        let gain = Self.leveledGain(levelDb: -40)
        #expect(abs(gain - SpeechGainControl.receiveMaximumBoostDb) < 0.01, "прибавка \(gain) дБ")
    }

    @Test("Громкая линия убавляется не больше чем на 6 дБ")
    func loudLineCutCapped() {
        let gain = Self.leveledGain(levelDb: -3)
        #expect(gain >= -SpeechGainControl.receiveMaximumCutDb - 0.01, "убавка \(gain) дБ")
        #expect(gain < -3, "громкая линия не убавлена: \(gain) дБ")
    }

    @Test("Ровный шум без речи прибавку не растит")
    func steadyNoiseDoesNotBoost() {
        var leveler = SpeechGainControl()
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            var frame = (0..<80).map { _ in Float.random(in: -0.003...0.003, using: &generator) }[...]
            leveler.process(&frame)
        }
        #expect(leveler.gainDb < 0.5, "прибавка на шуме \(leveler.gainDb) дБ")
    }

    @Test("200 % от полной шкалы после ограничителя остаются в шкале")
    func limiterKeepsScale() {
        for sample in stride(from: Float(-1), through: 1, by: 0.01) {
            let limited = SoftLimiter.limit(sample * VoiceAudioEngine.Configuration.playbackVolumeLimit)
            #expect(abs(limited) <= 1)
        }
        #expect(SoftLimiter.limit(0.5) == 0.5)
        #expect(SoftLimiter.limit(-0.9) == -0.9)
    }

    @Test("Громкость обрезается на двух")
    func volumeClampedAtTwo() {
        let configuration = VoiceAudioEngine.Configuration(playbackVolume: 5)
        #expect(configuration.playbackVolume == 2)
    }

    // MARK: - Итог

    @Test("Фон — десятый процентиль, цифровой ноль на старте его не роняет")
    func noiseFloorPercentile() {
        var meter = NoiseFloorMeter()
        meter.observe(levelDb: -180)
        for _ in 0..<50 { meter.observe(levelDb: -60) }
        for _ in 0..<50 { meter.observe(levelDb: -20) }
        #expect(meter.decibels == -60)
    }

    @Test("Итог называет приглушение и выравнивание")
    func summaryMentionsProcessing() {
        var stats = VoiceProcessingStatistics()
        stats.frames = 1000
        stats.suppressedFrames = 380
        stats.usedSuppression = true
        stats.voiceDb = -24
        stats.receiveLevelingDb = 4
        #expect(stats.summary.contains("голоса вокруг приглушались 38 % времени"))
        #expect(stats.summary.contains("выравнивание приёма +4 дБ"))
        #expect(VoiceProcessingStatistics().summary == "обработка: ни одного кадра")
    }
}
