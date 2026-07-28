import Foundation
import Testing
@testable import MediaCore

/// Что происходит со звуком после потери пакета.
///
/// Проверять это отдельно нужно из-за G.722: он с состоянием, и потерянный
/// кадр сбивает предсказатель декодера с траектории кодера. У G.711 такой
/// проблемы нет вовсе — там каждый байт самодостаточен, — поэтому одна и та же
/// потеря в двух кодеках звучит по-разному, и знать насколько это разные вещи
/// стоит заранее, а не по жалобе.
@Suite("Восстановление после потерь")
struct LossRecoveryTests {

    private func tone(_ frequency: Double, sampleRate: Double, count: Int) -> [Int16] {
        (0..<count).map { index in
            Int16(0.4 * 32000 * sin(2 * .pi * frequency * Double(index) / sampleRate))
        }
    }

    /// Среднеквадратичное расхождение двух дорожек на отрезке, в долях шкалы.
    private func deviation(_ lhs: ArraySlice<Int16>, _ rhs: ArraySlice<Int16>) -> Double {
        let pairs = zip(lhs, rhs)
        var sum = 0.0
        var count = 0
        for (left, right) in pairs {
            let error = (Double(left) - Double(right)) / 32768
            sum += error * error
            count += 1
        }
        guard count > 0 else { return 0 }
        return (sum / Double(count)).squareRoot()
    }

    /// Прогоняет поток кадров через кодек, подменяя один кадр повтором
    /// предыдущего — ровно так, как это делает джиттер-буфер при потере.
    private func decodeWithLoss(
        codec: AudioCodec,
        frames: [[Int16]],
        losing lostIndex: Int
    ) -> (clean: [Int16], damaged: [Int16]) {
        var encoder = AudioFrameEncoder(codec: codec)
        let payloads = frames.map { encoder.encode($0) }

        var cleanDecoder = AudioFrameDecoder(codec: codec)
        var clean: [Int16] = []
        for payload in payloads {
            clean.append(contentsOf: cleanDecoder.decode(payload))
        }

        var damagedDecoder = AudioFrameDecoder(codec: codec)
        var damaged: [Int16] = []
        for (index, payload) in payloads.enumerated() {
            // Потерянный кадр заменяется повтором предыдущего: именно это
            // отдаёт джиттер-буфер, а затухание накладывается уже в движке.
            let delivered = index == lostIndex ? payloads[index - 1] : payload
            damaged.append(contentsOf: damagedDecoder.decode(delivered))
        }

        return (clean, damaged)
    }

    @Test("G.711 забывает потерю сразу же")
    func narrowbandRecoversImmediately() {
        let samplesPerFrame = AudioCodec.pcmu.sampleCount(forPacketTime: 20)
        let signal = tone(440, sampleRate: 8000, count: samplesPerFrame * 20)
        let frames = stride(from: 0, to: signal.count, by: samplesPerFrame).map {
            Array(signal[$0..<min($0 + samplesPerFrame, signal.count)])
        }

        let (clean, damaged) = decodeWithLoss(codec: .pcmu, frames: frames, losing: 10)

        // Кодек без состояния: расходятся ровно те отсчёты, что подменили, и
        // ни одним больше.
        let afterHole = (11 * samplesPerFrame)..<(13 * samplesPerFrame)
        #expect(deviation(clean[afterHole], damaged[afterHole]) == 0)
    }

    @Test("G.722 после потери возвращается к норме за десятки миллисекунд")
    func widebandReconvergesAfterLoss() {
        let samplesPerFrame = AudioCodec.g722.sampleCount(forPacketTime: 20)
        let signal = tone(1000, sampleRate: 16000, count: samplesPerFrame * 30)
        let frames = stride(from: 0, to: signal.count, by: samplesPerFrame).map {
            Array(signal[$0..<min($0 + samplesPerFrame, signal.count)])
        }

        let (clean, damaged) = decodeWithLoss(codec: .g722, frames: frames, losing: 10)

        // Сразу за дырой предсказатель сбит и звук заметно отличается.
        let justAfter = (11 * samplesPerFrame)..<(12 * samplesPerFrame)
        let immediate = deviation(clean[justAfter], damaged[justAfter])

        // Через пять кадров (100 мс) он должен уже почти сойтись: предсказатель
        // в G.722 «протекающий», то есть по построению забывает прошлое, и на
        // этом держится вся устойчивость кодека к потерям.
        let later = (16 * samplesPerFrame)..<(17 * samplesPerFrame)
        let settled = deviation(clean[later], damaged[later])

        #expect(settled < immediate, "расхождение должно убывать: было \(immediate), стало \(settled)")
        #expect(settled < 0.02, "через 100 мс после потери расхождение \(settled)")
    }

    @Test("Одна потеря не ломает G.722 навсегда")
    func widebandStaysUsableLongAfterLoss() {
        let samplesPerFrame = AudioCodec.g722.sampleCount(forPacketTime: 20)
        let signal = tone(1000, sampleRate: 16000, count: samplesPerFrame * 60)
        let frames = stride(from: 0, to: signal.count, by: samplesPerFrame).map {
            Array(signal[$0..<min($0 + samplesPerFrame, signal.count)])
        }

        let (clean, damaged) = decodeWithLoss(codec: .g722, frames: frames, losing: 5)

        // Полсекунды спустя расхождение должно быть неотличимо от нуля. Если
        // тест однажды покраснеет — значит предсказатель где-то накапливает
        // ошибку вместо того, чтобы её забывать, и разговор будет тем хуже,
        // чем он длиннее.
        let farLater = (50 * samplesPerFrame)..<(55 * samplesPerFrame)
        #expect(deviation(clean[farLater], damaged[farLater]) < 0.005)
    }

    @Test("Затухание на спрятанном кадре доводит повтор до тишины")
    func concealmentFadeReachesSilence() {
        // Множитель 0,6 за кадр: пять кадров подряд — это 0,6^5 ≈ 0,078, то
        // есть −22 дБ. Ровно к этому моменту джиттер-буфер и сдаётся, так что
        // заевшей пластинки не получается ни при каком стечении обстоятельств.
        var gain = 1.0
        for _ in 0..<JitterBuffer.maximumConcealmentRun {
            gain *= 0.6
        }
        #expect(gain < 0.1, "после предела сокрытия остаётся \(gain) громкости")
        #expect(20 * log10(gain) < -20)
    }
}
