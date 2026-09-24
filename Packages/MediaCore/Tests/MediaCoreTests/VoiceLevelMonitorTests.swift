import Foundation
import Testing
@testable import MediaCore

/// Проверочный звук раздела «Звук». Сам тракт здесь не поднять — нет
/// микрофона и разрешений, — поэтому проверяется то, что в тракт уходит.
@Suite("Проверочный звук")
struct VoiceLevelMonitorTests {

    @Test("Кадров ровно на две секунды, каждый полного размера", arguments: [AudioCodec.pcmu, .g722])
    func framesCoverDuration(codec: AudioCodec) {
        let frames = VoiceLevelMonitor.testSoundFrames(codec: codec, packetTime: 20)
        #expect(frames.count == Int(VoiceLevelMonitor.testSoundSeconds * 1000 / 20))
        #expect(frames.allSatisfy { $0.count == codec.byteCount(forPacketTime: 20) })
    }

    @Test("Звук слышен, но без перегруза и щелчка в конце")
    func soundIsAudibleAndClean() {
        let samples = VoiceLevelMonitor.testSoundSamples(sampleRate: 8000)
        let peak = samples.map { abs(Int($0)) }.max() ?? 0
        #expect(peak > Int(Int16.max) / 8, "шкала должна заметно сдвинуться")
        #expect(peak < Int(Int16.max), "до ограничения не доходим")
        #expect(abs(Int(samples.last ?? 1)) < 100, "хвост уходит в ноль")
    }
}
