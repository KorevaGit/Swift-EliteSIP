import AVFoundation
import Compat
import MediaCore

/// Звонок входящего вызова.
///
/// Стандартный звонок — мягкий двойной телефонный, файлом в бандле
/// (`Sounds/ringtone.wav`). С 22 октября 2026 это тот же WAV, что у Windows
/// 0.1.82, байт в байт (SHA-256 `2CCD7DF4…3E5535`): выбрал его заказчик, и
/// звучать на двух системах по-разному стандартный звонок не должен. Файл
/// целиком читается в буфер и
/// зацикливается, так что рингтон по-прежнему два вызова: звучит до того, как
/// поднимется тракт разговора, и замолкает раньше него. Синтезированный цикл
/// остался запасным — на случай, если файла в бандле не окажется.
///
/// Свой `AVAudioEngine`, отдельный от разговорного: у того включён
/// `VoiceProcessingIO`, и любой звук через него уводит AirPods в режим
/// гарнитуры — то есть приглушает всю систему ещё до того, как оператор
/// решил ответить.
///
/// Открытие устройства уведено с главного актора: `AVAudioEngine.start` на
/// капризном драйвере ждёт до секунд, и всё это время окно входящего не
/// отвечало бы. Команды идут в одну последовательную очередь, и ждёт в ней
/// только последняя: «звони» и сразу «замолчи» до того, как очередь до них
/// дошла, — это просто «замолчи», и запоздалое открытие после отмены звонить
/// не начинает.
@MainActor
final class Ringtone {

    /// Что просили последним. Это состояние для интерфейса, а не устройства:
    /// устройство догонит его на своей очереди.
    private(set) var isPlaying = false

    private let player = RingtonePlayer()

    /// Начинает звонить. Повторный вызов ничего не меняет.
    ///
    /// Ошибки не выбрасываются наверх: беззвучный рингтон — досадно, но окно
    /// входящего видно и без него, а звонок ронять из-за звуковой карты нельзя.
    func start(settings: AppSettings.RingtoneSettings, outputDeviceUID: String?) {
        guard settings.isEnabled, !isPlaying else { return }
        isPlaying = true
        player.request(.start(settings: settings, outputDeviceUID: outputDeviceUID))
    }

    func stop() {
        guard isPlaying else { return }
        isPlaying = false
        player.request(.stop)
    }

    /// Годится ли файл в рингтоны — до того, как его записали в настройки.
    static func isPlayable(url: URL) -> Bool {
        RingtonePlayer.makeFileBuffer(url: url) != nil
    }

    static var defaultSoundURL: URL? { RingtonePlayer.defaultSoundURL }
    static var supportedFileExtensions: [String] { RingtonePlayer.supportedFileExtensions }
}

/// Устройство рингтона. Живёт на своей очереди целиком.
private final class RingtonePlayer: @unchecked Sendable {

    enum Command: Sendable {
        case start(settings: AppSettings.RingtoneSettings, outputDeviceUID: String?)
        case stop
    }

    /// Цикл: два коротких тона и пауза. Пауза длинная намеренно — рингтон
    /// звучит на фоне работы в CRM, и непрерывная трель мешает думать.
    private static let toneDuration = 0.4
    private static let gapDuration = 0.2
    private static let silenceDuration = 2.0

    /// Две гармоники вместо одной: чистая синусоида на колонках ноутбука
    /// звучит как неисправность, а не как звонок.
    private static let partials: [(frequency: Double, amplitude: Double)] = [
        (587.33, 0.6),  // ре пятой октавы
        (880.00, 0.4),  // ля пятой октавы
    ]

    private let queue = DispatchQueue(label: "com.elite.EliteSIP.ringtone", qos: .userInitiated)

    /// Ожидающая команда — одна, последняя. `isDraining` — очередь уже идёт.
    private let pending = UnfairLock<(command: Command?, isDraining: Bool)>(initialState: (nil, false))

    // Только на `queue`.
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?

    func request(_ command: Command) {
        let schedule = pending.withLock { state in
            state.command = command
            defer { state.isDraining = true }
            return !state.isDraining
        }
        if schedule { queue.async { [self] in drain() } }
    }

    private func drain() {
        while true {
            let command: Command? = pending.withLock { state in
                defer { state.command = nil }
                if state.command == nil { state.isDraining = false }
                return state.command
            }
            switch command {
            case nil: return
            case .stop: stop()
            case .start(let settings, let outputDeviceUID):
                start(settings: settings, outputDeviceUID: outputDeviceUID)
            }
        }
    }

    private func start(settings: AppSettings.RingtoneSettings, outputDeviceUID: String?) {
        guard engine == nil else { return }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()

        // Устройство выбирается до того, как граф собран: смена устройства на
        // запущенном движке требует полной пересборки (см. audio.md).
        if !settings.usesSystemOutput,
           let uid = outputDeviceUID,
           let device = AudioDeviceCatalog.device(uid: uid) {
            try? engine.outputNode.auAudioUnit.setDeviceID(device.id)
        }

        // Свой файл, если он задан и на месте; иначе стандартный из бандла;
        // иначе синтезированный цикл.
        // Порядок именно такой: замена рингтона — настройка рабочего места, и
        // молчаливый откат к стандартному звонку лучше, чем тишина из-за
        // переименованного файла.
        let buffer: AVAudioPCMBuffer
        if let url = settings.customSoundURL, let fileBuffer = Self.makeFileBuffer(url: url) {
            buffer = fileBuffer
        } else if let url = Self.defaultSoundURL, let fileBuffer = Self.makeFileBuffer(url: url) {
            buffer = fileBuffer
        } else {
            let format = engine.outputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, let cycle = Self.makeCycleBuffer(format: format) else { return }
            buffer = cycle
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
        engine.mainMixerNode.outputVolume = Float(min(max(settings.volume, 0), 1))

        do {
            try engine.start()
        } catch {
            return
        }

        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()

        self.engine = engine
        self.player = player
    }

    private func stop() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
    }

    /// Стандартный звонок из бандла.
    static let defaultSoundURL = Bundle.main.url(forResource: "ringtone", withExtension: "wav")

    /// Расширения, которые принимает выбор своего файла. OGG (Vorbis и Opus)
    /// читает сам Core Audio — свой декодер не нужен; на старой системе, где
    /// не прочтёт, файл отсеет `isPlayable`.
    static let supportedFileExtensions = ["mp3", "wav", "ogg", "oga", "opus", "m4a", "aiff", "aif", "caf"]

    /// Файл рингтона целиком в буфер.
    ///
    /// Целиком, а не потоком с диска: буфер зацикливается одним планированием,
    /// и никакое чтение файла не встаёт между «пришёл вызов» и «зазвонило».
    /// Длинный файл этим и ограничен — и это ограничение по делу: рингтон на
    /// минуту в оперативной памяти держать незачем, звонки принимают за секунды.
    static func makeFileBuffer(url: URL) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)
        else { return nil }
        do {
            try file.read(into: buffer)
        } catch {
            return nil
        }
        return buffer
    }

    /// Один полный цикл звонка одним буфером.
    ///
    /// Целиком, а не по кусочкам с планировщиком: зацикленный буфер играет
    /// ровно, а цепочка запланированных отрезков рано или поздно даёт щелчок
    /// на стыке.
    private static func makeCycleBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let cycle = Self.toneDuration * 2 + Self.gapDuration + Self.silenceDuration
        let frameCount = AVAudioFrameCount(cycle * sampleRate)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channels = buffer.floatChannelData
        else { return nil }

        buffer.frameLength = frameCount

        let toneFrames = Int(Self.toneDuration * sampleRate)
        let gapFrames = Int(Self.gapDuration * sampleRate)
        // Скос по краям тона: обрыв синусоиды на ненулевой фазе слышен как
        // щелчок, и на цикле в две секунды он раздражает сильнее самого звонка.
        let fadeFrames = max(1, Int(0.012 * sampleRate))

        for frame in 0..<Int(frameCount) {
            let positionInTone: Int?
            switch frame {
            case 0..<toneFrames:
                positionInTone = frame
            case (toneFrames + gapFrames)..<(toneFrames * 2 + gapFrames):
                positionInTone = frame - toneFrames - gapFrames
            default:
                positionInTone = nil
            }

            var value = 0.0
            if let positionInTone {
                let time = Double(positionInTone) / sampleRate
                for partial in Self.partials {
                    value += partial.amplitude * sin(2 * .pi * partial.frequency * time)
                }

                let fadeIn = min(1.0, Double(positionInTone) / Double(fadeFrames))
                let fadeOut = min(1.0, Double(toneFrames - positionInTone) / Double(fadeFrames))
                value *= fadeIn * fadeOut * 0.5
            }

            for channel in 0..<Int(format.channelCount) {
                channels[channel][frame] = Float(value)
            }
        }

        return buffer
    }
}
