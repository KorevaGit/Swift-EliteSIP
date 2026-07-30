import AVFoundation
import CoreAudio
import Foundation
import MediaCore

/// Прогон аудиотракта по всем сочетаниям устройств, какие есть на машине.
///
/// Смысл в том, что сочетаний много, а ломаются они по-разному и молча.
/// Устройство может открыться без ошибки и не отдать ни одного отсчёта с
/// микрофона; выход на 96 кГц может не сойтись с форматом разговора; переход
/// на агрегат может обойтись без эхоподавления, о чём стоит знать заранее.
/// Проверять это вручную по одному — час работы и половина сочетаний
/// забудется, поэтому проверка сведена в таблицу.
///
/// Каждый прогон поднимает настоящий `VoiceAudioEngine` с синтетическим
/// потоком кадров и смотрит на три вещи, которые нельзя подделать: сколько
/// отсчётов запросила звуковая карта, сколько кадров пришло с микрофона и
/// вернулось ли устройство в исходный режим после остановки.
enum MatrixProbe {

    struct Outcome {
        var input: String
        var output: String
        var started = false
        var voiceProcessing = false
        var aggregate = false
        var headsetMode = false
        var inputFormat = ""
        var outputFormat = ""
        var renderedSeconds = 0.0
        var capturedFrames = 0
        var starvedRenders = 0
        var released = true
        /// Не заработало с первого раза, но заработало со второго.
        var neededRetry = false
        var failure: String?

        /// Сочетание считается рабочим, только если звук пошёл в обе стороны.
        /// Запуск без ошибки — ещё не работа: молчащий микрофон выглядит точно
        /// так же, как исправный, пока не посчитаешь кадры.
        var isWorking: Bool {
            started && failure == nil && renderedSeconds > 0.5 && capturedFrames > 20
        }

        var verdict: String {
            if let failure { return "✖ \(failure)" }
            if !started { return "✖ не запустился" }
            if renderedSeconds <= 0.5 { return "✖ воспроизведение не пошло" }
            if capturedFrames <= 20 { return "✖ микрофон молчит (\(capturedFrames) кадр.)" }
            return neededRetry ? "✓ со 2-й" : "✓"
        }
    }

    static func run(seconds: Double) async {
        guard await VoiceAudioEngine.requestMicrophoneAccess() else {
            print("Нет доступа к микрофону. Разрешите его терминалу в «Конфиденциальности».")
            exit(1)
        }

        let devices = AudioDeviceCatalog.devices()
        let inputs = devices.filter(\.isInput).sorted { $0.name < $1.name }
        let outputs = devices.filter(\.isOutput).sorted { $0.name < $1.name }

        print("Входов \(inputs.count), выходов \(outputs.count). На каждое сочетание \(Int(seconds)) с.\n")

        var results: [Outcome] = []

        // Сначала системное по умолчанию: это то, с чем поедет большинство, и
        // единственный режим, где сведением разных устройств занимается macOS.
        results.append(await probe(
            inputUID: nil, outputUID: nil,
            inputName: "системный", outputName: "системный",
            seconds: seconds
        ))

        for input in inputs {
            for output in outputs {
                var outcome = await probe(
                    inputUID: input.uid, outputUID: output.uid,
                    inputName: input.name, outputName: output.name,
                    seconds: seconds
                )

                // Один повтор с паузой, и это не подгонка результата.
                //
                // Прогон подряд нагружает CoreAudio так, как настоящее
                // приложение не делает никогда: агрегатные устройства
                // создаются и разбираются каждые несколько секунд, Bluetooth не
                // успевает выйти из режима гарнитуры. Проверено — сочетания,
                // молчавшие в таблице, поодиночке работают безупречно. Без
                // повтора таблица врёт в сторону поломок, а это хуже, чем
                // ничего: за настоящей бедой её перестанут замечать.
                if !outcome.isWorking {
                    // Bluetooth выходит из режима гарнитуры единицы секунд, и
                    // всё это время устройство отдаёт то, что успело. Четырёх
                    // секунд ему мало — проверено, сочетания с AirPods падали и
                    // на повторе, а поодиночке работали безупречно.
                    let settling = involvesBluetooth(input, output) ? 10.0 : 4.0
                    try? await Task.sleep(for: .seconds(settling))
                    var retried = await probe(
                        inputUID: input.uid, outputUID: output.uid,
                        inputName: input.name, outputName: output.name,
                        seconds: seconds
                    )
                    retried.neededRetry = retried.isWorking
                    outcome = retried
                }
                results.append(outcome)
            }
        }

        report(results, devices: devices)
    }

    /// Один прогон. Всё, что может пойти не так, ловится и попадает в таблицу,
    /// а не роняет остальные сочетания.
    private static func probe(
        inputUID: String?,
        outputUID: String?,
        inputName: String,
        outputName: String,
        seconds: Double
    ) async -> Outcome {
        var outcome = Outcome(input: inputName, output: outputName)

        // Частоты Bluetooth-устройств до запуска: по ним потом видно, вернулись
        // ли они в исходный режим.
        let ratesBefore = bluetoothRates()

        let engine: VoiceAudioEngine
        do {
            engine = try VoiceAudioEngine(configuration: .init(
                inputDeviceUID: inputUID,
                outputDeviceUID: outputUID
            ))
        } catch {
            outcome.failure = "движок не собрался"
            return outcome
        }

        let notes = DiagnosticNotes()
        engine.onDiagnostic = { notes.add($0) }

        let tone = ToneSource(codec: .pcmu, samplesPerFrame: 160)
        engine.onNeedsFrame = {
            VoiceAudioEngine.PlaybackFrame(payload: tone.next(), isConcealment: false)
        }
        let captured = FrameCounter()
        engine.onEncodedFrame = { _ in captured.increment() }

        do {
            try engine.start()
            outcome.started = true
        } catch {
            outcome.failure = shorten(error.localizedDescription)
            return outcome
        }

        try? await Task.sleep(for: .seconds(seconds))

        // Спрашиваем движок, а не гадаем по строкам журнала: эхоподавление
        // отпадает несколькими разными путями, и каждый пишет своё.
        outcome.voiceProcessing = engine.usesEchoCancellation
        outcome.aggregate = notes.contains("агрегатное устройство:")
        outcome.headsetMode = engine.route.isHeadsetMode
        outcome.inputFormat = notes.value(after: "вход: ") ?? "—"
        outcome.outputFormat = notes.value(after: "выход: ") ?? "—"
        outcome.renderedSeconds =
            Double(engine.renderedSampleCount) / Double(AudioCodec.pcmu.sampleRate)
        outcome.capturedFrames = captured.value
        outcome.starvedRenders = engine.starvedRenderCount

        engine.stop()

        // Bluetooth отпускается не мгновенно: узел ввода-вывода пересобирается,
        // и частота возвращается через секунды, а не доли секунды.
        try? await Task.sleep(for: .seconds(4))
        let ratesAfter = bluetoothRates()
        outcome.released = ratesBefore.allSatisfy { uid, rate in
            ratesAfter[uid].map { abs($0 - rate) < 1 } ?? true
        }

        return outcome
    }

    private static func involvesBluetooth(_ input: AudioDevice, _ output: AudioDevice) -> Bool {
        input.transport == .bluetooth || output.transport == .bluetooth
    }

    private static func bluetoothRates() -> [String: Double] {
        Dictionary(uniqueKeysWithValues: AudioDeviceCatalog.devices()
            .filter { $0.transport == .bluetooth }
            .map { ($0.uid, $0.sampleRate) })
    }

    private static func shorten(_ text: String) -> String {
        text.count > 60 ? String(text.prefix(57)) + "…" : text
    }

    // MARK: - Отчёт

    private static func report(_ results: [Outcome], devices: [AudioDevice]) {
        print("\n── Сочетания ──")
        print(String(
            format: "%-26@ %-24@ %-6@ %-5@ %-4@ %-16@ %@",
            "микрофон" as NSString, "выход" as NSString, "эхо" as NSString,
            "агр." as NSString, "гарн" as NSString, "форматы" as NSString, "итог" as NSString
        ))

        for outcome in results {
            print(String(
                format: "%-26@ %-24@ %-6@ %-5@ %-4@ %-16@ %@",
                outcome.input.prefix(25) as NSString,
                outcome.output.prefix(23) as NSString,
                (outcome.voiceProcessing ? "да" : "нет") as NSString,
                (outcome.aggregate ? "да" : "—") as NSString,
                (outcome.headsetMode ? "да" : "—") as NSString,
                "\(outcome.inputFormat.prefix(7))→\(outcome.outputFormat.prefix(7))" as NSString,
                outcome.verdict as NSString
            ))
        }

        let broken = results.filter { !$0.isWorking }
        print("\nРаботает \(results.count - broken.count) из \(results.count).")
        if !broken.isEmpty {
            print("\nНе работает:")
            for outcome in broken {
                print("  \(outcome.input) → \(outcome.output): \(outcome.verdict)")
            }
        }

        let notReleased = results.filter { !$0.released }
        if !notReleased.isEmpty {
            print("\nНе отпустили Bluetooth-устройство:")
            for outcome in notReleased {
                print("  \(outcome.input) → \(outcome.output)")
            }
        } else if devices.contains(where: { $0.transport == .bluetooth }) {
            print("Bluetooth-устройство отпускается во всех сочетаниях.")
        }

        let withoutEcho = results.filter { $0.isWorking && !$0.voiceProcessing }
        if !withoutEcho.isEmpty {
            print("\nБез эхоподавления (через колонки разговаривать нельзя):")
            for outcome in withoutEcho {
                print("  \(outcome.input) → \(outcome.output)")
            }
        }
    }
}

/// Собирает строки диагностики движка, чтобы потом их расспросить.
final class DiagnosticNotes: @unchecked Sendable {

    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ line: String) { lock.withLock { lines.append(line) } }

    func contains(_ fragment: String) -> Bool {
        lock.withLock { lines.contains { $0.contains(fragment) } }
    }

    /// Первое значение после указанного начала строки.
    func value(after prefix: String) -> String? {
        lock.withLock {
            lines.first { $0.hasPrefix(prefix) }
                .map { String($0.dropFirst(prefix.count)) }
        }
    }
}

final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
