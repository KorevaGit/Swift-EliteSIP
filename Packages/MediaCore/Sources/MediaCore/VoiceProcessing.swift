import Foundation

// не переводится: итог обработки — строка журнала, а не интерфейса.

/// Уровень кадра, дБ от полной шкалы (RMS). Цифровой ноль — −180.
func rmsDecibels(_ frame: ArraySlice<Float>) -> Double {
    guard !frame.isEmpty else { return -180 }
    var energy: Double = 0
    for sample in frame {
        energy += Double(sample) * Double(sample)
    }
    let rms = (energy / Double(frame.count)).squareRoot()
    return rms <= 1e-9 ? -180 : 20 * log10(rms)
}

/// Подавление голосов вокруг: всё, что заметно тише голоса самого оператора,
/// приглушается. Перенос `BackgroundVoiceGate` из Windows 0.1.73 — числа те же,
/// они взяты из замеров, а не подобраны на глаз.
///
/// **Зачем, если есть шумодав.** Шумодав Voice Processing вычитает **ровный**
/// фон — вентилятор, гул, шипение — и пропускает любую речь, чужую тоже. Жалоба
/// 2 октября 2026: на USB-гарнитуре шум комнаты убирается, а голоса коллег
/// слышно отчётливо.
///
/// **Чем отличаются голоса.** Расстоянием до микрофона. Штанга гарнитуры у
/// рта, сосед в метре-двух: 25–35 дБ разницы на входе. Всё, что тише голоса
/// оператора на `marginDb` и больше, плавно приглушается расширителем. Пока
/// оператор говорит, чужие голоса закрыты его голосом и так; слышны они были в
/// паузах — там блок их и убирает.
///
/// **Где не поможет.** На микрофоне ноутбука разница голосов около 12 дБ:
/// громкий сосед рядом пройдёт. Различать голоса по содержанию умеют только
/// нейросетевые шумодавы — от них отказались.
///
/// **Как не съесть самого оператора.** Уровень оператора меряется только по
/// кадрам, близким к нему самому; щелчок поднимает его не больше чем на
/// полдецибела за кадр. Пока голос не услышан (полсекунды речи), блок не делает
/// ничего. Открывается сразу, закрывается после 250 мс тишины и плавно.
/// Глубина ограничена: мёртвая тишина читается как обрыв связи.
///
/// Тип чистый, без замков: кадры по 10 мс на входе, те же кадры на выходе.
struct BackgroundVoiceGate {

    /// Насколько тише голоса оператора начинается чужое, дБ.
    static let marginDb: Double = 16
    /// Сколько вправе убрать у чужого, дБ.
    static let depthDb: Double = 24
    /// Крутизна расширителя: ниже порога каждый дБ входа — четыре на выходе.
    private static let ratio: Double = 4
    /// Держать открытым после последнего громкого кадра: 250 мс.
    private static let holdFrames = 25
    /// Скорость закрытия, дБ за кадр: вся глубина — за четверть секунды.
    private static let releaseDbPerFrame: Double = 1
    /// Сколько кадров голоса оператора услышать, прежде чем приглушать.
    private static let establishFrames = 50
    /// Кадр в пределах стольких дБ от голоса оператора — его голос.
    private static let ownVoiceBandDb: Double = 8
    /// Доля нового кадра в уровне голоса.
    private static let voiceSmoothing: Double = 0.04
    /// Сколько уровень голоса вправе подняться за кадр: щелчок по столу не
    /// должен закрыть оператора.
    private static let voiceRiseLimitDb: Double = 0.5
    /// Сползание уровня, когда оператор стал тише: 1 дБ в секунду.
    private static let voiceDriftDbPerFrame: Double = 0.01
    /// Насколько кадр громче фона, чтобы считаться чьей-то речью.
    private static let speechOverNoiseDb: Double = 10
    /// Тише этого — тишина.
    private static let silenceDb: Double = -62
    /// Как быстро оценка фона ползёт вверх: 1 дБ в секунду.
    private static let noiseRiseDbPerFrame: Double = 0.01

    private var noiseDb: Double = 0
    private var trackedVoiceDb: Double?
    private var voiceFrames = 0
    private var hold = 0
    private(set) var gainDb: Double = 0
    private var appliedGain: Float = 1

    /// Уровень голоса оператора, дБ RMS. `nil` — ещё не услышан.
    var voiceDb: Double? {
        voiceFrames >= Self.establishFrames ? trackedVoiceDb : nil
    }

    /// Приглушает кадр на месте.
    mutating func process(_ frame: inout ArraySlice<Float>) {
        guard !frame.isEmpty else { return }

        let levelDb = rmsDecibels(frame)
        noiseDb = levelDb < noiseDb ? levelDb : noiseDb + Self.noiseRiseDbPerFrame
        let isSpeech = levelDb > Self.silenceDb && levelDb > noiseDb + Self.speechOverNoiseDb

        trackVoice(levelDb: levelDb, isSpeech: isSpeech)

        var wanted: Double = 0
        if let voice = voiceDb {
            let threshold = voice - Self.marginDb
            if levelDb >= threshold {
                hold = Self.holdFrames
            } else if hold > 0 {
                hold -= 1
            } else {
                wanted = -min(Self.depthDb, (threshold - levelDb) * (Self.ratio - 1))
            }
        }

        // Открывается сразу, закрывается плавно: срезанное начало слова
        // слышно, медленно ушедший фон — нет.
        gainDb = wanted >= gainDb ? wanted : max(wanted, gainDb - Self.releaseDbPerFrame)

        // Прибавка меняется плавно внутри кадра: скачок на границе 10 мс
        // слышен щелчком.
        let target = Float(pow(10, gainDb / 20))
        let start = appliedGain
        if start == 1, target == 1 { return }

        let step = (target - start) / Float(frame.count)
        var position: Float = 1
        for index in frame.indices {
            frame[index] *= start + step * position
            position += 1
        }
        appliedGain = target
    }

    private mutating func trackVoice(levelDb: Double, isSpeech: Bool) {
        guard let voice = trackedVoiceDb else {
            if isSpeech {
                trackedVoiceDb = levelDb
                voiceFrames = 1
            }
            return
        }

        if levelDb > voice - Self.ownVoiceBandDb {
            // Свой голос: уровень тянется к кадру, но вверх не быстрее предела.
            let step = min((levelDb - voice) * Self.voiceSmoothing, Self.voiceRiseLimitDb)
            trackedVoiceDb = voice + step
            voiceFrames += 1
        } else if isSpeech, levelDb > voice - Self.marginDb - 4 {
            // Речь тише привычного, но у самого порога — так выглядит оператор,
            // отодвинувший штангу. Сползаем медленно; голоса вдвое дальше
            // порога уровень оператора не трогают.
            trackedVoiceDb = voice - Self.voiceDriftDbPerFrame
        }

        // До установления первые кадры могли быть чужими: если оператор
        // громче, уровень дотянется до него за десятые доли секунды.
        if voiceFrames < Self.establishFrames, isSpeech, levelDb > voice, let current = trackedVoiceDb {
            trackedVoiceDb = max(current, levelDb - Self.ownVoiceBandDb / 2)
        }
    }
}

/// Регулятор уровня речи — выравнивание громкости собеседника. Перенос
/// `SpeechGainControl` из Windows 0.1.73 с пределами приёма.
///
/// Каждый кадр (10 мс) меряется уровень. Нижняя огибающая — шум линии; кадр
/// заметно громче неё — речь. Прибавка тянется к тому, чтобы речь встала на
/// цель, и тянется **только на речи**: в паузе она замирает, иначе регулятор
/// вытягивал бы шум — то самое «дыхание». Вверх медленно, вниз быстро.
///
/// Подъём на приёме скромнее, чем был бы у микрофона: вместе с тихим голосом
/// поднимается шум линии.
struct SpeechGainControl {

    /// Цель на приёме, дБ RMS.
    static let receiveTargetDb: Double = -20
    /// Сколько вправе добавить тихой линии, дБ.
    static let receiveMaximumBoostDb: Double = 10
    /// Сколько вправе убрать у громкой, дБ.
    static let receiveMaximumCutDb: Double = 6

    /// Скорость подъёма: 6 дБ в секунду.
    private static let riseDbPerFrame: Double = 0.06
    /// Скорость спуска: 50 дБ в секунду.
    private static let fallDbPerFrame: Double = 0.5
    private static let speechOverNoiseDb: Double = 9
    private static let silenceDb: Double = -65
    private static let noiseRiseDbPerFrame: Double = 0.01
    private static let speechSmoothing: Double = 0.05

    private let targetDb: Double
    private let maximumBoostDb: Double
    private let maximumCutDb: Double

    private var noiseDb: Double = 0
    private var speechDb: Double?
    private(set) var gainDb: Double = 0
    private var appliedGain: Float = 1

    init(
        targetDb: Double = receiveTargetDb,
        maximumBoostDb: Double = receiveMaximumBoostDb,
        maximumCutDb: Double = receiveMaximumCutDb
    ) {
        self.targetDb = targetDb
        self.maximumBoostDb = maximumBoostDb
        self.maximumCutDb = maximumCutDb
    }

    /// Регулирует кадр на месте. Ограничителя здесь нет: он стоит в конце
    /// тракта, после громкости, — один на всё, что выше единицы.
    mutating func process(_ frame: inout ArraySlice<Float>) {
        guard !frame.isEmpty else { return }

        let levelDb = rmsDecibels(frame)
        noiseDb = levelDb < noiseDb ? levelDb : noiseDb + Self.noiseRiseDbPerFrame

        let isSpeech = levelDb > Self.silenceDb && levelDb > noiseDb + Self.speechOverNoiseDb
        if isSpeech {
            let speech = speechDb.map { $0 + (levelDb - $0) * Self.speechSmoothing } ?? levelDb
            speechDb = speech
            let wanted = min(max(targetDb - speech, -maximumCutDb), maximumBoostDb)
            gainDb = wanted > gainDb
                ? min(wanted, gainDb + Self.riseDbPerFrame)
                : max(wanted, gainDb - Self.fallDbPerFrame)
        }

        let target = Float(pow(10, gainDb / 20))
        let start = appliedGain
        if start == 1, target == 1 { return }

        let step = (target - start) / Float(frame.count)
        var position: Float = 1
        for index in frame.indices {
            frame[index] *= start + step * position
            position += 1
        }
        appliedGain = target
    }
}

/// Мягкий ограничитель пика: до колена — как есть, выше — плавно к единице
/// через `tanh`. Жёсткий срез после прибавки звучал бы хрипом.
enum SoftLimiter {

    static let knee: Float = 0.9

    static func limit(_ sample: Float) -> Float {
        let magnitude = abs(sample)
        guard magnitude > knee else { return sample }
        let headroom = 1 - knee
        let squeezed = knee + headroom * tanh((magnitude - knee) / headroom)
        return sample < 0 ? -squeezed : squeezed
    }
}

/// Уровень фона: десятый процентиль уровней кадров, гистограммой по 1 дБ от
/// −120 до 0.
///
/// Процентиль, а не нижняя огибающая: один кадр цифрового нуля на старте
/// устройства уронил бы огибающую на −180 дБ. Десятая доля кадров — это паузы,
/// даже если оператор говорит большую часть разговора.
struct NoiseFloorMeter: Sendable, Equatable {

    private static let floor = -120
    private var bins = [Int](repeating: 0, count: 121)
    private(set) var count = 0

    mutating func observe(levelDb: Double) {
        let db = levelDb <= Double(Self.floor) ? Self.floor : Int(levelDb.rounded())
        bins[min(max(db, Self.floor), 0) - Self.floor] += 1
        count += 1
    }

    mutating func merge(_ other: NoiseFloorMeter) {
        for index in bins.indices { bins[index] += other.bins[index] }
        count += other.count
    }

    var decibels: Int {
        let wanted = count / 10
        var seen = 0
        for (index, bin) in bins.enumerated() {
            seen += bin
            if seen > wanted { return index + Self.floor }
        }
        return Self.floor
    }
}

/// Что обработка сделала с микрофоном за разговор — для итоговой строки звонка.
///
/// Ответ на «шумодав вообще работает на этой гарнитуре?» по журналу, а не на
/// слух у клиента. Вход узла Voice Processing недоступен, поэтому «фон
/// микрофона» здесь — уже после него, а «в линию» — после своей цепочки.
public struct VoiceProcessingStatistics: Sendable, Equatable {

    /// Кадры по 10 мс.
    public internal(set) var frames = 0
    /// Кадры, где голоса вокруг убирались на 6 дБ и больше.
    public internal(set) var suppressedFrames = 0
    /// Последняя оценка голоса оператора, дБ. `nil` — не услышан.
    public internal(set) var voiceDb: Double?
    /// Работало ли приглушение хоть часть разговора.
    public internal(set) var usedSuppression = false
    /// Прибавка выравнивания приёма в конце, дБ. `nil` — выключено.
    public internal(set) var receiveLevelingDb: Double?
    var floorIn = NoiseFloorMeter()
    var floorOut = NoiseFloorMeter()

    public init() {}

    /// Складывает статистику прошлого владения трактом с текущей.
    public mutating func merge(_ other: VoiceProcessingStatistics) {
        frames += other.frames
        suppressedFrames += other.suppressedFrames
        voiceDb = other.voiceDb ?? voiceDb
        usedSuppression = usedSuppression || other.usedSuppression
        receiveLevelingDb = other.receiveLevelingDb ?? receiveLevelingDb
        floorIn.merge(other.floorIn)
        floorOut.merge(other.floorOut)
    }

    public var summary: String {
        guard frames > 0 else { return "обработка: ни одного кадра" }

        func level(_ db: Int) -> String { db <= -120 ? "тишина" : "\(db) дБ" }

        var text = String(
            format: "обработка: %.0f с, фон микрофона после VP %@ → в линию %@",
            Double(frames) / 100, level(floorIn.decibels), level(floorOut.decibels)
        )
        if usedSuppression {
            if let voiceDb {
                text += String(
                    format: ", голос оператора %.0f дБ, голоса вокруг приглушались %.0f %% времени",
                    voiceDb, 100 * Double(suppressedFrames) / Double(frames)
                )
            } else {
                text += ", голос оператора не услышан — голоса вокруг не приглушались"
            }
        }
        if let receiveLevelingDb {
            text += String(format: ", выравнивание приёма %+.0f дБ", receiveLevelingDb)
        }
        return text
    }
}
