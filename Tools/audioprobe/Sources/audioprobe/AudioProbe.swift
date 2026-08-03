import AVFoundation
import CoreAudio
import Foundation
import MediaCore

/// Замеры аудиотракта на живой машине.
///
/// Отвечает на вопросы, которые нельзя закрыть юнит-тестами: что происходит с
/// форматами при включении обработки голоса, что делает система при смене
/// устройства на ходу, во что превращаются AirPods, когда у них открывают
/// микрофон, и с какой точностью тикает поток рендера.
///
///   swift run audioprobe list
///   swift run audioprobe watch
///   swift run audioprobe engine --seconds 30
@main
struct AudioProbe {

    static func main() async {
        let arguments = CommandLine.arguments
        let command = arguments.count > 1 ? arguments[1] : "list"
        let seconds = value(of: "--seconds", in: arguments).flatMap(Double.init) ?? 20

        switch command {
        case "list":
            listDevices()
        case "watch":
            await watchDevices(seconds: seconds)
        case "engine":
            await probeEngine(seconds: seconds, voiceProcessing: !arguments.contains("--no-vpio"))
        case "release":
            await probeRelease()
        case "matrix":
            await MatrixProbe.run(seconds: value(of: "--seconds", in: arguments).flatMap(Double.init) ?? 4)
        case "quality":
            QualityProbe.run(arguments: arguments)
        case "voice":
            await probeVoiceEngine(
                seconds: seconds,
                inputUID: value(of: "--input", in: arguments) ?? value(of: "--device", in: arguments),
                outputUID: value(of: "--output", in: arguments) ?? value(of: "--device", in: arguments),
                rebuilds: arguments.contains("--rebuild")
            )
        default:
            print("""
            Использование: audioprobe <команда> [опции]

              list                     перечислить устройства
              watch [--seconds N]      следить за сменой устройств и частот
              engine [--seconds N]     поднять AVAudioEngine и замерить тракт
                     [--no-vpio]       без системной обработки голоса
              release                  чем именно отпускается Bluetooth-гарнитура
              quality                  качество пересчёта частоты и G.711, без устройства
              matrix [--seconds N]     прогон по всем сочетаниям устройств
              voice  [--seconds N]     боевой VoiceAudioEngine на синтетическом потоке
                     [--device UID]    конкретное устройство вместо системного
                     [--input UID]     микрофон отдельно
                     [--output UID]    выход отдельно (соберётся агрегат)
                     [--rebuild]       разок перестроить тракт на ходу
            """)
            exit(2)
        }
    }

    // MARK: - list

    static func listDevices() {
        let devices = AudioDeviceCatalog.devices()
        let defaultInput = AudioDeviceCatalog.defaultInput
        let defaultOutput = AudioDeviceCatalog.defaultOutput

        print("Устройств: \(devices.count)\n")
        for device in devices.sorted(by: { $0.name < $1.name }) {
            var marks: [String] = []
            if device.uid == defaultInput?.uid { marks.append("вход по умолчанию") }
            if device.uid == defaultOutput?.uid { marks.append("выход по умолчанию") }
            let suffix = marks.isEmpty ? "" : "  ← \(marks.joined(separator: ", "))"
            print("  \(device.summary)\(suffix)")
            print("    uid: \(device.uid)")
        }

        print("\nПо умолчанию:")
        print("  вход:  \(defaultInput?.summary ?? "нет")")
        print("  выход: \(defaultOutput?.summary ?? "нет")")

        let bluetooth = devices.filter { $0.transport == .bluetooth }
        if !bluetooth.isEmpty {
            print("\nBluetooth (при открытии микрофона уходят в режим гарнитуры):")
            for device in bluetooth {
                print("  \(device.summary)")
            }
        }
    }

    // MARK: - watch

    static func watchDevices(seconds: Double) async {
        let stamp = Self.makeStamp()

        print("Слежу \(Int(seconds)) с. Подключайте и отключайте наушники, меняйте устройство в «Звуке».\n")
        printSnapshot(prefix: stamp())

        let watched = AudioDeviceCatalog.devices().map(\.id)
        let observation = AudioDeviceCatalog.observe(sampleRatesOf: watched) { change in
            switch change {
            case .deviceListChanged:
                print("[\(stamp())] состав устройств изменился")
            case .defaultInputChanged:
                print("[\(stamp())] вход по умолчанию → \(AudioDeviceCatalog.defaultInput?.summary ?? "нет")")
            case .defaultOutputChanged:
                print("[\(stamp())] выход по умолчанию → \(AudioDeviceCatalog.defaultOutput?.summary ?? "нет")")
            case .sampleRateChanged(let id):
                let device = AudioDeviceCatalog.device(for: id)
                print("[\(stamp())] частота: \(device?.name ?? "\(id)") → \(Int(device?.sampleRate ?? 0)) Гц")
            }
        }

        try? await Task.sleep(for: .seconds(seconds))
        _ = observation
        print("\nИтог:")
        printSnapshot(prefix: stamp())
    }

    /// Отсчёт от запуска команды. Замыкание, а не функция: его захватывают
    /// слушатели HAL, а они @Sendable.
    static func makeStamp() -> @Sendable () -> String {
        let start = Date()
        return { String(format: "%6.2f", Date().timeIntervalSince(start)) }
    }

    static func printSnapshot(prefix: String) {
        print("[\(prefix)] вход:  \(AudioDeviceCatalog.defaultInput?.summary ?? "нет")")
        print("[\(prefix)] выход: \(AudioDeviceCatalog.defaultOutput?.summary ?? "нет")")
    }

    // MARK: - engine

    /// Поднимает граф, как это делает разговор, и печатает всё, что меняется.
    ///
    /// Смысл в трёх числах: форматы до и после включения обработки голоса,
    /// частота Bluetooth-устройства до и после открытия микрофона, и реальный
    /// шаг вызовов рендера.
    static func probeEngine(seconds: Double, voiceProcessing: Bool) async {
        let stamp = Self.makeStamp()

        guard await requestMicrophone() else {
            print("Нет доступа к микрофону. Разрешите его терминалу в «Конфиденциальности».")
            exit(1)
        }

        print("До запуска:")
        printSnapshot(prefix: stamp())
        let beforeRates = rateSnapshot()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let output = engine.outputNode

        print("\nформаты до обработки голоса:")
        print("  вход:   \(describe(input.outputFormat(forBus: 0)))")
        print("  выход:  \(describe(output.inputFormat(forBus: 0)))")
        print("  микшер: \(describe(engine.mainMixerNode.outputFormat(forBus: 0)))")

        if voiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
                try output.setVoiceProcessingEnabled(true)
                print("\nобработка голоса включена")
            } catch {
                print("\nобработка голоса недоступна: \(error.localizedDescription)")
            }
            print("форматы после:")
            print("  вход:   \(describe(input.outputFormat(forBus: 0)))")
            print("  выход:  \(describe(output.inputFormat(forBus: 0)))")
            print("  микшер: \(describe(engine.mainMixerNode.outputFormat(forBus: 0)))")
        }

        // Тот же граф, что в разговоре: источник 8 кГц → микшер → выход.
        let narrowband = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 8000, channels: 1, interleaved: false
        )!

        let meter = RenderMeter()
        let source = AVAudioSourceNode(format: narrowband) { [meter] _, _, frameCount, audioBufferList in
            meter.record(frames: Int(frameCount))
            for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
                memset(buffer.mData, 0, Int(buffer.mDataByteSize))
            }
            return noErr
        }
        engine.attach(source)

        let outputFormat = output.inputFormat(forBus: 0)
        if outputFormat.sampleRate > 0 {
            engine.disconnectNodeOutput(engine.mainMixerNode)
            engine.connect(engine.mainMixerNode, to: output, format: outputFormat)
        }
        engine.connect(source, to: engine.mainMixerNode, format: narrowband)

        let captureMeter = RenderMeter()
        let inputFormat = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [captureMeter] buffer, _ in
            captureMeter.record(frames: Int(buffer.frameLength))
        }

        // Уведомление о смене конфигурации — главное, ради чего эта команда
        // существует: именно оно приходит, когда наушники подключают на ходу.
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { _ in
            print("""

                [\(stamp())] AVAudioEngineConfigurationChange
                  движок работает: \(engine.isRunning)
                  вход:   \(describe(input.outputFormat(forBus: 0)))
                  выход:  \(describe(output.inputFormat(forBus: 0)))
                  микшер: \(describe(engine.mainMixerNode.outputFormat(forBus: 0)))
                  устройство входа:  \(AudioDeviceCatalog.defaultInput?.summary ?? "нет")
                  устройство выхода: \(AudioDeviceCatalog.defaultOutput?.summary ?? "нет")
                """)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let watched = AudioDeviceCatalog.devices().map(\.id)
        let observation = AudioDeviceCatalog.observe(sampleRatesOf: watched) { change in
            if case .sampleRateChanged(let id) = change, let device = AudioDeviceCatalog.device(for: id) {
                print("[\(stamp())] частота: \(device.name) → \(Int(device.sampleRate)) Гц")
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            print("\nдвижок не стартовал: \(error)")
            exit(1)
        }
        print("\n[\(stamp())] движок запущен\n")

        // Частоты сразу после открытия микрофона: у Bluetooth здесь и виден
        // переход в режим гарнитуры.
        try? await Task.sleep(for: .seconds(2))
        let afterRates = rateSnapshot()
        print("[\(stamp())] изменения частот после открытия микрофона:")
        var moved = false
        for (uid, before) in beforeRates.sorted(by: { $0.key < $1.key }) {
            guard let after = afterRates[uid], after.rate != before.rate else { continue }
            moved = true
            print("  \(before.name): \(Int(before.rate)) → \(Int(after.rate)) Гц")
        }
        if !moved { print("  ни одно устройство частоту не сменило") }
        print("")

        try? await Task.sleep(for: .seconds(seconds))

        engine.stop()
        input.removeTap(onBus: 0)
        _ = observation

        print("\n[\(stamp())] движок остановлен")
        print("рендер:  \(meter.report(expectedRate: 8000))")
        print("захват:  \(captureMeter.report(expectedRate: inputFormat.sampleRate))")

        // Отпустили ли устройство: у Bluetooth частота должна вернуться назад.
        try? await Task.sleep(for: .seconds(3))
        print("\nчерез 3 с после остановки:")
        for (uid, before) in rateSnapshot().sorted(by: { $0.key < $1.key }) {
            guard let original = beforeRates[uid], original.rate != before.rate else { continue }
            print("  \(before.name): \(Int(before.rate)) Гц (было до запуска \(Int(original.rate)))")
        }
        printSnapshot(prefix: stamp())
    }

    // MARK: - release

    /// Ищет, что именно возвращает Bluetooth-гарнитуру из режима связи.
    ///
    /// Вопрос не праздный: `engine.stop()` его не возвращает, а держать AirPods
    /// в режиме гарнитуры между звонками — ровно та жалоба, ради которой в
    /// прежней версии появился `RELEASE_AUDIO_DEVICE_WHEN_IDLE`.
    static func probeRelease() async {
        let stamp = Self.makeStamp()

        guard await requestMicrophone() else {
            print("Нет доступа к микрофону.")
            exit(1)
        }

        func rates(_ label: String) {
            let bluetooth = AudioDeviceCatalog.devices().filter { $0.transport == .bluetooth }
            if bluetooth.isEmpty {
                print("[\(stamp())] \(label): Bluetooth-устройств нет — проверять нечего")
                return
            }
            for device in bluetooth {
                print("[\(stamp())] \(label): \(device.summary)")
            }
        }

        rates("до запуска")

        // Движок в отдельной области видимости: последний шаг проверки — это
        // именно освобождение объекта, и без области его не сделать.
        var engine: AVAudioEngine? = AVAudioEngine()
        do {
            let engine = engine!
            let input = engine.inputNode
            let output = engine.outputNode
            try? input.setVoiceProcessingEnabled(true)
            try? output.setVoiceProcessingEnabled(true)

            let narrowband = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 8000, channels: 1, interleaved: false
            )!
            let source = AVAudioSourceNode(format: narrowband) { _, _, _, audioBufferList in
                for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
                    memset(buffer.mData, 0, Int(buffer.mDataByteSize))
                }
                return noErr
            }
            engine.attach(source)
            let outputFormat = output.inputFormat(forBus: 0)
            if outputFormat.sampleRate > 0 {
                engine.disconnectNodeOutput(engine.mainMixerNode)
                engine.connect(engine.mainMixerNode, to: output, format: outputFormat)
            }
            engine.connect(source, to: engine.mainMixerNode, format: narrowband)
            input.installTap(onBus: 0, bufferSize: 2048, format: input.outputFormat(forBus: 0)) { _, _ in }

            engine.prepare()
            try? engine.start()
            try? await Task.sleep(for: .seconds(3))
            rates("движок работает")

            engine.stop()
            try? await Task.sleep(for: .seconds(3))
            rates("после engine.stop()")

            input.removeTap(onBus: 0)
            engine.detach(source)
            engine.reset()
            try? await Task.sleep(for: .seconds(3))
            rates("после removeTap + detach + reset")

            try? input.setVoiceProcessingEnabled(false)
            try? output.setVoiceProcessingEnabled(false)
            try? await Task.sleep(for: .seconds(3))
            rates("после выключения обработки голоса")
        }

        engine = nil
        try? await Task.sleep(for: .seconds(3))
        rates("после освобождения движка")

        try? await Task.sleep(for: .seconds(5))
        rates("ещё через 5 с")
    }

    // MARK: - voice

    /// Гоняет боевой `VoiceAudioEngine` на синтетическом потоке кадров.
    ///
    /// Проверяет ровно то, чего не видно в юнит-тестах: с каким темпом тракт
    /// на самом деле забирает кадры (то есть не плывёт ли такт), переживает ли
    /// он перестройку на ходу и отпускает ли устройство после остановки.
    static func probeVoiceEngine(
        seconds: Double,
        inputUID: String?,
        outputUID: String?,
        rebuilds: Bool
    ) async {
        let stamp = Self.makeStamp()

        guard await VoiceAudioEngine.requestMicrophoneAccess() else {
            print("Нет доступа к микрофону.")
            exit(1)
        }

        let engine: VoiceAudioEngine
        do {
            engine = try VoiceAudioEngine(configuration: .init(
                inputDeviceUID: inputUID, outputDeviceUID: outputUID
            ))
        } catch {
            print("движок не собрался: \(error.localizedDescription)")
            exit(1)
        }

        let counters = VoiceCounters()

        engine.onDiagnostic = { print("[\(stamp())] звук: \($0)") }
        engine.onEvent = { event in
            switch event {
            case .restarted(let reason): print("[\(stamp())] тракт пересобран: \(reason)")
            case .broken(let reason): print("[\(stamp())] тракт сломан: \(reason)")
            case .routeChanged(let route): print("[\(stamp())] маршрут: \(route.summary)")
            }
        }

        // Источник кадров вместо джиттер-буфера: синус 440 Гц в G.711. Тишина
        // не годится — по ней не отличить работающий тракт от молчащего.
        let tone = ToneSource(codec: .pcmu, samplesPerFrame: 160)
        engine.onNeedsFrame = {
            counters.frameRequested()
            return VoiceAudioEngine.PlaybackFrame(payload: tone.next(), isConcealment: false)
        }
        engine.onEncodedFrame = { frame in counters.captured(bytes: frame.count) }
        // Шаг между кадрами с микрофона — прямая мера задержки захвата: пока
        // стоял installTap, кадры приходили пачками по пять раз в 100 мс.

        let bluetoothBefore = AudioDeviceCatalog.devices().filter { $0.transport == .bluetooth }
        for device in bluetoothBefore { print("[\(stamp())] до запуска: \(device.summary)") }

        do {
            try engine.start()
        } catch {
            print("не запустился: \(error.localizedDescription)")
            exit(1)
        }
        print("[\(stamp())] запущен, режим гарнитуры: \(engine.route.isHeadsetMode ? "да" : "нет")")

        // Замер начинается с первого вызова рендера, а не с возврата из
        // `start()`. Между ними проходит от нуля до восьми десятых секунды —
        // движок ещё поднимает устройство, — и если считать от запуска, эта
        // задержка превращается в «расхождение такта 5%», которого нет.
        while engine.renderedSampleCount == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let startedAt = Date()
        let renderedAtStart = engine.renderedSampleCount
        let requestedAtStart = counters.frames

        if rebuilds {
            try? await Task.sleep(for: .seconds(seconds / 2))
            print("[\(stamp())] прошу перестроить тракт")
            // Тот же путь, которым идёт автоматическая перестройка после
            // подключения наушников. Формат при этом не меняется, зато разбор
            // графа, склейка пачки и повторный запуск проходятся по-настоящему.
            engine.restart(reason: "проверка перестройки")
            try? await Task.sleep(for: .seconds(seconds / 2))
        } else {
            try? await Task.sleep(for: .seconds(seconds))
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        let rendered = engine.renderedSampleCount - renderedAtStart
        let requested = counters.frames - requestedAtStart

        print("")
        print("замер шёл:         \(String(format: "%.2f", elapsed)) с (от первого рендера)")
        print("отсчётов рендера:  \(rendered) → \(String(format: "%.2f", Double(rendered) / 8000)) с звука")
        print("запрошено кадров:  \(requested) → \(String(format: "%.2f", Double(requested) * 0.02)) с звука")
        print("пустых рендеров:   \(engine.starvedRenderCount)")
        print("захвачено кадров:  \(counters.capturedFrames)")
        print("темп отправки:     \(counters.captureGapReport)")
        let drift = elapsed > 0 ? (Double(rendered) / 8000 - elapsed) / elapsed * 100 : 0
        print("расхождение такта: \(String(format: "%+.3f", drift)) %")

        engine.stop()
        print("\n[\(stamp())] остановлен")

        try? await Task.sleep(for: .seconds(3))
        for device in AudioDeviceCatalog.devices().filter({ $0.transport == .bluetooth }) {
            let before = bluetoothBefore.first { $0.uid == device.uid }
            let mark = before?.sampleRate == device.sampleRate ? "вернулось" : "НЕ вернулось"
            print("[\(stamp())] после остановки: \(device.summary) — \(mark)")
        }
    }

    static func rateSnapshot() -> [String: (name: String, rate: Double)] {
        Dictionary(uniqueKeysWithValues: AudioDeviceCatalog.devices().map {
            ($0.uid, (name: $0.name, rate: $0.sampleRate))
        })
    }

    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    static func describe(_ format: AVAudioFormat) -> String {
        "\(Int(format.sampleRate)) Гц, \(format.channelCount) кан."
    }

    static func value(of key: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: key), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

/// Счётчик вызовов рендера: сколько раз позвали, сколько кадров отдали и с
/// каким шагом. По нему видно, можно ли вешать такт воспроизведения на рендер.
///
/// Отсчёт ведётся от первого вызова до последнего, а не от команды запуска:
/// движок стартует не мгновенно, и разница в пару секунд превращается в
/// «расхождение 20%» на ровном месте.
final class RenderMeter: @unchecked Sendable {

    private let lock = NSLock()
    private var calls = 0
    private var frames = 0
    private var firstTime: CFAbsoluteTime?
    private var lastTime: CFAbsoluteTime?
    private var minimumGap = Double.greatestFiniteMagnitude
    private var maximumGap = 0.0
    private var frameCounts: Set<Int> = []

    func record(frames count: Int) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.withLock {
            calls += 1
            frames += count
            frameCounts.insert(count)
            if let last = lastTime {
                let gap = now - last
                minimumGap = min(minimumGap, gap)
                maximumGap = max(maximumGap, gap)
            } else {
                firstTime = now
            }
            lastTime = now
        }
    }

    func report(expectedRate: Double) -> String {
        lock.withLock {
            guard calls > 1, let first = firstTime, let last = lastTime else { return "ни одного вызова" }
            // Первый вызов кадров ещё не «проиграл», поэтому из общего счёта
            // вычитается ровно один блок — иначе получается лишний период.
            let span = last - first
            let played = Double(frames) - Double(frames) / Double(calls)
            let effectiveRate = span > 0 ? played / span : 0
            let drift = expectedRate > 0 ? (effectiveRate - expectedRate) / expectedRate * 100 : 0
            let sizes = frameCounts.sorted().map(String.init).joined(separator: "/")
            return String(
                format: "вызовов %d, кадров %d за %.2f с → %.1f Гц "
                    + "(номинал %.0f, расхождение %+.3f%%), размер блока %@, шаг %.1f–%.1f мс",
                calls, frames, span, effectiveRate, expectedRate, drift, sizes,
                minimumGap * 1000, maximumGap * 1000
            )
        }
    }
}

/// Счётчики боевого прогона. Их трогают потоки звука, поэтому под замком.
final class VoiceCounters: @unchecked Sendable {

    private let lock = NSLock()
    private var requestedFrames = 0
    private var capturedFrameCount = 0
    private var lastCapture: CFAbsoluteTime?
    private var gaps: [Double] = []

    func frameRequested() { lock.withLock { requestedFrames += 1 } }
    func captured(bytes: Int) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.withLock {
            capturedFrameCount += 1
            if let last = lastCapture, now - last > 0.0005 { gaps.append(now - last) }
            lastCapture = now
        }
    }

    /// Как ровно уходят кадры в сеть. Пачками или по одному — видно здесь.
    var captureGapReport: String {
        lock.withLock {
            guard gaps.count > 10 else { return "мало данных" }
            let sorted = gaps.sorted()
            let median = sorted[sorted.count / 2] * 1000
            let p95 = sorted[Int(Double(sorted.count) * 0.95)] * 1000
            let bursts = gaps.filter { $0 < 0.005 }.count
            return String(
                format: "медиана %.1f мс, 95-я доля %.1f мс, вплотную идущих %d из %d",
                median, p95, bursts, gaps.count
            )
        }
    }

    var frames: Int { lock.withLock { requestedFrames } }
    var capturedFrames: Int { lock.withLock { capturedFrameCount } }
}

/// Синус 440 Гц, нарезанный на кадры G.711.
///
/// Заменяет джиттер-буфер в замерах: по тишине не отличить исправный тракт от
/// молчащего, а тон слышно и видно в статистике.
final class ToneSource: @unchecked Sendable {

    private let lock = NSLock()
    private let codec: MediaCore.AudioCodec
    private let samplesPerFrame: Int
    private var phase = 0.0

    init(codec: MediaCore.AudioCodec, samplesPerFrame: Int) {
        self.codec = codec
        self.samplesPerFrame = samplesPerFrame
    }

    func next() -> Data {
        lock.withLock {
            let step = 2 * Double.pi * 440 / 8000
            var samples = [Int16]()
            samples.reserveCapacity(samplesPerFrame)
            for _ in 0..<samplesPerFrame {
                samples.append(Int16(sin(phase) * 8000))
                phase += step
                if phase > 2 * .pi { phase -= 2 * .pi }
            }
            return G711.encode(samples, as: codec)
        }
    }
}
