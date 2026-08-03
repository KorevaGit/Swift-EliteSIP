import Foundation

/// Сокрытие потерь в области отсчётов — по мотивам ITU-T G.711 Appendix I.
///
/// **Зачем отдельный тип.** Раньше дырка затыкалась повтором *закодированного*
/// кадра с затуханием 0,6 за кадр. Для одиночной потери этого хватало, но
/// повтор двадцатимиллисекундного куска — это повтор куска, никак не связанного
/// с периодом голоса: шов приходится на случайную фазу основного тона, и на
/// слух получается «бульканье», а не продолжение звука. Дальше третьего кадра
/// затухание уводило всё в тишину, то есть на 60 мс потери оператор просто
/// терял слог.
///
/// Appendix I решает это иначе: находит период основного тона в уже
/// прозвучавшем и продолжает сигнал ровно этим периодом. Шов ложится в фазу,
/// голос сохраняет и высоту, и тембр, и короткая потеря перестаёт читаться на
/// слух вообще.
///
/// **Почему это работа под G.711.** Приложение I написано именно для него, и
/// не случайно: у G.711 нет собственного состояния, повторять нечего, кроме
/// самого звука, — а восстановить утраченный кадр по предыдущим для
/// кодека без предсказателя можно только так. Ровно поэтому этап M2c, где
/// решено, что боевой разговор идёт на G.711, начинается отсюда.
///
/// Работает над отсчётами, поэтому кодеку безразличен и одинаково годится
/// G.722 — там он тоже лучше повтора, хотя декодер после дырки всё равно
/// приходит в себя сам.
///
/// **Задержки не добавляет.** Канонический Appendix I задерживает весь тракт на
/// 3,75 мс, чтобы сшивать возврат к настоящему звуку с обеих сторон. Мы платить
/// задержкой не готовы — при норме G.114 в 150 мс на весь путь каждая
/// миллисекунда на счету, — поэтому возврат сшивается только вперёд:
/// синтез продолжается ещё несколько миллисекунд и смешивается с началом
/// пришедшего кадра. Щелчок это убирает так же, а стоит нисколько.
///
/// Тип синхронный и без зависимостей от сети и звуковой карты: проверяется
/// целиком тестом.
public struct PacketLossConcealer: Sendable {

    // MARK: Настройки шкалы
    //
    // Все пороги заданы в миллисекундах и переводятся в отсчёты по частоте
    // кодека. Иначе на G.722 период основного тона искался бы вдвое ниже, чем
    // надо, и мужской голос синтезировался бы женским.

    /// Сколько прозвучавшего держим для анализа. 48 мс — из Appendix I: это
    /// чуть больше двух самых длинных периодов основного тона.
    private let historyCount: Int
    /// Самый короткий период основного тона, который ищем: 400 Гц. Выше —
    /// уже не тон голоса, а шипящая.
    private let minimumPeriod: Int
    /// Самый длинный: 66 Гц. Ниже мужской голос не опускается.
    private let maximumPeriod: Int
    /// Длина сшивки на возврате к настоящему звуку.
    private let recoveryBlend: Int

    /// Сколько миллисекунд синтез звучит в полную силу, прежде чем начать
    /// затухать. До 10 мс повтор периода неотличим от продолжения речи.
    private let fullGainSamples: Int
    /// Сколько миллисекунд занимает уход в тишину. К 60 мс потери продолжать
    /// нечего: голос за это время успевает смениться, и синтез из правдоподобного
    /// становится гудком.
    private let fadeSamples: Int

    // MARK: Состояние

    /// Кольцо прозвучавшего. Пишется на каждом настоящем кадре, читается на
    /// первом потерянном.
    private var history: [Int16]
    private var historyFilled = 0

    /// Период, которым продолжаем сигнал, в отсчётах. Ищется один раз на серию
    /// потерь: искать заново на каждом кадре значит менять высоту голоса
    /// посреди дырки. Ноль — серии нет.
    ///
    /// Наружу открыт для диагностики и для теста: «синтез звучит похоже» —
    /// свойство, которое легко проходит и при вдвое ошибочном периоде, а
    /// ошибка вдвое — это голос, поднявшийся на октаву.
    public private(set) var estimatedPeriod = 0
    /// Продолжение сигнала — копия последнего периода, из которой синтез
    /// вычитывается по кругу.
    private var pattern: [Int16] = []
    private var patternCursor = 0
    /// Сколько отсчётов уже синтезировано в текущей серии. По нему считается
    /// затухание, поэтому счётчик именно в отсчётах, а не в кадрах: кадр может
    /// быть любой длины.
    private var concealedSamples = 0
    /// Синтез, оставшийся на сшивку с первым настоящим кадром после потери.
    private var pendingBlend: [Int16] = []

    public init(sampleRate: Int) {
        precondition(sampleRate > 0, "частота дискретизации обязана быть положительной")

        func samples(milliseconds: Double) -> Int {
            max(1, Int((Double(sampleRate) * milliseconds / 1000).rounded()))
        }

        historyCount = samples(milliseconds: 48)
        minimumPeriod = samples(milliseconds: 2.5)
        maximumPeriod = samples(milliseconds: 15)
        recoveryBlend = samples(milliseconds: 2)
        fullGainSamples = samples(milliseconds: 10)
        fadeSamples = samples(milliseconds: 50)

        history = [Int16](repeating: 0, count: historyCount)
    }

    public init(codec: AudioCodec) {
        self.init(sampleRate: Int(codec.sampleRate))
    }

    // MARK: - Настоящий звук

    /// Принимает прозвучавший кадр.
    ///
    /// Возвращает его же — но если перед ним была потеря, начало кадра сшито с
    /// хвостом синтеза. Возврат, а не изменение на месте: вызывающему видно, что
    /// отдавать в кольцо надо именно результат.
    public mutating func receive(_ samples: [Int16]) -> [Int16] {
        var result = samples

        if !pendingBlend.isEmpty {
            // Линейная сшивка: синтез уходит, настоящий звук приходит. Оба
            // сигнала в фазе — синтез продолжает ровно тот же период, — поэтому
            // двух миллисекунд достаточно, чтобы шва не было слышно.
            let count = min(pendingBlend.count, result.count)
            for index in 0..<count {
                let weight = Float(index + 1) / Float(count + 1)
                let blended = Float(pendingBlend[index]) * (1 - weight) + Float(result[index]) * weight
                result[index] = Int16(clamping: Int(blended.rounded()))
            }
            pendingBlend.removeAll(keepingCapacity: true)
        }

        remember(result)
        estimatedPeriod = 0
        pattern.removeAll(keepingCapacity: true)
        concealedSamples = 0
        return result
    }

    /// Кладёт кадр в кольцо прозвучавшего.
    private mutating func remember(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }

        if samples.count >= historyCount {
            history = Array(samples.suffix(historyCount))
            historyFilled = historyCount
            return
        }

        history.removeFirst(samples.count)
        history.append(contentsOf: samples)
        historyFilled = min(historyFilled + samples.count, historyCount)
    }

    // MARK: - Потерянный звук

    /// Синтезирует кадр взамен потерянного.
    public mutating func conceal(count: Int) -> [Int16] {
        guard count > 0 else { return [] }

        // Пока кольцо не заполнено целиком, продолжать нечего: корреляция
        // против ещё не записанных нулей нашла бы период где угодно. Это первые
        // 48 мс разговора — потеря в них закрывается тишиной, и это честнее
        // синтеза из ничего.
        guard historyFilled >= historyCount else {
            concealedSamples += count
            return [Int16](repeating: 0, count: count)
        }

        if pattern.isEmpty {
            estimatedPeriod = estimatePeriod()
            pattern = Array(history.suffix(estimatedPeriod))
            patternCursor = 0
        }

        var output = [Int16](repeating: 0, count: count)
        for index in 0..<count {
            let gain = attenuation(at: concealedSamples + index)
            let value = Float(pattern[patternCursor]) * gain
            output[index] = Int16(clamping: Int(value.rounded()))
            patternCursor = (patternCursor + 1) % pattern.count
        }
        concealedSamples += count

        // Хвост на сшивку берём из продолжения того же периода, а не из уже
        // отданного куска: тогда на возврате синтез и настоящий звук идут в
        // одной фазе, и складывать их можно напрямую.
        pendingBlend = (0..<recoveryBlend).map { offset in
            let gain = attenuation(at: concealedSamples + offset)
            let value = Float(pattern[(patternCursor + offset) % pattern.count]) * gain
            return Int16(clamping: Int(value.rounded()))
        }

        remember(output)
        return output
    }

    /// Громкость синтеза на заданном отсчёте серии.
    private func attenuation(at offset: Int) -> Float {
        if offset < fullGainSamples { return 1 }
        let faded = offset - fullGainSamples
        guard faded < fadeSamples else { return 0 }
        return 1 - Float(faded) / Float(fadeSamples)
    }

    /// Ищет период основного тона нормированной взаимной корреляцией.
    ///
    /// Сравнивается последний кусок длиной с самый длинный допустимый период —
    /// с такими же кусками, отстоящими назад на все допустимые периоды.
    /// Нормировка на энергию обязательна: без неё побеждает не самый похожий
    /// кусок, а самый громкий, и на затухающем звуке период всегда получается
    /// минимальным.
    ///
    /// Окно взято длиной с максимальный период, а не с минимальный: короткое
    /// окно одинаково хорошо ложится и на период, и на его половину, а ошибка
    /// вдвое — это голос, поднявшийся на октаву.
    private func estimatePeriod() -> Int {
        let windowCount = maximumPeriod
        var bestLag = maximumPeriod
        var bestScore = -Float.greatestFiniteMagnitude

        history.withUnsafeBufferPointer { samples in
            let end = samples.count
            for lag in minimumPeriod...maximumPeriod {
                let start = end - windowCount - lag
                guard start >= 0 else { continue }

                var correlation: Float = 0
                var energy: Float = 0
                for offset in 0..<windowCount {
                    let recent = Float(samples[end - windowCount + offset])
                    let past = Float(samples[start + offset])
                    correlation += recent * past
                    energy += past * past
                }

                let score = energy > 0 ? correlation / energy.squareRoot() : 0
                if score > bestScore {
                    bestScore = score
                    bestLag = lag
                }
            }
        }

        return bestLag
    }

    public mutating func reset() {
        for index in history.indices { history[index] = 0 }
        historyFilled = 0
        estimatedPeriod = 0
        pattern.removeAll(keepingCapacity: true)
        patternCursor = 0
        concealedSamples = 0
        pendingBlend.removeAll(keepingCapacity: true)
    }
}
