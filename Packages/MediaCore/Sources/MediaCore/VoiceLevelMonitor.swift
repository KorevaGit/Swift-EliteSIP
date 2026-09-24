import Compat
import Foundation

/// Живые уровни на странице настроек звука: микрофон и проверочный звук.
///
/// **Зачем.** До 0.1.41 полоски уровня оживали только в разговоре и в
/// пятисекундной самопроверке. Выставить усиление при этом было нечем: тянешь
/// ползунок — и не видишь, как меняется голос, пока не позвонишь. Монитор
/// держит тракт, пока открыт раздел «Звук», и полоска микрофона отвечает на
/// голос сразу.
///
/// Тракт тот же, что у разговора, по той же причине, что и у `VoiceSelfTest`:
/// уровень берётся после усиления и обработки голоса, то есть ровно тот, что
/// уйдёт в линию. Отдельный `AVAudioEngine` показал бы сырой сигнал, и
/// ползунок усиления на нём ничего бы не двигал.
///
/// Захваченный голос никуда не уходит и нигде не копится: кадры кодека
/// выбрасываются сразу, остаётся только число уровня.
///
/// **Проверочный звук.** Пока `isPlayingTestSound`, в воспроизведение идёт
/// мягкий аккорд — тем же кодеком и тем же выходом, что и голос собеседника.
/// Полоска приёма и наушники проверяются одним нажатием, без звонка.
///
/// Разговор забирает тракт себе сам (`VoiceAudioBus.claim` отпускает прежнего
/// владельца), поэтому монитор не мешает входящему; вернуть его после звонка —
/// дело того, кто показывает страницу.
public final class VoiceLevelMonitor: @unchecked Sendable {

    /// Сколько длится проверочный звук.
    public static let testSoundSeconds = 2.0

    private let bus: VoiceAudioBus
    private let configuration: VoiceAudioEngine.Configuration
    private var token: VoiceAudioBus.Token { ObjectIdentifier(self) }

    private let state = UnfairLock(initialState: State())

    private struct State: Sendable {
        var testFrames: [Data] = []
        var testIndex = 0
    }

    /// Подробности в журнал.
    public var onDiagnostic: (@Sendable (String) -> Void)?

    /// Проверочный звук доиграл. На главной очереди.
    public var onTestSoundFinished: (@Sendable () -> Void)?

    public init(bus: VoiceAudioBus, configuration: VoiceAudioEngine.Configuration) {
        self.bus = bus
        self.configuration = configuration
    }

    /// Тракт всё ещё у монитора. Разговор или самопроверка могли его забрать.
    public var isActive: Bool { bus.isOwner(token) }

    public var inputLevel: Float { bus.withEngine(token) { $0.inputLevel } ?? 0 }
    public var outputLevel: Float { bus.withEngine(token) { $0.outputLevel } ?? 0 }

    public var isPlayingTestSound: Bool {
        state.withLock { $0.testIndex < $0.testFrames.count }
    }

    /// Усиление и громкость меняются на ходу, без пересборки тракта.
    public var microphoneGain: Float {
        get { bus.withEngine(token) { $0.microphoneGain } ?? configuration.microphoneGain }
        set { bus.withEngine(token) { $0.microphoneGain = newValue } }
    }

    public var playbackVolume: Float {
        get { bus.withEngine(token) { $0.playbackVolume } ?? configuration.playbackVolume }
        set { bus.withEngine(token) { $0.playbackVolume = newValue } }
    }

    public func start() throws {
        var handlers = VoiceAudioBus.Handlers()
        handlers.diagnostic = { [weak self] message in self?.onDiagnostic?(message) }
        // Голос не хранится: уровень движок считает сам, кадр больше не нужен.
        handlers.encodedFrame = { _ in }
        handlers.needsFrame = { [weak self] in self?.nextTestFrame() }
        try bus.claim(token, configuration: configuration, handlers: handlers)
    }

    public func stop() {
        state.withLock { $0 = State() }
        bus.release(token)
    }

    /// Проиграть проверочный звук в выбранные наушники.
    public func playTestSound() {
        let frames = Self.testSoundFrames(
            codec: configuration.codec,
            packetTime: max(configuration.packetTimeMilliseconds, 1)
        )
        state.withLock {
            $0.testFrames = frames
            $0.testIndex = 0
        }
    }

    private func nextTestFrame() -> VoiceAudioEngine.PlaybackFrame? {
        let (payload, finished): (Data?, Bool) = state.withLock { state in
            guard state.testIndex < state.testFrames.count else { return (nil, false) }
            defer { state.testIndex += 1 }
            let last = state.testIndex == state.testFrames.count - 1
            return (state.testFrames[state.testIndex], last)
        }
        if finished {
            let handler = onTestSoundFinished
            DispatchQueue.main.async { handler?() }
        }
        return payload.map { VoiceAudioEngine.PlaybackFrame(payload: $0, isConcealment: false) }
    }

    /// Мажорное трезвучие вверх: до, ми, соль — по полсекунды с затуханием, и
    /// последнее держится дольше. Узнаваемо как «проверка», не похоже ни на
    /// гудок, ни на звонок, и достаточно громкое, чтобы полоска дошла до
    /// середины на обычной громкости.
    static func testSoundSamples(sampleRate: Double) -> [Int16] {
        let notes: [(frequency: Double, start: Double)] = [
            (523.25, 0.0), (659.25, 0.45), (783.99, 0.9),
        ]
        let count = Int(testSoundSeconds * sampleRate)
        return (0..<count).map { index in
            let time = Double(index) / sampleRate
            var value = 0.0
            for note in notes where time >= note.start {
                let local = time - note.start
                let attack = min(1, local / 0.01)
                let decay = exp(-local / 0.6)
                value += sin(2 * .pi * note.frequency * local) * attack * decay
            }
            // Хвост к нулю, чтобы конец не щёлкал.
            let tail = min(1, (testSoundSeconds - time) / 0.05)
            return Int16(max(-1, min(1, 0.22 * value * tail)) * Double(Int16.max))
        }
    }

    static func testSoundFrames(codec: AudioCodec, packetTime: Int) -> [Data] {
        let samples = testSoundSamples(sampleRate: Double(codec.sampleRate))
        let perFrame = codec.sampleCount(forPacketTime: packetTime)
        var encoder = AudioFrameEncoder(codec: codec)
        return stride(from: 0, to: samples.count, by: perFrame).map { start in
            var chunk = Array(samples[start..<min(start + perFrame, samples.count)])
            if chunk.count < perFrame { chunk += [Int16](repeating: 0, count: perFrame - chunk.count) }
            return encoder.encode(chunk)
        }
    }

    deinit {
        bus.release(token)
    }
}
