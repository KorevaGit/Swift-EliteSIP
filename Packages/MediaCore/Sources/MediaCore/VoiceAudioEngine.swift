import Compat
import AVFoundation
import CoreAudio
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
/// Три вещи, которые в этом классе выглядят избыточными, но каждая закрывает
/// замеренную на живой машине неприятность (подробности — `docs/audio.md`):
///
/// 1. **Такт воспроизведения берётся от рендера, а не от таймера.** Поток
///    рендера просит ровно один кадр пакетного времени и делает это с точностью
///    кварца звуковой карты. Таймер на 20 мс — нет, и за длинный разговор
///    расхождение накапливается.
/// 2. **Перестройка графа по `AVAudioEngineConfigurationChange`.** Подключение
///    наушников на ходу меняет частоты входа и выхода. Уведомление приходит
///    пачкой, поэтому оно ещё и склеивается по времени.
/// 3. **Явное выключение обработки голоса при остановке.** `engine.stop()`
///    Bluetooth-гарнитуру не отпускает — замерено: AirPods остаются в режиме
///    двусторонней связи бесконечно. Отпускает именно выключение VPIO.
///
/// Класс помечен `@unchecked Sendable`: изменяемое состояние либо живёт под
/// замком, либо трогается только на одном потоке. Где именно — отмечено по месту.
public final class VoiceAudioEngine: @unchecked Sendable {

    public struct Configuration: Sendable {
        public var codec: AudioCodec
        public var packetTimeMilliseconds: Int
        /// Глубина кольца воспроизведения в кадрах. Защита от роста задержки,
        /// если сеть отдаёт быстрее, чем звуковая карта успевает играть.
        public var maximumPlaybackFrames: Int
        /// Сколько кадров держать наготове перед потоком рендера. Два — это
        /// 40 мс: хватает пережить неровный вызов рендера и не добавляет
        /// заметной задержки поверх джиттер-буфера.
        public var targetPlaybackFrames: Int
        /// Микрофон (`AudioDevice.uid`). nil — системный по умолчанию.
        public var inputDeviceUID: String?
        /// Наушники (`AudioDevice.uid`). nil — системные по умолчанию.
        ///
        /// Если вход и выход заданы разными устройствами, движок соберёт
        /// приватное агрегатное устройство: `AVAudioEngine` на macOS держит один
        /// общий AUHAL на оба направления (проверено —
        /// `inputNode.auAudioUnit === outputNode.auAudioUnit`), и без агрегата
        /// развести их нельзя. Ровно так же поступает и сама система, когда
        /// умолчания разные.
        public var outputDeviceUID: String?
        /// Отпускать звуковое устройство при остановке.
        ///
        /// Ради AirPods: иначе они висят в режиме гарнитуры между звонками, и
        /// у всей системы приглушён звук. В прежней версии это называлось
        /// `RELEASE_AUDIO_DEVICE_WHEN_IDLE`.
        public var releasesDeviceWhenIdle: Bool
        /// Автоматическая регулировка усиления в блоке обработки голоса.
        ///
        /// Система включает её сама, поэтому по умолчанию здесь стоит `false`:
        /// продуктовое решение — выключено, включение остаётся пользовательской
        /// или административной опцией. На встроенном микрофоне AGC полезна, на
        /// хорошей гарнитуре — «дышит»: подтягивает шум в паузах и приседает на
        /// громком слоге. Эхоподавление и шумодав от неё не зависят.
        public var automaticGainControl: Bool

        public init(
            codec: AudioCodec = .pcmu,
            packetTimeMilliseconds: Int = defaultPacketTimeMilliseconds,
            maximumPlaybackFrames: Int = 25,
            targetPlaybackFrames: Int = 2,
            inputDeviceUID: String? = nil,
            outputDeviceUID: String? = nil,
            releasesDeviceWhenIdle: Bool = true,
            automaticGainControl: Bool = false
        ) {
            self.codec = codec
            self.packetTimeMilliseconds = packetTimeMilliseconds
            self.maximumPlaybackFrames = maximumPlaybackFrames
            self.targetPlaybackFrames = targetPlaybackFrames
            self.inputDeviceUID = inputDeviceUID
            self.outputDeviceUID = outputDeviceUID
            self.releasesDeviceWhenIdle = releasesDeviceWhenIdle
            self.automaticGainControl = automaticGainControl
        }

        public var samplesPerFrame: Int {
            codec.sampleCount(forPacketTime: packetTimeMilliseconds)
        }
    }

    public enum AudioError: Error, Sendable, LocalizedError {
        case microphoneDenied
        case formatUnavailable
        case voiceProcessingUnavailable(String)
        case deviceUnavailable(uid: String)
        /// Шаг указывается всегда: сообщение CoreAudio вида «error -10875» само
        /// по себе не говорит, какой из форматов не подошёл, и без шага
        /// приходится гадать.
        case engineFailed(step: String, reason: String)

        public var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                "Нет доступа к микрофону. Разрешите его в «Системных настройках → Конфиденциальность»."
            case .formatUnavailable:
                "Не удалось построить формат звука 8 кГц."
            case .voiceProcessingUnavailable(let reason):
                "Системное эхоподавление недоступно: \(reason)"
            case .deviceUnavailable(let uid):
                "Выбранное звуковое устройство недоступно (\(uid))."
            case .engineFailed(let step, let reason):
                "Звуковой движок не запустился на шаге «\(step)»: \(reason)"
            }
        }
    }

    /// Что случилось с трактом. Отдельно от диагностики: диагностика — текст
    /// для журнала, а на это приложению надо реагировать.
    public enum Event: Sendable {
        /// Граф пересобран после смены конфигурации звука.
        case restarted(reason: String)
        /// Пересобрать не удалось — звука больше нет.
        case broken(reason: String)
        /// Маршрут изменился: другое устройство или другой режим.
        case routeChanged(AudioRoute)
    }

    /// Куда писать подробности о форматах. Без них разбирать отказы CoreAudio
    /// невозможно: он сообщает номер ошибки, но не то, что именно не сошлось.
    public var onDiagnostic: (@Sendable (String) -> Void)?

    /// События тракта. Вызывается на служебной очереди, не на потоке звука.
    public var onEvent: (@Sendable (Event) -> Void)?

    /// Кодированный кадр с микрофона, готовый к отправке в RTP.
    /// Вызывается на потоке звукового ввода — не блокировать.
    public var onEncodedFrame: (@Sendable (Data) -> Void)?

    /// Кадр для воспроизведения вместе с признаком, настоящий он или спрятанный.
    public struct PlaybackFrame: Sendable {
        public var payload: Data
        /// Кадр не пришёл и подставлен взамен. Воспроизведение накладывает на
        /// такой затухание, чтобы повтор не звучал заевшей пластинкой.
        public var isConcealment: Bool

        public init(payload: Data, isConcealment: Bool) {
            self.payload = payload
            self.isConcealment = isConcealment
        }
    }

    /// Распакованные отсчёты того, что мы услышали.
    ///
    /// Диагностический: нужен, чтобы можно было ответить на вопрос «а что
    /// именно приехало», не полагаясь на уши. Без него проверить чужой кодер
    /// нечем — совпадения счётчиков пакетов для этого мало. Вызывается на
    /// потоке подачи, поэтому обработчик обязан быть быстрым.
    public var onDecodedSamples: (@Sendable ([Int16]) -> Void)?

    /// Запрос очередного кадра для воспроизведения.
    ///
    /// Пул, а не толчок: спрашивает подающий поток ровно в том темпе, в каком
    /// звуковая карта забирает отсчёты. Возврат nil означает «нечего играть» —
    /// подающий поток на этом успокаивается до следующего запроса.
    /// Вызывается на выделенном потоке подачи, не на потоке рендера.
    public var onNeedsFrame: (@Sendable () -> PlaybackFrame?)?

    private let configuration: Configuration
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?

    /// Формат разговора: частота кодека, моно. У G.711 это 8 кГц, у G.722 —
    /// 16 кГц. Всё остальное движок пересчитывает сам.
    private let conversationFormat: AVAudioFormat

    /// Очередь, на которой происходят запуск, остановка и перестройка графа.
    /// Последовательная: пересборка и остановка не должны наложиться.
    private let control = DispatchQueue(label: "com.elite.EliteSIP.audio-control")

    // MARK: - Состояние захвата
    // `converter`, `captureRemainder` и форматы трогает только поток
    // кодирования. Кольцо делят поток реального времени и он же — под замком.

    private var converter: AVAudioConverter?
    private var captureRemainder: [Int16] = []
    private var captureConversionFormats: (source: AVAudioFormat, destination: AVAudioFormat)?
    private var sinkNode: AVAudioSinkNode?

    /// Своё агрегатное устройство, если микрофон и наушники разные. Живёт ровно
    /// столько, сколько граф: пока оно существует, оба подчинённых устройства
    /// остаются открытыми, а Bluetooth-гарнитура — в режиме связи.
    private var aggregate: AggregateAudioDevice?

    private let captureLock: UnfairLock<CaptureState>

    private struct CaptureState {
        var ring: SampleRing
        /// Буфер под выборку канала 0 из чересполосного блока. Заведён заранее,
        /// потому что в потоке реального времени выделять память нельзя.
        var scratch: [Float]
        var capturedSamples = 0
    }

    /// Сколько кадров подряд уже спрятано. Живёт только на потоке подачи,
    /// поэтому замок не нужен.
    private var concealmentRun = 0

    /// Пиковые уровни в обе стороны.
    ///
    /// Считаются на потоках кодирования и подачи, а не на потоках реального
    /// времени: там и так есть распакованные отсчёты, а лишняя работа в рендере
    /// не нужна. Читаются из интерфейса, отсюда замок.
    private let levelLock = UnfairLock(initialState: LevelState())

    private struct LevelState {
        var inputPeak: Float = 0
        var outputPeak: Float = 0
    }

    /// Кодек с состоянием требует, чтобы кодер и декодер жили весь разговор и
    /// обрабатывали кадры строго подряд. У G.722 предсказатель подстраивается на
    /// каждом отсчёте, и разойтись с собеседником — значит захрипеть.
    ///
    /// Каждый принадлежит своему потоку: декодер — потоку подачи, кодер — потоку
    /// кодирования. Отсюда и отсутствие замков.
    private var decoder: AudioFrameDecoder
    private var encoder: AudioFrameEncoder

    private let captureSignal = DispatchSemaphore(value: 0)
    private var encodeThread: Thread?
    private let isEncoding = UnfairLock(initialState: false)

    // MARK: - Состояние воспроизведения
    // Читается на потоке рендера, пишется подающим потоком — отсюда замок.
    //
    // os_unfair_lock, а не очередь: критическая секция здесь несколько
    // микросекунд, а любое ожидание на потоке рендера слышно как щелчок.

    private let playbackLock: UnfairLock<PlaybackState>

    private struct PlaybackState {
        var ring: SampleRing
        var starvedRenders = 0
        var renderedSamples = 0
    }

    /// Будильник подающего потока. Взводится из рендера — только `signal`,
    /// который не выделяет память и не ждёт.
    private let feedSignal = DispatchSemaphore(value: 0)
    private var feedThread: Thread?
    private let isFeeding = UnfairLock(initialState: false)

    // MARK: - Состояние жизненного цикла
    // Трогается только на `control`, кроме чтения `isRunning`.

    private let runningFlag = UnfairLock(initialState: false)
    public var isRunning: Bool { runningFlag.withLock { $0 } }

    private let mutedFlag = UnfairLock(initialState: false)

    /// Немой микрофон: в линию уходит тишина, но уходит.
    ///
    /// Именно тишина, а не пустота. Перестать отправлять пакеты вовсе — значит
    /// заморозить метку времени и номер пакета на всё время удержания, а потом
    /// вернуться в разговор с разрывом, который собеседник услышит как щелчок.
    /// Заодно живёт привязка в NAT, которая от нескольких минут молчания
    /// вполне может протухнуть.
    ///
    /// Отсчёты обнуляются до кодирования, а не после: у G.722 состояние, и
    /// подменять уже закодированный кадр постоянным «байтом тишины» нельзя —
    /// декодер на той стороне услышит треск (грабли M3).
    public var isMuted: Bool {
        get { mutedFlag.withLock { $0 } }
        set {
            let becameMuted = mutedFlag.withLock { current in
                let changed = !current && newValue
                current = newValue
                return changed
            }

            // На входе в mute выбрасываем ещё не обработанный хвост микрофона.
            // Иначе оператор уже видит mic.slash, а encoder ещё до четверти
            // секунды отправляет то, что лежало в кольце до нажатия.
            if becameMuted {
                captureLock.withLock { $0.ring.removeAll() }
                levelLock.withLock { $0.inputPeak = 0 }
            }
        }
    }

    private var configurationObserver: NSObjectProtocol?
    private var routeObservation: AudioDeviceCatalog.Observation?
    private var usesVoiceProcessing = false
    /// Последний объявленный маршрут — чтобы не сыпать одинаковыми событиями.
    private var lastRoute: AudioRoute?
    /// Склейка пачки уведомлений о смене конфигурации. Подключение AirPods даёт
    /// их несколько подряд, и перестраивать граф на каждое — верный способ
    /// получить гонку с самим собой.
    private var pendingRebuild: DispatchWorkItem?

    public init(configuration: Configuration = Configuration()) throws {
        self.configuration = configuration
        decoder = AudioFrameDecoder(codec: configuration.codec)
        encoder = AudioFrameEncoder(codec: configuration.codec)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(configuration.codec.sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw AudioError.formatUnavailable
        }
        conversationFormat = format
        playbackLock = UnfairLock(initialState: PlaybackState(
            ring: SampleRing(
                capacity: configuration.maximumPlaybackFrames * configuration.samplesPerFrame,
                targetFill: configuration.targetPlaybackFrames * configuration.samplesPerFrame
            )
        ))
        // Полсекунды запаса на стороне захвата, считая по самой высокой частоте
        // устройства, какая встречается (96 кГц). Размер задан здесь и потом не
        // меняется: выделять память на потоке реального времени нельзя, а
        // частота устройства к моменту создания движка ещё неизвестна.
        captureLock = UnfairLock(initialState: CaptureState(
            ring: SampleRing(capacity: 48_000, targetFill: 0),
            scratch: [Float](repeating: 0, count: 16_384)
        ))
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
        try control.sync {
            guard !isRunning else { return }

            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                throw AudioError.microphoneDenied
            }

            do {
                try buildAndStart()
            } catch {
                // Убрать за собой обязательно. Неудачный запуск оставляет граф
                // наполовину собранным, а обработку голоса — включённой, то
                // есть устройство занятым. `stop()` тут уже не поможет: он
                // выходит по `isRunning`, а мы до него не дошли — и AirPods
                // остались бы в режиме гарнитуры после звонка, который даже не
                // состоялся.
                teardownGraph()
                releaseDeviceIfNeeded()
                throw error
            }

            startFeeding()
            startEncoding()
            subscribeToConfigurationChanges()
            subscribeToRouteChanges()
            runningFlag.withLock { $0 = true }
            reportRoute()
        }
    }

    /// Собирает граф и запускает движок. Вызывается на `control`.
    private func buildAndStart() throws {
        // Разные устройства на вход и выход несовместимы с обработкой голоса.
        //
        // Замерено: `kAudioOutputUnitProperty_CurrentDevice` с любым своим
        // агрегатным устройством возвращает -10851
        // (`kAudioUnitErr_InvalidPropertyValue`) при включённом VPIO —
        // и с приватным, и с публичным, и с ведущим устройством, и без него.
        // Своё агрегатное устройство VoiceProcessingIO не принимает; своё
        // собственное (`CADefaultDeviceAggregate`) он строит сам, но только для
        // системных умолчаний.
        //
        // Поэтому здесь не пытаемся и не падаем в откат, а сразу идём без
        // обработки голоса: попытка всё равно кончится тем же, только с
        // тревожным сообщением в журнале и лишней секундой на запуск.
        if needsAggregateDevice {
            onDiagnostic?(
                "микрофон и выход — разные устройства, поэтому без системного эхоподавления"
                    + " (VoiceProcessingIO не принимает агрегатные устройства)"
            )
            try startEngine(withVoiceProcessing: false)
            return
        }

        do {
            try startEngine(withVoiceProcessing: true)
        } catch {
            // Откат без обработки голоса.
            //
            // Разговор без эхоподавления хуже, чем с ним, но несравнимо лучше,
            // чем отсутствие звонка. Плюс это сразу отвечает на вопрос, в чём
            // дело: если без VPIO движок стартует, причина именно в нём.
            onDiagnostic?("с эхоподавлением не вышло (\(error.localizedDescription)), пробую без него")
            teardownGraph()
            try startEngine(withVoiceProcessing: false)
            onDiagnostic?("работаем БЕЗ системного эхоподавления")
        }
    }

    private func startEngine(withVoiceProcessing wantsVoiceProcessing: Bool) throws {
        let input = engine.inputNode
        let output = engine.outputNode

        if wantsVoiceProcessing {
            // Включать надо ДО подключения узлов: VoiceProcessingIO меняет
            // формат входа и выхода, и уже созданные соединения после этого
            // становятся неверными.
            do {
                try input.setVoiceProcessingEnabled(true)
                try output.setVoiceProcessingEnabled(true)
            } catch {
                throw AudioError.voiceProcessingUnavailable(error.localizedDescription)
            }
            // Автоусиление обработка голоса включает сама и не спрашивает. На
            // хорошем микрофоне оно «дышит»: подтягивает шум в паузах и
            // приседает на громком слоге. Эхоподавитель при выключении AGC
            // остаётся — это независимые блоки.
            input.isVoiceProcessingAGCEnabled = configuration.automaticGainControl
            if !configuration.automaticGainControl {
                onDiagnostic?("автоусиление выключено")
            }
        } else {
            try? input.setVoiceProcessingEnabled(false)
            try? output.setVoiceProcessingEnabled(false)
        }
        usesVoiceProcessing = wantsVoiceProcessing

        // Устройство назначается ПОСЛЕ обработки голоса и ДО чтения форматов.
        //
        // Порядок выяснился замером и выглядит противоестественно.
        // `setVoiceProcessingEnabled` пересобирает узел ввода-вывода целиком, а
        // вместе с ним теряет и `kAudioOutputUnitProperty_CurrentDevice`:
        // назначение, сделанное раньше, молча отменяется, и разговор уходит на
        // системное устройство. Симптом коварный — звук есть, просто не тот, что
        // выбрал пользователь.
        //
        // А до чтения форматов потому, что смена устройства их переставляет:
        // всё, что посчитано раньше, устаревает.
        try assignDevice()

        let outputFormat = output.inputFormat(forBus: 0)
        onDiagnostic?("вход: \(Self.describe(input.outputFormat(forBus: 0)))")
        onDiagnostic?("выход: \(Self.describe(outputFormat))")
        onDiagnostic?("микшер: \(Self.describe(engine.mainMixerNode.outputFormat(forBus: 0)))")
        onDiagnostic?("разговор: \(Self.describe(conversationFormat))")

        // Микшер пересоединяем с выходом явно.
        //
        // Обработка голоса переводит выход на свою частоту (в замерах — 24 кГц
        // на AirPods), а соединение микшера с выходом остаётся с прежней
        // (44.1 кГц). Движок на этом расхождении отказывается стартовать
        // с -10875 (kAudioUnitErr_FormatNotSupported), и по номеру ошибки
        // понять, какой из форматов не сошёлся, невозможно.
        if outputFormat.sampleRate > 0 {
            engine.disconnectNodeOutput(engine.mainMixerNode)
            engine.connect(engine.mainMixerNode, to: output, format: outputFormat)
        }

        try startPlayback()
        try startCapture()

        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw AudioError.engineFailed(step: "запуск движка", reason: error.localizedDescription)
        }
    }

    /// Назначает движку выбранное устройство.
    ///
    /// Когда устройство не задано, ничего не делаем: система сама сводит
    /// умолчания — в том числе разные для входа и выхода, через собственное
    /// агрегатное устройство (`CADefaultDeviceAggregate`). Стоит вмешаться —
    /// и эта сборка ложится на нас.
    private func assignDevice() throws {
        guard let target = try resolveDevice() else { return }
        guard let unit = engine.inputNode.audioUnit else {
            throw AudioError.deviceUnavailable(uid: target.uid)
        }

        var id = target.id
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AudioError.engineFailed(
                step: "назначение устройства «\(target.name)»",
                reason: "CoreAudio вернул \(status)"
            )
        }
        onDiagnostic?("устройство: \(target.name)")
    }

    /// Во что превращается выбор пользователя.
    ///
    /// Три случая. Ничего не выбрано — отдаём системе, она сведёт умолчания
    /// сама, в том числе разные. Выбрано одно устройство на обе стороны —
    /// назначаем его напрямую. Выбраны разные — собираем своё агрегатное, как
    /// это делает и macOS.
    private var needsAggregateDevice: Bool {
        AudioDeviceCatalog.needsAggregate(
            inputUID: configuration.inputDeviceUID,
            outputUID: configuration.outputDeviceUID
        )
    }

    private func resolveDevice() throws -> (id: AudioDeviceID, uid: String, name: String)? {
        let inputUID = configuration.inputDeviceUID
        let outputUID = configuration.outputDeviceUID

        if needsAggregateDevice, let inputUID, let outputUID {
            do {
                let aggregate = try AggregateAudioDevice(inputUID: inputUID, outputUID: outputUID)
                self.aggregate = aggregate
                let input = AudioDeviceCatalog.device(uid: inputUID)?.name ?? inputUID
                let output = AudioDeviceCatalog.device(uid: outputUID)?.name ?? outputUID
                onDiagnostic?("агрегатное устройство: микрофон \(input), выход \(output)")
                return (aggregate.id, aggregate.uid, "агрегатное")
            } catch {
                // Отказываться от разговора из-за этого нельзя: пусть звук
                // пойдёт через системные умолчания, но пойдёт.
                onDiagnostic?("агрегатное устройство не собралось (\(error.localizedDescription)), беру системное")
                return nil
            }
        }

        // Одно устройство на обе стороны либо задана только одна сторона.
        guard let uid = inputUID ?? outputUID else { return nil }
        guard let device = AudioDeviceCatalog.device(uid: uid) else {
            // Наушники могли отключить между настройкой и звонком.
            onDiagnostic?("устройство \(uid) недоступно, беру системное по умолчанию")
            return nil
        }
        return (device.id, device.uid, device.summary)
    }

    /// Разбирает граф, чтобы повторная попытка начиналась с чистого состояния.
    /// Вызывается на `control`.
    private func teardownGraph() {
        engine.stop()
        if let sourceNode {
            engine.detach(sourceNode)
            self.sourceNode = nil
        }
        if let sinkNode {
            engine.detach(sinkNode)
            self.sinkNode = nil
        }
        converter = nil
        captureConversionFormats = nil
        captureRemainder.removeAll()

        // Агрегат разбирается вместе с графом: он держит открытыми оба
        // подчинённых устройства, и оставить его — то же самое, что не отпустить
        // гарнитуру.
        aggregate?.destroy()
        aggregate = nil
    }

    /// Заводит кодеки заново.
    ///
    /// Нужно только для G.722 и только там, где поток и так рвётся: между
    /// звонками. Посреди разговора этого делать нельзя — состояние кодера
    /// обязано совпадать с состоянием декодера на той стороне, а он про наш
    /// сброс не узнает.
    private func resetCoders() {
        decoder = AudioFrameDecoder(codec: configuration.codec)
        encoder = AudioFrameEncoder(codec: configuration.codec)
    }

    private static func describe(_ format: AVAudioFormat) -> String {
        let sampleType = switch format.commonFormat {
        case .pcmFormatFloat32: "float32"
        case .pcmFormatInt16: "int16"
        default: "иной"
        }
        return "\(Int(format.sampleRate)) Гц, \(format.channelCount) кан., \(sampleType)"
    }

    // MARK: - Остановка

    public func stop() {
        control.sync {
            guard isRunning else { return }
            runningFlag.withLock { $0 = false }

            pendingRebuild?.cancel()
            pendingRebuild = nil

            if let configurationObserver {
                NotificationCenter.default.removeObserver(configurationObserver)
                self.configurationObserver = nil
            }
            routeObservation = nil

            stopFeeding()
            stopEncoding()
            teardownGraph()
            releaseDeviceIfNeeded()

            resetCoders()
            captureLock.withLock { state in
                state.ring.removeAll()
                state.capturedSamples = 0
            }
            playbackLock.withLock { state in
                state.ring.removeAll()
                state.starvedRenders = 0
                state.renderedSamples = 0
            }
            lastRoute = nil
        }
    }

    /// Отпускает звуковое устройство.
    ///
    /// Замерено на AirPods Pro (macOS 26.5): после `engine.stop()`, снятия
    /// отвода, `detach` и `reset` гарнитура остаётся в режиме двусторонней
    /// связи — устройство вывода так и держит 24 кГц и входные каналы.
    /// Возвращает её обратно на 48 кГц именно выключение обработки голоса: оно
    /// разбирает и заново создаёт узел ввода-вывода, а вместе с ним закрывает
    /// устройство.
    private func releaseDeviceIfNeeded() {
        guard configuration.releasesDeviceWhenIdle, usesVoiceProcessing else { return }
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        try? engine.outputNode.setVoiceProcessingEnabled(false)
        usesVoiceProcessing = false
        onDiagnostic?("устройство отпущено")
    }

    // MARK: - Перестройка при смене конфигурации

    /// Пересобирает тракт на ходу, не роняя разговор.
    ///
    /// Тем же путём, что и автоматическая перестройка после смены устройства,
    /// поэтому и путь один: два разных способа пересобрать граф — это два
    /// разных набора граблей, а слышно их одинаково плохо.
    public func restart(reason: String = "запрошено приложением") {
        scheduleRebuild(reason: reason)
    }

    private func subscribeToConfigurationChanges() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.scheduleRebuild(reason: "конфигурация звука изменилась")
        }
    }

    private func subscribeToRouteChanges() {
        // Смена устройства по умолчанию сама по себе граф не ломает — движок
        // получит своё уведомление. Но пользователю надо сказать, куда ушёл
        // звук, и заметить переход гарнитуры в двусторонний режим.
        routeObservation = AudioDeviceCatalog.observe(queue: control) { [weak self] _ in
            self?.reportRoute()
        }
    }

    /// Откладывает пересборку, склеивая пачку уведомлений в одну.
    ///
    /// Задержка не косметическая: подключение AirPods даёт несколько
    /// уведомлений подряд (появляется агрегатное устройство обработки голоса,
    /// потом меняется частота), и перестройка на каждом успевает столкнуться со
    /// следующим.
    private func scheduleRebuild(reason: String) {
        control.async { [weak self] in
            guard let self, self.isRunning else { return }

            self.pendingRebuild?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.rebuild(reason: reason)
            }
            self.pendingRebuild = work
            self.control.asyncAfter(deadline: .now() + .milliseconds(300), execute: work)
        }
    }

    /// Собирает граф заново на новых форматах. Вызывается на `control`.
    private func rebuild(reason: String) {
        guard isRunning else { return }
        pendingRebuild = nil

        onDiagnostic?("пересобираю тракт: \(reason)")
        teardownGraph()

        // Кольцо воспроизведения не трогаем: формат разговора не изменился,
        // накопленное в нём — обычный звук, и выбрасывать его значит добавить
        // слышимую дыру там, где её могло не быть.
        do {
            try buildAndStart()
            onEvent?(.restarted(reason: reason))
            onDiagnostic?("тракт пересобран")
            reportRoute()
        } catch {
            runningFlag.withLock { $0 = false }
            stopFeeding()
            stopEncoding()
            teardownGraph()
            releaseDeviceIfNeeded()
            onEvent?(.broken(reason: error.localizedDescription))
            onDiagnostic?("пересобрать тракт не удалось: \(error.localizedDescription)")
        }
    }

    private func reportRoute() {
        let route = self.route
        guard route != lastRoute else { return }
        lastRoute = route
        onDiagnostic?("маршрут: \(route.summary)")
        onEvent?(.routeChanged(route))
    }

    // MARK: - Воспроизведение

    private func startPlayback() throws {
        let node = AVAudioSourceNode(format: conversationFormat) {
            [playbackLock, feedSignal] _, _, frameCount, audioBufferList in

            let requested = Int(frameCount)

            // Список буферов принадлежит вызывающему и живёт ровно до возврата
            // из этого блока. `nonisolated(unsafe)` говорит это компилятору:
            // проверять здесь нечего, гонки нет по построению.
            nonisolated(unsafe) let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)

            playbackLock.withLock { state in
                var served = 0
                for buffer in buffers {
                    guard let pointer = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    // Каналов у нашего формата один, но цикл честный: если
                    // формат когда-нибудь станет стерео, тишина в правом канале
                    // — ошибка, которую по звуку почти не слышно.
                    served = state.ring.read(into: pointer, requested: requested)
                }
                if served < requested {
                    state.starvedRenders += 1
                }
                state.renderedSamples += requested
            }

            // Будим подающий поток. `signal` не выделяет память и не ждёт —
            // единственная разрешённая здесь форма общения с остальным миром.
            feedSignal.signal()
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: conversationFormat)
        sourceNode = node
    }

    // MARK: - Подача кадров

    /// Поток, который декодирует кадры по запросу рендера.
    ///
    /// Отдельный поток, а не очередь GCD: он должен просыпаться каждые 20 мс с
    /// предсказуемой задержкой, а очередь общего назначения такого не обещает.
    /// Приоритет — как у звука, но не realtime: тяжёлого здесь ничего нет.
    private func startFeeding() {
        isFeeding.withLock { $0 = true }

        let thread = Thread { [weak self] in
            while true {
                guard let self else { return }
                self.feedSignal.wait()
                guard self.isFeeding.withLock({ $0 }) else { return }
                self.fillRing()
            }
        }
        thread.name = "com.elite.EliteSIP.audio-feed"
        thread.qualityOfService = .userInteractive
        thread.start()
        feedThread = thread
    }

    private func stopFeeding() {
        isFeeding.withLock { $0 = false }
        // Будим поток, чтобы он увидел флаг и вышел, иначе он навсегда останется
        // висеть на семафоре.
        feedSignal.signal()
        feedThread = nil
        concealmentRun = 0
    }

    /// Добирает кольцо до целевого запаса. Всё тяжёлое — декодирование и
    /// выделение памяти — происходит здесь, вне потока рендера.
    private func fillRing() {
        let samplesPerFrame = configuration.samplesPerFrame

        while isFeeding.withLock({ $0 }) {
            let needed = playbackLock.withLock { state in
                min(state.ring.deficit, state.ring.freeSpace)
            }
            guard needed >= samplesPerFrame else { return }

            guard let frame = onNeedsFrame?() else { return }

            let samples = decoder.decode(frame.payload)
            onDecodedSamples?(samples)
            var floats = samples.map { Float($0) / 32768.0 }

            // Спрятанный кадр — повтор предыдущего. Повторять его в полную
            // громкость нельзя: два-три подряд начинают звучать как дребезг.
            // Затухание по 0,6 за кадр уводит повтор в тишину примерно за
            // 100 мс, ровно к тому моменту, когда буфер сдаётся и сам.
            //
            // Множитель меняется линейно ВНУТРИ кадра, а не скачком на границе:
            // ступенька по громкости — это щелчок, который слышно лучше, чем
            // саму потерю.
            if frame.isConcealment {
                concealmentRun += 1
                let from = pow(0.6, Float(concealmentRun - 1))
                let to = pow(0.6, Float(concealmentRun))
                let count = Float(max(floats.count - 1, 1))
                for index in floats.indices {
                    floats[index] *= from + (to - from) * Float(index) / count
                }
            } else {
                concealmentRun = 0
            }

            let ready = floats
            let peak = ready.reduce(Float(0)) { max($0, abs($1)) }
            levelLock.withLock { $0.outputPeak = max($0.outputPeak, peak) }

            playbackLock.withLock { state in
                _ = state.ring.write(ready)
            }
        }
    }

    // MARK: - Захват

    /// Ставит узел приёмника вместо отвода микрофона.
    ///
    /// `installTap` отдаёт блоки **ровно по 100 мс** на любом устройстве, и
    /// запрошенный размер буфера на это не влияет: замерено на 160, 480, 2048 и
    /// 4800 кадрах — всегда 4800 кадров на 48 кГц. Сто миллисекунд в одну
    /// сторону при норме G.114 в сто пятьдесят на весь путь — непозволительная
    /// роскошь, да ещё и RTP уходил пачками по пять пакетов.
    ///
    /// `AVAudioSinkNode` вызывается каждый цикл ввода-вывода и отдаёт блок
    /// размером с буфер устройства — замерено 512 кадров, то есть 10,67 мс.
    ///
    /// Плата за это — блок вызывается на потоке реального времени, в отличие от
    /// отвода. Поэтому здесь только копирование в кольцо и `signal`, а пересчёт,
    /// кодирование и отправка живут на своём потоке. Ровно так же устроено
    /// воспроизведение, и это не совпадение: правило одно и то же.
    private func startCapture() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioError.engineFailed(
                step: "чтение формата входа",
                reason: "устройство ввода не отдало формат — вероятно, микрофон занят"
            )
        }

        // Конвертер собирается из МОНО-формата устройства, а не из того, что
        // отдаёт вход.
        //
        // Обработка голоса делает вход многоканальным: замерено три канала на
        // AirPods и пять на встроенном микрофоне. Лишние — опорные дорожки
        // эхоподавителя, то есть то, что сейчас играет в наушниках; свести их с
        // микрофоном значит отправить собеседнику его собственный голос. Раньше
        // это решалось `converter.channelMap = [0]`, теперь канал 0 берётся
        // прямо в приёмнике, и конвертеру достаётся честное моно.
        guard let monoInputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ), let captureFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(configuration.codec.sampleRate),
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: monoInputFormat, to: captureFormat) else {
            throw AudioError.formatUnavailable
        }

        // Качество пересчёта — не косметика, а главный источник грязи в голосе.
        //
        // По умолчанию `AVAudioConverter` ставит `.medium`, и при переходе с
        // 48 кГц на 8 кГц его фильтр давит зазеркалье всего на 15 дБ: тон 5 кГц
        // возвращается в полосу как 3 кГц с уровнем −14,9 дБ. В речи выше 4 кГц
        // живут шипящие, и на слух это «жестяной», подсвистывающий голос. Заодно
        // `.medium` съедает полосу: −3,7 дБ уже на 3 кГц, то есть ровно там, где
        // различаются согласные.
        //
        // Замер (`audioprobe quality`), тон 5 кГц → зеркало 3 кГц:
        //
        //     вход      medium      max
        //     24 кГц    −31,1 дБ    −234 дБ
        //     44,1 кГц  −16,9 дБ    −64,3 дБ
        //     48 кГц    −14,9 дБ    −52,3 дБ
        //
        // Стоит это 7 мкс на блок вместо 4 — при бюджете блока в 100 мс цена
        // неизмеримо мала. Ставить нужно ДО первого `convert`: потом настройка
        // не подхватится.
        converter.sampleRateConverterQuality = Int(AVAudioQuality.max.rawValue)
        self.converter = converter
        captureConversionFormats = (source: monoInputFormat, destination: captureFormat)

        if inputFormat.channelCount > 1 {
            onDiagnostic?("вход многоканальный (\(inputFormat.channelCount)), беру канал 0")
        }

        let node = AVAudioSinkNode {
            [captureLock, captureSignal, mutedFlag] _, frameCount, audioBufferList in
            // Приёмнику список приходит константным, а обёртка для перебора
            // есть только изменяемая. Мы из него только читаем.
            nonisolated(unsafe) let buffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: audioBufferList)
            )
            guard let first = buffers.first, let raw = first.mData else { return noErr }

            nonisolated(unsafe) let samples = raw.assumingMemoryBound(to: Float.self)
            let count = Int(frameCount)
            let isMuted = mutedFlag.withLock { $0 }
            // Чересполосный буфер отдаёт все каналы одним куском, раздельный —
            // каждый своим. Нам в обоих случаях нужен канал 0, и различаются
            // они только шагом между его отсчётами.
            let stride = Int(first.mNumberChannels)

            captureLock.withLock { state in
                if isMuted {
                    // Глушим в момент захвата, а не при позднем чтении кольца.
                    // Тогда короткий mute/unmute не выпустит записанный в паузе
                    // голос после того, как кнопка уже снова включена.
                    let usable = min(count, state.scratch.count)
                    state.scratch.withUnsafeMutableBufferPointer { destination in
                        for index in 0..<usable {
                            destination[index] = 0
                        }
                        state.ring.write(destination.baseAddress!, count: usable)
                    }
                } else if stride == 1 {
                    state.ring.write(samples, count: count)
                } else {
                    // Расчёску приходится собирать поэлементно, зато буфер под
                    // неё выделен один раз при запуске.
                    let usable = min(count, state.scratch.count)
                    state.scratch.withUnsafeMutableBufferPointer { destination in
                        for index in 0..<usable {
                            destination[index] = samples[index * stride]
                        }
                        state.ring.write(destination.baseAddress!, count: usable)
                    }
                }
                state.capturedSamples += count
            }

            captureSignal.signal()
            return noErr
        }

        engine.attach(node)
        engine.connect(input, to: node, format: inputFormat)
        sinkNode = node
    }

    /// Поток кодирования: забирает накопленное микрофоном, пересчитывает и режет
    /// на кадры пакетного времени.
    private func startEncoding() {
        isEncoding.withLock { $0 = true }

        let thread = Thread { [weak self] in
            while true {
                guard let self else { return }
                self.captureSignal.wait()
                guard self.isEncoding.withLock({ $0 }) else { return }
                self.encodePendingCapture()
            }
        }
        thread.name = "com.elite.EliteSIP.audio-encode"
        thread.qualityOfService = .userInteractive
        thread.start()
        encodeThread = thread
    }

    private func stopEncoding() {
        isEncoding.withLock { $0 = false }
        captureSignal.signal()
        encodeThread = nil
    }

    private func encodePendingCapture() {
        guard let converter, let formats = captureConversionFormats else { return }

        // Не больше четверти секунды за раз: если поток кодирования проспал,
        // выгребать всё разом значит отправить в сеть пачку пакетов, ради
        // избавления от которой всё и затевалось.
        let maximumSamples = Int(formats.source.sampleRate / 4)
        let captured = captureLock.withLock { state in
            state.ring.drain(maximum: maximumSamples)
        }
        guard !captured.isEmpty else { return }

        guard let converted = Self.resample(
            captured, using: converter, from: formats.source, to: formats.destination
        ) else { return }

        // Индикатор микрофона на удержании обязан лежать на нуле: показывать
        // уровень голоса, который никуда не уходит, — это ровно тот случай,
        // когда оператор говорит в пустоту и уверен, что его слышат.
        let isMuted = mutedFlag.withLock { $0 }
        let peak = isMuted ? 0 : converted.reduce(Float(0)) { max($0, abs(Float($1) / 32768)) }
        levelLock.withLock { $0.inputPeak = max($0.inputPeak, peak) }

        // В кольце уже лежат нули для всего, что было записано во время mute.
        // Повторная проверка ниже нужна для переключения посреди этой пачки:
        // решение принимается перед каждым 20-мс кадром, а не раз в 250 мс.
        captureRemainder.append(contentsOf: converted)

        // Режем на кадры ровно по packet time: RTP не терпит кусков
        // произвольной длины, а остаток переносим в следующий заход.
        let samplesPerFrame = configuration.samplesPerFrame
        var offset = 0
        while captureRemainder.count - offset >= samplesPerFrame {
            let capturedFrame = Array(captureRemainder[offset..<(offset + samplesPerFrame)])
            offset += samplesPerFrame
            let frame = Self.gateMicrophoneFrame(
                capturedFrame,
                isMuted: mutedFlag.withLock { $0 }
            )
            onEncodedFrame?(encoder.encode(frame))
        }
        // Один сдвиг в конце вместо `removeFirst` на каждом кадре: тот двигает
        // весь хвост заново при каждом вызове.
        if offset > 0 {
            captureRemainder.removeFirst(offset)
        }
    }

    /// Последний, кодек-независимый рубеж mute перед кодированием RTP-кадра.
    ///
    /// `internal` ради регрессионного теста: проверка должна доказывать не только
    /// смену флага, но и отсутствие исходных отсчётов в передаваемом кадре.
    static func gateMicrophoneFrame(
        _ samples: [Int16],
        isMuted: Bool
    ) -> [Int16] {
        isMuted ? [Int16](repeating: 0, count: samples.count) : samples
    }

    /// Пересчитывает моно-отсчёты микрофона в частоту кодека.
    private static func resample(
        _ samples: [Float],
        using converter: AVAudioConverter,
        from source: AVAudioFormat,
        to destination: AVAudioFormat
    ) -> [Int16]? {
        guard let input = AVAudioPCMBuffer(
            pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return nil }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer in
            input.floatChannelData![0].update(from: buffer.baseAddress!, count: samples.count)
        }

        let ratio = destination.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount(Double(samples.count) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: destination, frameCapacity: capacity) else { return nil }

        // Блок конвертера объявлен @Sendable, хотя вызывается синхронно и из
        // того же потока. Коробка выражает это явно вместо захвата var, на
        // который компилятор справедливо ругается.
        let box = ConversionSource(buffer: input)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            // Отдаём буфер ровно один раз: иначе конвертер зациклится, требуя
            // всё новых данных, и вызов никогда не вернётся.
            guard let next = box.take() else {
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

    /// Сколько раз рендеру не хватило отсчётов. Растущее число означает, что
    /// сеть не успевает или джиттер-буфер настроен слишком мелко.
    public var starvedRenderCount: Int {
        playbackLock.withLock { $0.starvedRenders }
    }

    public var queuedPlaybackSamples: Int {
        playbackLock.withLock { $0.ring.available }
    }

    /// Пиковый уровень микрофона с прошлого чтения, от 0 до 1.
    ///
    /// Чтение сбрасывает пик — так ведут себя все стрелочные индикаторы, и
    /// иначе показания залипают на первом громком звуке за разговор.
    public var inputLevel: Float {
        levelLock.withLock { state in
            defer { state.inputPeak = 0 }
            return state.inputPeak
        }
    }

    /// Пиковый уровень принятого звука с прошлого чтения, от 0 до 1.
    public var outputLevel: Float {
        levelLock.withLock { state in
            defer { state.outputPeak = 0 }
            return state.outputPeak
        }
    }

    /// Сколько отсчётов запросила звуковая карта с момента запуска. Это и есть
    /// часы разговора: по ним видно реальную длительность, а не ту, что показал
    /// бы таймер.
    public var renderedSampleCount: Int {
        playbackLock.withLock { $0.renderedSamples }
    }

    /// Куда на самом деле идёт звук.
    ///
    /// Не `AudioRoute.current()`: тот читает системные умолчания, а движок может
    /// работать на выбранном устройстве или на своём агрегатном. Показывать
    /// пользователю системные умолчания, пока разговор идёт через другое
    /// устройство, — прямой путь к жалобе «в настройках одно, слышно другое».
    public var route: AudioRoute {
        let inputUID = configuration.inputDeviceUID
        let outputUID = configuration.outputDeviceUID
        guard inputUID != nil || outputUID != nil else { return .current() }

        return AudioRoute(
            input: inputUID.flatMap(AudioDeviceCatalog.device(uid:)) ?? AudioDeviceCatalog.defaultInput,
            output: outputUID.flatMap(AudioDeviceCatalog.device(uid:)) ?? AudioDeviceCatalog.defaultOutput
        )
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
