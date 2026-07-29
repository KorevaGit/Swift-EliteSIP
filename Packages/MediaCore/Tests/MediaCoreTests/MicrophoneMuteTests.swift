import Testing
@testable import MediaCore

@Suite("Mute микрофона")
struct MicrophoneMuteTests {

    @Test("Mute удаляет все отсчёты непосредственно перед кодированием")
    func mutedFrameContainsOnlySilence() {
        let voice: [Int16] = [
            -32_000, -12_345, -1, 0, 1, 12_345, 32_000,
        ]

        let muted = VoiceAudioEngine.gateMicrophoneFrame(voice, isMuted: true)

        #expect(muted.count == voice.count)
        #expect(muted.allSatisfy { $0 == 0 })
    }

    @Test("Заглушённый кадр декодируется как тишина во всех кодеках")
    func mutedFrameStaysSilentOnWire() {
        for codec in AudioCodec.allCases {
            let sampleCount = codec.sampleCount(forPacketTime: 20)
            let voice = (0..<sampleCount).map { index in
                Int16((index * 977) % 60_000 - 30_000)
            }
            let muted = VoiceAudioEngine.gateMicrophoneFrame(
                voice,
                isMuted: true
            )

            var encoder = AudioFrameEncoder(codec: codec)
            var decoder = AudioFrameDecoder(codec: codec)
            let decoded = decoder.decode(encoder.encode(muted))
            let peak = decoded.map { abs(Int($0)) }.max() ?? 0

            #expect(peak < 64, "\(codec.sdpName): пик тишины \(peak)")
        }
    }

    @Test("После unmute исходные отсчёты проходят без изменения")
    func unmutedFrameIsUnchanged() {
        let voice: [Int16] = [-20_000, -500, 0, 500, 20_000]

        #expect(
            VoiceAudioEngine.gateMicrophoneFrame(voice, isMuted: false) == voice
        )
    }

    @Test("Состояние движка переключается без запуска звукового устройства")
    func engineTracksMuteState() throws {
        let engine = try VoiceAudioEngine()
        #expect(!engine.isMuted)

        engine.isMuted = true
        #expect(engine.isMuted)

        engine.isMuted = false
        #expect(!engine.isMuted)
    }
}
