import AVFoundation
import Foundation
import os

/// Аудиотракт разговора: микрофон → кодек → сеть и обратно.
///
/// Ключевое решение — `setVoiceProcessingEnabled(true)`. Это включает системный
/// блок обработки голоса (VoiceProcessingIO): тот же эхоподавитель, шумодав и
/// автоусиление, что использует FaceTime. Своего эхоподавителя мы не пишем и не
/// будем: написать сравнимый — это отдельный проект, а без эхоподавления
/// разговор через колонки невозможен.
///
/// Класс помечен `@unchecked Sendable`: изменяемое состояние либо живёт под
/// замком, либо трогается только на одном потоке. Где именно — отмечено по месту.
public final class VoiceAudioEngine: @unchecked Sendable {

    public struct Configuration: Sendable {
        public var codec: AudioCodec
        public var packetTimeMilliseconds: Int
        /// Глубина буфера воспроизведения в кадрах, после которой старое
        /// выбрасывается. Защита от роста задержки, если сеть отдаёт быстрее,
        /// чем звуковая карта успевает играть.
        public var maximumPlaybackFrames: Int

        public init(
            codec: AudioCodec = .pcmu,
            packetTimeMilliseconds: Int = defaultPacketTimeMilliseconds,
            maximumPlaybackFrames: Int = 25
        ) {
            self.codec = codec
            self.packetTimeMilliseconds = packetTimeMilliseconds
            self.maximumPlaybackFrames = maximumPlaybackFrames
        }

        public var samplesPerFrame: Int {
            codec.sampleCount(forPacketTime: packetTimeMilliseconds)
        }
    }

    public enum AudioError: Error, Sendable, LocalizedError {
        case microphoneDenied
        case formatUnavailable
        case voiceProcessingUnavailable(String)
        case engineFailed(String)

        public var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                "Нет доступа к микрофону. Разрешите его в «Системных настройках → Конфиденциальность»."
            case .formatUnavailable:
                "Не удалось построить формат звука 8 кГц."
            case .voiceProcessingUnavailable(let reason):
                "Системное эхоподавление недоступно: \(reason)"
            case .engineFailed(let reason):
                "Звуковой движок не запустился: \(reason)"
            }
        }
    }

    /// Кодированный кадр с микрофона, готовый к отправке в RTP.
    /// Вызывается на потоке звукового ввода — не блокировать.
    public var onEncodedFrame: (@Sendable (Data) -> Void)?

    private let configuration: Configuration
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?

    /// Формат разговора: 8 кГц, моно. Всё остальное движок пересчитывает сам.
    private let narrowbandFormat: AVAudioFormat

    // MARK: - Состояние захвата
    // Трогается только из обработчика отвода микрофона, то есть с одного потока.

    private var converter: AVAudioConverter?
    private var captureRemainder: [Int16] = []

    // MARK: - Состояние воспроизведения
    // Читается на потоке рендера звука, пишется из сети — отсюда замок.
    //
    // os_unfair_lock, а не очередь: критическая секция здесь несколько
    // микросекунд, а любое ожидание на потоке рендера слышно как щелчок.

    private let playbackLock = OSAllocatedUnfairLock(initialState: PlaybackState())

    private struct PlaybackState {
        var samples: [Float] = []
        var starvedRenders = 0
    }

    public private(set) var isRunning = false

    public init(configuration: Configuration = Configuration()) throws {
        self.configuration = configuration
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(configuration.codec.clockRate),
            channels: 1,
            interleaved: false
        ) else {
            throw AudioError.formatUnavailable
        }
        narrowbandFormat = format
    }

    // MARK: - Разрешение на микрофон

    /// Спрашивает доступ к микрофону. Без него движок запустится, но в линию
    /// уйдёт тишина, и понять причину по звуку невозможно.
    public static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    // MARK: - Запуск

    public func start() throws {
        guard !isRunning else { return }

        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw AudioError.microphoneDenied
        }

        let input = engine.inputNode
        let output = engine.outputNode

        // Включать надо ДО подключения узлов: VoiceProcessingIO меняет формат
        // входа, и уже созданные соединения после этого становятся неверными.
        do {
            try input.setVoiceProcessingEnabled(true)
            try output.setVoiceProcessingEnabled(true)
        } catch {
            throw AudioError.voiceProcessingUnavailable(error.localizedDescription)
        }

        try startPlayback()
        try startCapture()

        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw AudioError.engineFailed(error.localizedDescription)
        }

        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        if let sourceNode {
            engine.detach(sourceNode)
            self.sourceNode = nil
        }
        converter = nil
        captureRemainder.removeAll()
        playbackLock.withLock { state in
            state.samples.removeAll()
            state.starvedRenders = 0
        }
    }

    // MARK: - Воспроизведение

    /// Кладёт кодированный кадр из сети в очередь воспроизведения.
    public func enqueue(encodedFrame payload: Data) {
        let samples = G711.decode([UInt8](payload), as: configuration.codec)
        let floats = samples.map { Float($0) / 32768.0 }

        let capacity = configuration.maximumPlaybackFrames * configuration.samplesPerFrame
        playbackLock.withLock { state in
            state.samples.append(contentsOf: floats)
            // Очередь длиннее предела означает, что задержка растёт и сама уже
            // не уменьшится. Лучше выбросить старое и услышать щелчок, чем
            // разговаривать с секундным опозданием.
            if state.samples.count > capacity {
                state.samples.removeFirst(state.samples.count - capacity)
            }
        }
    }

    private func startPlayback() throws {
        let node = AVAudioSourceNode(format: narrowbandFormat) { [playbackLock] _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let requested = Int(frameCount)

            let chunk: [Float] = playbackLock.withLock { state in
                guard !state.samples.isEmpty else {
                    state.starvedRenders += 1
                    return []
                }
                let available = min(requested, state.samples.count)
                let result = Array(state.samples.prefix(available))
                state.samples.removeFirst(available)
                return result
            }

            for buffer in buffers {
                guard let pointer = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                // Недостающее добиваем тишиной: отдать меньше кадров, чем
                // попросили, нельзя — движок воспримет это как обрыв.
                for index in 0..<requested {
                    pointer[index] = index < chunk.count ? chunk[index] : 0
                }
            }
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: narrowbandFormat)
        sourceNode = node
    }

    // MARK: - Захват

    private func startCapture() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard let captureFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(configuration.codec.clockRate),
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: captureFormat) else {
            throw AudioError.formatUnavailable
        }
        self.converter = converter

        let samplesPerFrame = configuration.samplesPerFrame
        let codec = configuration.codec

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard let converted = Self.convert(buffer, using: converter, to: captureFormat) else { return }

            self.captureRemainder.append(contentsOf: converted)

            // Режем на кадры ровно по packet time: RTP не терпит кусков
            // произвольной длины, а остаток переносим в следующий отвод.
            while self.captureRemainder.count >= samplesPerFrame {
                let frame = Array(self.captureRemainder.prefix(samplesPerFrame))
                self.captureRemainder.removeFirst(samplesPerFrame)
                let encoded = Data(G711.encode(frame, as: codec))
                self.onEncodedFrame?(encoded)
            }
        }
    }

    /// Пересчитывает буфер микрофона в 8 кГц моно Int16.
    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> [Int16]? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        // Блок конвертера объявлен @Sendable, хотя вызывается синхронно и из
        // того же потока. Коробка выражает это явно вместо захвата var, на
        // который компилятор справедливо ругается.
        let source = ConversionSource(buffer: buffer)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            // Отдаём буфер ровно один раз: иначе конвертер зациклится, требуя
            // всё новых данных, и обработчик отвода никогда не вернётся.
            guard let next = source.take() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return next
        }
        guard error == nil, output.frameLength > 0, let channel = output.int16ChannelData else { return nil }

        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }

    // MARK: - Диагностика

    /// Сколько раз рендеру нечего было играть. Растущее число означает, что
    /// сеть не успевает или джиттер-буфер настроен слишком мелко.
    public var starvedRenderCount: Int {
        playbackLock.withLock { $0.starvedRenders }
    }

    public var queuedPlaybackSamples: Int {
        playbackLock.withLock { $0.samples.count }
    }
}

/// Одноразовая передача буфера в блок конвертера.
///
/// `AVAudioConverter.convert` вызывает блок синхронно, поэтому передача через
/// ссылку здесь безопасна — но `AVAudioPCMBuffer` не помечен Sendable, и без
/// явной коробки компилятор об этом не догадывается.
private final class ConversionSource: @unchecked Sendable {

    private var buffer: AVAudioPCMBuffer?

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
