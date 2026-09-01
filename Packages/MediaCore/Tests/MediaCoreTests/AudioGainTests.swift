import Testing
@testable import MediaCore

@Suite("Громкость")
struct AudioGainTests {

    @Test("Единица не трогает отсчёты вовсе")
    func unityIsUntouched() {
        var samples: [Int16] = [-32_768, -20_000, -1, 0, 1, 20_000, 32_767]
        let original = samples
        VoiceAudioEngine.amplify(&samples, by: 1)
        #expect(samples == original)
    }

    @Test("Усиление поднимает тихое и не переполняет громкое")
    func gainClipsInsteadOfWrapping() {
        var samples: [Int16] = [-30_000, -1_000, 0, 1_000, 30_000]
        VoiceAudioEngine.amplify(&samples, by: 2)

        // Тихое поднялось ровно вдвое.
        #expect(samples[1] == -2_000)
        #expect(samples[3] == 2_000)
        // А громкое упёрлось в шкалу, а не перевернулось знаком. Без
        // ограничения здесь было бы переполнение Int16: на отладочной сборке
        // это падение процесса, на релизной — треск вместо голоса.
        #expect(samples[0] == Int16.min)
        #expect(samples[4] == Int16.max)
        #expect(samples[2] == 0)
    }

    @Test("Ослабление работает и на границах шкалы")
    func attenuationHandlesExtremes() {
        var samples: [Int16] = [Int16.min, Int16.max]
        VoiceAudioEngine.amplify(&samples, by: 0.5)
        #expect(samples[0] == -16_384)
        #expect(samples[1] == 16_383)
    }

    @Test("Ноль — это тишина, а не отключение потока")
    func zeroGainIsSilence() {
        var samples: [Int16] = [-30_000, 1_000, 30_000]
        VoiceAudioEngine.amplify(&samples, by: 0)
        #expect(samples == [0, 0, 0])
    }

    @Test("Границы множителя проверяются, а не принимаются на веру")
    func gainIsClamped() {
        // Правленный руками файл настроек может принести и отрицательное
        // усиление — это переворот фазы, то есть не «тише», а «наоборот», — и
        // бесконечность из испорченного JSON.
        #expect(Float(-1).clampedGain(to: 2) == 0)
        #expect(Float(5).clampedGain(to: 2) == 2)
        #expect(Float(5).clampedGain(to: 1) == 1)
        #expect(Float.infinity.clampedGain(to: 2) == 1)
        #expect(Float.nan.clampedGain(to: 2) == 1)
        #expect(Float(0.5).clampedGain(to: 2) == 0.5)
    }

    @Test("Конфигурация тракта не пропускает значение за границы")
    func configurationClampsGains() {
        let configuration = VoiceAudioEngine.Configuration(
            microphoneGain: 99,
            playbackVolume: 99
        )
        #expect(configuration.microphoneGain == VoiceAudioEngine.Configuration.microphoneGainLimit)
        #expect(configuration.playbackVolume == 1)
    }
}
