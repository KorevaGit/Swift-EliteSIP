import Foundation

/// G.722 — субполосный АДИКМ по рекомендации ITU-T.
///
/// Зачем он нужен: полоса 50–7000 Гц вместо 300–3400 у G.711 при том же
/// битрейте 64 кбит/с. Разница на слух — та же, что между телефоном и радио:
/// возвращаются шипящие и различимость близких согласных.
///
/// Как устроен. Входные 16 кГц квадратурный фильтр делит на две полосы по 8 кГц:
/// нижнюю 0–4 кГц и верхнюю 4–8 кГц. Нижняя кодируется шестью битами на отсчёт,
/// верхняя двумя. На каждые два входных отсчёта выходит один байт — отсюда и
/// 64 кбит/с, и то, что пакет в 20 мс занимает те же 160 байт, что у G.711.
///
/// **Кодек с состоянием, в отличие от G.711.** Предсказатель и квантователь
/// подстраиваются на каждом отсчёте, и кодер с декодером обязаны идти по одной
/// и той же траектории. Практические следствия: экземпляр кодера привязан к
/// разговору и не переживает его; декодировать кадры не подряд или пропустив
/// один — значит разойтись с отправителем и получить хрип, который сам собой
/// затухает лишь через десятки миллисекунд. Поэтому потерянный кадр всё равно
/// надо чем-то заполнять, а не пропускать.
///
/// Реализация следует блочной структуре рекомендации, названия блоков (UPPOL2,
/// FILTEZ, SCALEL и прочие) сохранены в комментариях — иначе этот код невозможно
/// сверить с текстом стандарта.
public enum G722 {

    /// Коэффициенты квадратурного зеркального фильтра, 24 отвода.
    /// Симметричны, поэтому хранится половина.
    ///
    /// Развязка чётных и нечётных отводов — `x[2i]` с прямым индексом
    /// коэффициента, `x[2i+1]` с обратным — выглядит произвольной, и перепутать
    /// её ничего не стоит. Перепутанная не ломает кодек заметно: полоса ниже
    /// 1 кГц проходит почти без потерь, зато на 3 и 5 кГц появляется провал в
    /// 13,8 дБ. На слух это «глухой» голос, а не поломка, поэтому проверяется
    /// тестом `qmfReconstructsFlat`.
    private static let qmfCoefficients: [Int32] = [
        3, -11, 12, 32, -210, 951, 3876, -805, 362, -156, 53, -11,
    ]

    // Таблицы квантователей и адаптации из рекомендации. Смысла по отдельности
    // не имеют, менять нельзя.

    private static let q6: [Int32] = [
        0, 35, 72, 110, 150, 190, 233, 276,
        323, 370, 422, 473, 530, 587, 650, 714,
        786, 858, 940, 1023, 1121, 1219, 1339, 1458,
        1612, 1765, 1980, 2195, 2557, 2919, 0, 0,
    ]

    private static let iln: [Int32] = [
        0, 63, 62, 31, 30, 29, 28, 27,
        26, 25, 24, 23, 22, 21, 20, 19,
        18, 17, 16, 15, 14, 13, 12, 11,
        10, 9, 8, 7, 6, 5, 4, 0,
    ]

    private static let ilp: [Int32] = [
        0, 61, 60, 59, 58, 57, 56, 55,
        54, 53, 52, 51, 50, 49, 48, 47,
        46, 45, 44, 43, 42, 41, 40, 39,
        38, 37, 36, 35, 34, 33, 32, 0,
    ]

    private static let wl: [Int32] = [-60, -30, 58, 172, 334, 538, 1198, 3042]

    private static let rl42: [Int32] = [0, 7, 6, 5, 4, 3, 2, 1, 7, 6, 5, 4, 3, 2, 1, 0]

    private static let ilb: [Int32] = [
        2048, 2093, 2139, 2186, 2233, 2282, 2332, 2383,
        2435, 2489, 2543, 2599, 2656, 2714, 2774, 2834,
        2896, 2960, 3025, 3091, 3158, 3228, 3298, 3371,
        3444, 3520, 3597, 3676, 3756, 3838, 3922, 4008,
    ]

    private static let qm4: [Int32] = [
        0, -20456, -12896, -8968,
        -6288, -4240, -2584, -1200,
        20456, 12896, 8968, 6288,
        4240, 2584, 1200, 0,
    ]

    private static let qm2: [Int32] = [-7408, -1616, 7408, 1616]

    private static let qm6: [Int32] = [
        -136, -136, -136, -136,
        -24808, -21904, -19008, -16704,
        -14984, -13512, -12280, -11192,
        -10232, -9360, -8576, -7856,
        -7192, -6576, -6000, -5456,
        -4944, -4464, -4008, -3576,
        -3168, -2776, -2400, -2032,
        -1688, -1360, -1040, -728,
        24808, 21904, 19008, 16704,
        14984, 13512, 12280, 11192,
        10232, 9360, 8576, 7856,
        7192, 6576, 6000, 5456,
        4944, 4464, 4008, 3576,
        3168, 2776, 2400, 2032,
        1688, 1360, 1040, 728,
        432, 136, -432, -136,
    ]

    private static let ihn: [Int32] = [0, 1, 0]
    private static let ihp: [Int32] = [0, 3, 2]
    private static let wh: [Int32] = [0, -214, 798]
    private static let rh2: [Int32] = [2, 1, 2, 1]

    @inline(__always)
    private static func saturate(_ value: Int32) -> Int32 {
        if value > 32767 { return 32767 }
        if value < -32768 { return -32768 }
        return value
    }

    /// Состояние одной полосы: предсказатель и масштаб квантователя.
    private struct Band {
        var s: Int32 = 0
        var sp: Int32 = 0
        var sz: Int32 = 0
        var r = [Int32](repeating: 0, count: 3)
        var a = [Int32](repeating: 0, count: 3)
        var ap = [Int32](repeating: 0, count: 3)
        var p = [Int32](repeating: 0, count: 3)
        var d = [Int32](repeating: 0, count: 7)
        var b = [Int32](repeating: 0, count: 7)
        var bp = [Int32](repeating: 0, count: 7)
        var sg = [Int32](repeating: 0, count: 7)
        var nb: Int32 = 0
        /// Начальный масштаб задан рекомендацией. Ноль здесь означал бы, что
        /// первые отсчёты декодируются в тишину независимо от входа.
        var det: Int32 = 32

        /// Блок 4 рекомендации: пересчёт предсказателя по новой невязке.
        /// Общий для обеих полос и для обеих сторон — кодер и декодер обязаны
        /// выполнять его одинаково, иначе их состояния разойдутся.
        mutating func update(with dx: Int32) {
            // RECONS и PARREC
            d[0] = dx
            r[0] = saturate(s + dx)
            p[0] = saturate(sz + dx)

            // UPPOL2
            for index in 0..<3 {
                sg[index] = p[index] >> 15
            }
            var wd1 = saturate(a[1] &* 4)
            var wd2 = (sg[0] == sg[1]) ? -wd1 : wd1
            if wd2 > 32767 { wd2 = 32767 }
            var wd3 = (sg[0] == sg[2]) ? Int32(128) : Int32(-128)
            wd3 += wd2 >> 7
            wd3 += (a[2] &* 32512) >> 15
            wd3 = min(max(wd3, -12288), 12288)
            ap[2] = wd3

            // UPPOL1
            sg[0] = p[0] >> 15
            sg[1] = p[1] >> 15
            wd1 = (sg[0] == sg[1]) ? 192 : -192
            wd2 = (a[1] &* 32640) >> 15
            ap[1] = saturate(wd1 + wd2)
            wd3 = saturate(15360 - ap[2])
            ap[1] = min(max(ap[1], -wd3), wd3)

            // UPZERO
            wd1 = (dx == 0) ? 0 : 128
            sg[0] = dx >> 15
            for index in 1..<7 {
                sg[index] = d[index] >> 15
                wd2 = (sg[index] == sg[0]) ? wd1 : -wd1
                wd3 = (b[index] &* 32640) >> 15
                bp[index] = saturate(wd2 + wd3)
            }

            // DELAYA
            for index in stride(from: 6, to: 0, by: -1) {
                d[index] = d[index - 1]
                b[index] = bp[index]
            }
            for index in stride(from: 2, to: 0, by: -1) {
                r[index] = r[index - 1]
                p[index] = p[index - 1]
                a[index] = ap[index]
            }

            // FILTEP
            wd1 = saturate(r[1] + r[1])
            wd1 = (a[1] &* wd1) >> 15
            wd2 = saturate(r[2] + r[2])
            wd2 = (a[2] &* wd2) >> 15
            sp = saturate(wd1 + wd2)

            // FILTEZ
            var sum: Int32 = 0
            for index in stride(from: 6, to: 0, by: -1) {
                let doubled = saturate(d[index] + d[index])
                sum += (b[index] &* doubled) >> 15
            }
            sz = saturate(sum)

            // PREDIC
            s = saturate(sp + sz)
        }

        /// Блоки 3 нижней полосы: LOGSCL и SCALEL.
        mutating func scaleLow(index: Int32) {
            var wd1 = (nb &* 127) >> 7
            wd1 += G722.wl[Int(G722.rl42[Int(index)])]
            nb = min(max(wd1, 0), 18432)

            let position = Int((nb >> 6) & 31)
            let shift = 8 - (nb >> 11)
            let scaled = shift < 0
                ? G722.ilb[position] << Int(-shift)
                : G722.ilb[position] >> Int(shift)
            det = scaled << 2
        }

        /// Блоки 3 верхней полосы: LOGSCH и SCALEH.
        mutating func scaleHigh(index: Int32) {
            var wd1 = (nb &* 127) >> 7
            wd1 += G722.wh[Int(G722.rh2[Int(index)])]
            nb = min(max(wd1, 0), 22528)

            let position = Int((nb >> 6) & 31)
            let shift = 10 - (nb >> 11)
            let scaled = shift < 0
                ? G722.ilb[position] << Int(-shift)
                : G722.ilb[position] >> Int(shift)
            det = scaled << 2
        }
    }

    // MARK: - Кодер

    /// Кодер G.722. Живёт ровно столько, сколько разговор: состояние
    /// предсказателя нельзя ни переиспользовать между звонками, ни сбросить
    /// посреди потока.
    public struct Encoder {

        private var low = Band()
        private var high = Band()
        /// Окно квадратурного фильтра: 24 последних отсчёта.
        private var window = [Int32](repeating: 0, count: 24)

        public init() {}

        /// Кодирует отсчёты 16 кГц. Их количество обязано быть чётным: один байт
        /// приходится ровно на пару.
        public func encoded(_ samples: [Int16]) -> [UInt8] {
            var copy = self
            return copy.encode(samples)
        }

        public mutating func encode(_ samples: [Int16]) -> [UInt8] {
            var output = [UInt8]()
            output.reserveCapacity(samples.count / 2)

            var index = 0
            while index + 1 < samples.count {
                // Квадратурный фильтр анализа: пара отсчётов на входе даёт по
                // одному отсчёту в каждой полосе.
                for position in 0..<22 {
                    window[position] = window[position + 2]
                }
                window[22] = Int32(samples[index])
                window[23] = Int32(samples[index + 1])
                index += 2

                var sumEven: Int32 = 0
                var sumOdd: Int32 = 0
                for tap in 0..<12 {
                    sumOdd &+= window[2 * tap] &* qmfCoefficients[tap]
                    sumEven &+= window[2 * tap + 1] &* qmfCoefficients[11 - tap]
                }
                let xLow = saturate((sumEven &+ sumOdd) >> 14)
                let xHigh = saturate((sumEven &- sumOdd) >> 14)

                output.append(UInt8(truncatingIfNeeded: encodePair(xLow: xLow, xHigh: xHigh)))
            }
            return output
        }

        private mutating func encodePair(xLow: Int32, xHigh: Int32) -> Int32 {
            // Нижняя полоса: шестибитный квантователь.
            let errorLow = saturate(xLow - low.s)
            let magnitude = errorLow >= 0 ? errorLow : -(errorLow + 1)
            var step = 1
            while step < 30 {
                if magnitude < (q6[step] &* low.det) >> 12 { break }
                step += 1
            }
            let indexLow = errorLow < 0 ? iln[step] : ilp[step]

            let quarter = indexLow >> 2
            let deltaLow = (low.det &* qm4[Int(quarter)]) >> 15
            low.scaleLow(index: quarter)
            low.update(with: deltaLow)

            // Верхняя полоса: двухбитный квантователь.
            let errorHigh = saturate(xHigh - high.s)
            let magnitudeHigh = errorHigh >= 0 ? errorHigh : -(errorHigh + 1)
            let threshold = (564 &* high.det) >> 12
            let level = magnitudeHigh >= threshold ? 2 : 1
            let indexHigh = errorHigh < 0 ? ihn[level] : ihp[level]

            let deltaHigh = (high.det &* qm2[Int(indexHigh)]) >> 15
            high.scaleHigh(index: indexHigh)
            high.update(with: deltaHigh)

            return (indexHigh << 6) | indexLow
        }
    }

    // MARK: - Декодер

    public struct Decoder {

        private var low = Band()
        private var high = Band()
        private var window = [Int32](repeating: 0, count: 24)

        public init() {}

        public mutating func decode(_ payload: [UInt8]) -> [Int16] {
            var output = [Int16]()
            output.reserveCapacity(payload.count * 2)

            for byte in payload {
                let code = Int32(byte)
                let indexLow = code & 0x3F
                let indexHigh = (code >> 6) & 0x03

                // Нижняя полоса восстанавливается по шестибитной таблице, а
                // предсказатель обновляется по четырёхбитной — так в
                // рекомендации, и это не описка: адаптация намеренно грубее
                // восстановления.
                let restoredLow = min(
                    max(low.s + ((low.det &* qm6[Int(indexLow)]) >> 15), -16384), 16383
                )
                let quarter = indexLow >> 2
                let deltaLow = (low.det &* qm4[Int(quarter)]) >> 15
                low.scaleLow(index: quarter)
                low.update(with: deltaLow)

                let deltaHigh = (high.det &* qm2[Int(indexHigh)]) >> 15
                let restoredHigh = min(max(high.s + deltaHigh, -16384), 16383)
                high.scaleHigh(index: indexHigh)
                high.update(with: deltaHigh)

                // Квадратурный фильтр синтеза: две полосы обратно в пару
                // отсчётов 16 кГц.
                for position in 0..<22 {
                    window[position] = window[position + 2]
                }
                window[22] = restoredLow + restoredHigh
                window[23] = restoredLow - restoredHigh

                var sumEven: Int32 = 0
                var sumOdd: Int32 = 0
                for tap in 0..<12 {
                    sumOdd &+= window[2 * tap] &* qmfCoefficients[tap]
                    sumEven &+= window[2 * tap + 1] &* qmfCoefficients[11 - tap]
                }
                output.append(Int16(saturate(sumEven >> 11)))
                output.append(Int16(saturate(sumOdd >> 11)))
            }
            return output
        }
    }
}
