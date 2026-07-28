import Foundation
import Testing
@testable import MediaCore

@Suite("Кольцо отсчётов")
struct SampleRingTests {

    /// Чтение через настоящий указатель: кольцо пишет ровно так же, как в
    /// буфер CoreAudio, и подменять этот путь на массив значит не проверить
    /// именно то место, где ошибка стоит щелчка.
    private func read(_ ring: inout SampleRing, _ count: Int) -> (samples: [Float], real: Int) {
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { storage.deallocate() }
        storage.initialize(repeating: .nan, count: count)

        let real = ring.read(into: storage, requested: count)
        return (Array(UnsafeBufferPointer(start: storage, count: count)), real)
    }

    @Test("Отдаёт записанное в том же порядке")
    func preservesOrder() {
        var ring = SampleRing(capacity: 16, targetFill: 8)
        ring.write([1, 2, 3, 4])

        let (samples, real) = read(&ring, 4)
        #expect(samples == [1, 2, 3, 4])
        #expect(real == 4)
        #expect(ring.available == 0)
    }

    @Test("Недостающее добивает тишиной, а не отдаёт меньше")
    func padsWithSilence() {
        var ring = SampleRing(capacity: 16, targetFill: 8)
        ring.write([1, 2])

        let (samples, real) = read(&ring, 5)
        #expect(samples == [1, 2, 0, 0, 0], "движок воспримет короткий блок как обрыв")
        #expect(real == 2, "по разнице между запрошенным и настоящим и считаются недоборы")
    }

    @Test("Переживает переход через край хранилища")
    func wrapsAround() {
        var ring = SampleRing(capacity: 8, targetFill: 4)

        ring.write([1, 2, 3, 4, 5, 6])
        _ = read(&ring, 5)
        // Голова уехала на позицию 5, запись пойдёт через край.
        ring.write([7, 8, 9, 10])

        let (samples, real) = read(&ring, 5)
        #expect(samples == [6, 7, 8, 9, 10])
        #expect(real == 5)
    }

    @Test("Не пишет сверх ёмкости")
    func respectsCapacity() {
        var ring = SampleRing(capacity: 4, targetFill: 4)

        let written = ring.write([1, 2, 3, 4, 5, 6])
        #expect(written == 4, "лишнее должно отбрасываться, а не затирать неиграное")
        #expect(ring.freeSpace == 0)

        let (samples, _) = read(&ring, 4)
        #expect(samples == [1, 2, 3, 4])
    }

    @Test("Недобор до цели показывает, сколько просить у джиттер-буфера")
    func reportsDeficit() {
        var ring = SampleRing(capacity: 480, targetFill: 320)
        #expect(ring.deficit == 320, "пустое кольцо просит весь запас")

        ring.write([Float](repeating: 0.5, count: 160))
        #expect(ring.deficit == 160, "ровно один кадр 20 мс")

        ring.write([Float](repeating: 0.5, count: 160))
        #expect(ring.deficit == 0, "запас набран — просить больше нечего")

        ring.write([Float](repeating: 0.5, count: 160))
        #expect(ring.deficit == 0, "сверх цели недобора не бывает")
    }

    @Test("Сброс возвращает кольцо в исходное состояние")
    func resets() {
        var ring = SampleRing(capacity: 8, targetFill: 4)
        ring.write([1, 2, 3, 4, 5])
        _ = read(&ring, 2)

        ring.removeAll()
        #expect(ring.available == 0)
        #expect(ring.freeSpace == 8)

        ring.write([9, 9])
        let (samples, _) = read(&ring, 2)
        #expect(samples == [9, 9], "после сброса указатели не должны помнить старое место")
    }
}
