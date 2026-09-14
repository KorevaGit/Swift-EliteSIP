import AppKit
import MediaCore

/// Тоны клавиш поля набора и сигнал отбоя.
///
/// Появились 14 сентября 2026 по просьбе заказчика: номер набирается с
/// клавиатуры, и без звука цифра на экране — единственное подтверждение
/// нажатия; а конец разговора без звука оператор замечал по тишине в
/// гарнитуре, то есть с опозданием. Оба звука тихие и мягкие намеренно —
/// «негромкий и ненапряжный» было частью просьбы: оператор слышит их сотни раз
/// за день.
///
/// Синтезируются, как и рингтон, — без файлов с чужой лицензией. Играет
/// `NSSound`, а не свой `AVAudioEngine`: звуки короткие и редкие, и держать ради
/// них открытым поток на устройстве нельзя — Bluetooth-гарнитура с открытым
/// потоком не засыпает, а запуск движка на каждое нажатие опаздывает к цифре.
/// `NSSound` умеет играть в выбранное устройство (`playbackDeviceIdentifier`) с
/// Catalina и не трогает разговорный тракт с его `VoiceProcessingIO`.
///
/// Звучат в устройство разговора: гарнитура на голове — там их и ждут, а в
/// колонках тон каждой цифры слышит весь опенспейс.
@MainActor
final class CallSounds {

    /// Частота дискретизации синтеза. Любое устройство её примет, а
    /// пересчёт под устройство сделает система.
    private static let sampleRate = 44_100.0

    /// Громкость проигрывателя поверх и без того тихого синтеза. Пики тонов
    /// около −16 дБ от полной шкалы, и с этой громкостью — около −22: слышно в
    /// гарнитуре на средней системной громкости и не режет на высокой.
    private static let volume: Float = 0.5

    private var keySounds: [Character: NSSound] = [:]
    private lazy var endSound: NSSound? = Self.makeSound(samples: Self.endSamples())

    /// Тон одной клавиши — как у кнопочного телефона: та же пара частот DTMF,
    /// что уходит в линию, только коротко и тихо.
    ///
    /// Клавиши без пары (`+` и прочее) звучат как `0`: плюс на кнопочном
    /// телефоне набирают им же.
    func playKey(_ key: Character, outputDeviceUID: String?) {
        let key = Self.dtmfPairs[key] == nil ? "0" : key
        let sound: NSSound?
        if let cached = keySounds[key] {
            sound = cached
        } else {
            sound = Self.dtmfPairs[key].flatMap { Self.makeSound(samples: Self.keySamples(pair: $0)) }
            keySounds[key] = sound
        }
        play(sound, outputDeviceUID: outputDeviceUID)
    }

    /// Сигнал отбоя: две мягкие ноты вниз.
    ///
    /// Не «короткие гудки» АТС: три резких писка по 425 Гц — это «занято», а не
    /// «разговор кончился», и в нём ровно та напряжённость, которой просили
    /// избежать.
    func playEnd(outputDeviceUID: String?) {
        play(endSound, outputDeviceUID: outputDeviceUID)
    }

    private func play(_ sound: NSSound?, outputDeviceUID: String?) {
        guard let sound else { return }
        // Выбранной гарнитуры может не быть: её вынули, а в настройках она
        // осталась. Тогда — системное устройство, как и у разговора.
        if let uid = outputDeviceUID, AudioDeviceCatalog.device(uid: uid) != nil {
            sound.playbackDeviceIdentifier = NSSound.PlaybackDeviceIdentifier(uid)
        } else {
            sound.playbackDeviceIdentifier = nil
        }
        sound.volume = Self.volume
        // Та же клавиша подряд: `play()` у играющего звука ничего не делает,
        // и быстрый набор «00» звучал бы одним тоном.
        if sound.isPlaying { sound.stop() }
        sound.play()
    }

    // MARK: - Синтез

    /// Пары частот DTMF (ITU-T Q.23).
    private static let dtmfPairs: [Character: (low: Double, high: Double)] = [
        "1": (697, 1209), "2": (697, 1336), "3": (697, 1477),
        "4": (770, 1209), "5": (770, 1336), "6": (770, 1477),
        "7": (852, 1209), "8": (852, 1336), "9": (852, 1477),
        "*": (941, 1209), "0": (941, 1336), "#": (941, 1477),
    ]

    /// 70 мс пары с мягкими краями. Высокая составляющая тише низкой: у DTMF
    /// именно она звенит, и приглушённая она перестаёт колоть ухо.
    private static func keySamples(pair: (low: Double, high: Double)) -> [Float] {
        let count = Int(0.07 * sampleRate)
        let fade = Int(0.008 * sampleRate)
        return (0..<count).map { index in
            let time = Double(index) / sampleRate
            let tone = 0.09 * sin(2 * .pi * pair.low * time)
                + 0.06 * sin(2 * .pi * pair.high * time)
            return Float(tone * edge(index, count: count, fade: fade))
        }
    }

    /// Ми и ля пятой октавы с затуханием, как у колокольчика, — вниз, то
    /// есть «закончилось», а не «внимание».
    private static func endSamples() -> [Float] {
        let notes: [(frequency: Double, duration: Double, decay: Double)] = [
            (659.25, 0.16, 0.09),
            (440.00, 0.34, 0.14),
        ]
        let gap = [Float](repeating: 0, count: Int(0.03 * sampleRate))
        var samples: [Float] = []
        for (position, note) in notes.enumerated() {
            if position > 0 { samples += gap }
            let count = Int(note.duration * sampleRate)
            let fade = Int(0.006 * sampleRate)
            for index in 0..<count {
                let time = Double(index) / sampleRate
                // Вторая гармоника вполсилы — голая синусоида в гарнитуре
                // звучит как неисправность, а не как сигнал.
                let tone = sin(2 * .pi * note.frequency * time)
                    + 0.2 * sin(4 * .pi * note.frequency * time)
                let envelope = exp(-time / note.decay) * edge(index, count: count, fade: fade)
                samples.append(Float(0.13 * tone * envelope))
            }
        }
        return samples
    }

    /// Скос по краям: обрыв синусоиды на ненулевой фазе слышен как щелчок.
    private static func edge(_ index: Int, count: Int, fade: Int) -> Double {
        let rise = min(1, Double(index) / Double(fade))
        let fall = min(1, Double(count - index) / Double(fade))
        return min(rise, fall)
    }

    /// Звук из отсчётов: WAV в памяти, 16 бит, моно.
    private static func makeSound(samples: [Float]) -> NSSound? {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let rate = UInt32(sampleRate)
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + byteCount)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))        // размер блока fmt
        append(UInt16(1))         // PCM
        append(UInt16(1))         // моно
        append(rate)
        append(rate * 2)          // байт в секунду
        append(UInt16(2))         // байт на отсчёт
        append(UInt16(16))        // бит на отсчёт
        data.append(contentsOf: Array("data".utf8))
        append(byteCount)
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * Float(Int16.max)))
        }
        return NSSound(data: data)
    }
}
