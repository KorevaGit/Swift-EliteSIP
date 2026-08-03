import Foundation
import Testing
@testable import MediaCore

/// Кусок «голоса»: пила на заданной частоте — сигнал с ярко выраженным
/// основным тоном и богатыми обертонами, то есть ровно то, на чём период
/// обязан находиться уверенно.
private func voice(
    frequency: Double,
    count: Int,
    sampleRate: Double = 8000,
    startingAt phase: Double = 0,
    amplitude: Double = 8000
) -> [Int16] {
    (0..<count).map { index in
        let position = (phase + Double(index) * frequency / sampleRate).truncatingRemainder(dividingBy: 1)
        return Int16(amplitude * (2 * position - 1))
    }
}

private func rootMeanSquare(_ samples: [Int16]) -> Double {
    guard !samples.isEmpty else { return 0 }
    let energy = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
    return (energy / Double(samples.count)).squareRoot()
}

/// Наибольший скачок между соседними отсчётами. Щелчок на шве — это именно он.
private func maximumStep(_ samples: [Int16]) -> Int {
    zip(samples, samples.dropFirst()).reduce(0) { max($0, abs(Int($1.1) - Int($1.0))) }
}

@Suite("Сокрытие потерь")
struct PacketLossConcealmentTests {

    private let frameCount = 160  // 20 мс на 8 кГц

    /// Прогоняет через сокрытие несколько настоящих кадров, чтобы кольцо
    /// заполнилось, и возвращает готовый к потере экземпляр.
    private func primed(
        frequency: Double = 200,
        frames: Int = 5
    ) -> (concealer: PacketLossConcealer, tail: [Int16]) {
        var concealer = PacketLossConcealer(sampleRate: 8000)
        var tail: [Int16] = []
        for index in 0..<frames {
            let phase = Double(index * frameCount) * frequency / 8000
            let block = voice(frequency: frequency, count: frameCount, startingAt: phase)
            tail = concealer.receive(block)
        }
        return (concealer, tail)
    }

    @Test("Настоящий звук проходит насквозь без изменений")
    func realAudioIsUntouched() {
        var concealer = PacketLossConcealer(sampleRate: 8000)
        let block = voice(frequency: 200, count: frameCount)
        #expect(concealer.receive(block) == block)
    }

    @Test("Потеря в самом начале разговора закрывается тишиной, а не выдумкой")
    func lossBeforeAnyHistoryIsSilent() {
        var concealer = PacketLossConcealer(sampleRate: 8000)
        _ = concealer.receive(voice(frequency: 200, count: frameCount))
        let concealed = concealer.conceal(count: frameCount)
        #expect(concealed.count == frameCount)
        #expect(concealed.allSatisfy { $0 == 0 }, "истории ещё нет — синтезировать не из чего")
    }

    @Test("Спрятанный кадр сохраняет громкость голоса")
    func concealedFrameKeepsLoudness() {
        var (concealer, tail) = primed()
        let concealed = concealer.conceal(count: frameCount)

        let expected = rootMeanSquare(tail)
        let actual = rootMeanSquare(concealed)
        // Первые 10 мс идут в полную силу, дальше начинается затухание, поэтому
        // за кадр целиком уровень законно проседает — но не в разы.
        #expect(actual > expected * 0.6, "синтез слишком тихий: \(actual) против \(expected)")
        #expect(actual < expected * 1.2, "синтез громче оригинала: \(actual) против \(expected)")
    }

    @Test(
        "Основной тон находится точно, а не с ошибкой в октаву",
        arguments: [(100.0, 80), (160.0, 50), (200.0, 40), (250.0, 32)]
    )
    func periodIsFoundExactly(frequency: Double, expected: Int) {
        var (concealer, _) = primed(frequency: frequency)
        _ = concealer.conceal(count: frameCount)
        // Кратный период — тоже «похожий» кусок, и корреляция на него ловится
        // легко. Слышно это как голос октавой ниже, поэтому проверяем число, а
        // не похожесть.
        #expect(
            concealer.estimatedPeriod == expected,
            "\(frequency) Гц: период \(concealer.estimatedPeriod) вместо \(expected)"
        )
    }

    @Test("Спрятанный кадр продолжает тот же основной тон")
    func concealedFrameKeepsPitch() {
        // 200 Гц на 8 кГц — период ровно 40 отсчётов. Синтез обязан повторяться
        // с тем же периодом: именно за это платится вся сложность.
        var (concealer, _) = primed(frequency: 200)
        let concealed = concealer.conceal(count: frameCount)

        let period = 40
        var mismatch = 0.0
        for index in period..<min(concealed.count, 80) {
            mismatch += abs(Double(concealed[index]) - Double(concealed[index - period]) * 0.99)
        }
        let average = mismatch / Double(80 - period)
        #expect(average < 400, "период не выдержан: среднее расхождение \(average)")
    }

    @Test("На шве между настоящим звуком и синтезом нет щелчка")
    func noClickEnteringConcealment() {
        var (concealer, tail) = primed()
        let concealed = concealer.conceal(count: frameCount)

        // Пила сама по себе даёт один большой скачок за период — это её обрыв,
        // а не щелчок. Поэтому шов сравнивается не с нулём, а с тем, какие
        // скачки в этом сигнале и так есть.
        let natural = maximumStep(tail)
        let seam = abs(Int(concealed[0]) - Int(tail[tail.count - 1]))
        #expect(seam <= natural, "на входе в сокрытие скачок \(seam) при природных \(natural)")
    }

    @Test("На возврате настоящего звука тоже нет щелчка")
    func noClickLeavingConcealment() {
        let frequency = 200.0
        var (concealer, _) = primed(frequency: frequency, frames: 5)
        let concealed = concealer.conceal(count: frameCount)

        // Настоящий звук продолжается ровно с того места, где его прервали:
        // шестой кадр по счёту.
        let phase = Double(6 * frameCount) * frequency / 8000
        let real = voice(frequency: frequency, count: frameCount, startingAt: phase)
        let recovered = concealer.receive(real)

        let natural = maximumStep(real)
        let seam = abs(Int(recovered[0]) - Int(concealed[concealed.count - 1]))
        #expect(seam <= natural, "на выходе из сокрытия скачок \(seam) при природных \(natural)")
        // Сшивка короткая: к середине кадра должен идти уже честный сигнал.
        #expect(Array(recovered.suffix(frameCount / 2)) == Array(real.suffix(frameCount / 2)))
    }

    @Test("Долгая потеря уходит в тишину, а не в гудок")
    func longLossFadesToSilence() {
        var (concealer, tail) = primed()
        let loud = rootMeanSquare(tail)

        var levels: [Double] = []
        for _ in 0..<5 {
            levels.append(rootMeanSquare(concealer.conceal(count: frameCount)))
        }

        #expect(levels[0] > loud * 0.6, "первый спрятанный кадр обязан быть слышен")
        for index in 1..<levels.count {
            #expect(levels[index] <= levels[index - 1] + 1, "громкость обязана только падать")
        }
        // 10 мс полной громкости плюс 50 мс затухания — к четвёртому кадру
        // (60 мс) продолжать уже нечего.
        #expect(levels[3] == 0, "на 60 мс потери синтез обязан замолчать")
    }

    @Test("После настоящего кадра затухание начинается заново")
    func recoveryRestartsTheFade() {
        var (concealer, _) = primed()
        _ = concealer.conceal(count: frameCount)
        _ = concealer.conceal(count: frameCount)

        let real = voice(frequency: 200, count: frameCount, startingAt: 0.25)
        _ = concealer.receive(real)
        let afterRecovery = rootMeanSquare(concealer.conceal(count: frameCount))

        #expect(afterRecovery > rootMeanSquare(real) * 0.6, "серия обязана считаться с нуля")
    }

    @Test("Шкала считается по частоте кодека, а не по числу отсчётов")
    func scaleFollowsSampleRate() {
        // Тот же тон на 16 кГц — период вдвое длиннее в отсчётах. Если бы
        // пороги были заданы в отсчётах, а не в миллисекундах, на G.722
        // основной тон искался бы вне допустимого диапазона.
        var concealer = PacketLossConcealer(codec: .g722)
        for index in 0..<6 {
            let phase = Double(index * 320) * 200 / 16000
            _ = concealer.receive(voice(
                frequency: 200, count: 320, sampleRate: 16000, startingAt: phase
            ))
        }
        let concealed = concealer.conceal(count: 320)
        let period = 80  // 200 Гц на 16 кГц
        var mismatch = 0.0
        for index in period..<160 {
            mismatch += abs(Double(concealed[index]) - Double(concealed[index - period]) * 0.99)
        }
        #expect(mismatch / Double(160 - period) < 400)
    }

    @Test("Сброс возвращает сокрытие в исходное состояние")
    func resetClearsHistory() {
        var (concealer, _) = primed()
        concealer.reset()
        let concealed = concealer.conceal(count: frameCount)
        #expect(concealed.allSatisfy { $0 == 0 }, "после сброса истории нет")
    }
}
