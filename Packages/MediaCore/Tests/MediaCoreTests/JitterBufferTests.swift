import Foundation
import Testing
@testable import MediaCore

@Suite("Джиттер-буфер")
struct JitterBufferTests {

    private func packet(_ sequence: UInt16, timestamp: UInt32? = nil, byte: UInt8 = 0x11) -> RTPPacket {
        RTPPacket(
            payloadType: 0,
            sequenceNumber: sequence,
            timestamp: timestamp ?? UInt32(sequence) &* 160,
            ssrc: 0x1234,
            payload: Data(repeating: byte, count: 160)
        )
    }

    private func makeBuffer(target: Int = 3, maximum: Int = 12) -> JitterBuffer {
        JitterBuffer(targetDepth: target, maximumDepth: maximum)
    }

    @Test("До набора целевой глубины ничего не отдаёт")
    func waitsForPrefill() {
        var buffer = makeBuffer(target: 3)

        buffer.push(packet(1))
        #expect(buffer.pop() == nil, "одного кадра мало: первый же всплеск джиттера вызовет недобор")
        buffer.push(packet(2))
        #expect(buffer.pop() == nil)

        buffer.push(packet(3))
        let frame = buffer.pop()
        #expect(frame?.sequenceNumber == 1, "начинаем с самого старого кадра")
    }

    @Test("Отдаёт кадры по порядку")
    func popsInOrder() {
        var buffer = makeBuffer(target: 2)
        for sequence in UInt16(10)...UInt16(14) {
            buffer.push(packet(sequence))
        }

        var order: [UInt16] = []
        while let frame = buffer.pop() {
            order.append(frame.sequenceNumber)
        }
        #expect(order == [10, 11, 12, 13, 14])
    }

    @Test("Переставленные пакеты выстраиваются обратно")
    func reordersPackets() {
        var buffer = makeBuffer(target: 3)
        // Пришли не по порядку — ровно то, ради чего буфер и существует.
        buffer.push(packet(3))
        buffer.push(packet(1))
        buffer.push(packet(2))

        var order: [UInt16] = []
        while let frame = buffer.pop() {
            order.append(frame.sequenceNumber)
        }
        #expect(order == [1, 2, 3])
        #expect(buffer.statistics.reordered > 0)
    }

    @Test("Потерянный кадр заменяется тишиной, а не задержкой")
    func concealsLoss() {
        var buffer = makeBuffer(target: 2)
        buffer.push(packet(1))
        buffer.push(packet(3))   // второй потерян
        buffer.push(packet(4))

        #expect(buffer.pop()?.sequenceNumber == 1)

        let concealed = buffer.pop()
        #expect(concealed?.sequenceNumber == 2)
        #expect(concealed?.isConcealment == true)
        // Заглушка — тишина в том же кодеке и той же длины: иначе поедет
        // выравнивание кадров на воспроизведении.
        #expect(concealed?.payload.count == 160)
        #expect(concealed?.payload.allSatisfy { $0 == G711.muLawSilence } == true)

        #expect(buffer.pop()?.sequenceNumber == 3)
        #expect(buffer.statistics.concealed == 1)
    }

    @Test("Опоздавший пакет отбрасывается, а не вставляется задним числом")
    func dropsLatePackets() {
        var buffer = makeBuffer(target: 2)
        buffer.push(packet(5))
        buffer.push(packet(6))
        #expect(buffer.pop()?.sequenceNumber == 5)
        #expect(buffer.pop()?.sequenceNumber == 6)

        // Пятый доехал, когда его время давно прошло.
        buffer.push(packet(5))
        #expect(buffer.statistics.late == 1)
        #expect(buffer.depth == 0, "вставлять его назад некуда — звук уже сыгран")
    }

    @Test("Дубликаты не размножают звук")
    func dropsDuplicates() {
        var buffer = makeBuffer(target: 2)
        buffer.push(packet(1))
        buffer.push(packet(1))
        buffer.push(packet(2))

        #expect(buffer.statistics.duplicated == 1)
        #expect(buffer.depth == 2)
    }

    @Test("Распухший буфер догоняет реальное время")
    func trimsWhenOverflowing() {
        // Иначе задержка растёт и уже не возвращается: разговор превращается
        // в переписку с задержкой в секунды.
        var buffer = makeBuffer(target: 3, maximum: 6)
        for sequence in UInt16(1)...UInt16(20) {
            buffer.push(packet(sequence))
        }

        #expect(buffer.depth <= 6)
        #expect(buffer.statistics.dropped > 0)

        // Продолжаем с самых свежих кадров, а не с начала.
        let frame = buffer.pop()
        #expect(frame != nil)
        #expect(frame!.sequenceNumber > 10, "догонять надо вперёд, отдан \(frame!.sequenceNumber)")
    }

    @Test("Пустой буфер сообщает о недоборе и переходит к накоплению")
    func reportsUnderrun() {
        var buffer = makeBuffer(target: 2)
        buffer.push(packet(1))
        buffer.push(packet(2))
        #expect(buffer.pop()?.sequenceNumber == 1)
        #expect(buffer.pop()?.sequenceNumber == 2)

        #expect(buffer.pop() == nil)
        #expect(buffer.statistics.underruns == 1)

        // После недобора буфер снова копит запас, а не отдаёт по одному кадру.
        buffer.push(packet(3))
        #expect(buffer.pop() == nil, "одного кадра снова мало")
        buffer.push(packet(4))
        #expect(buffer.pop()?.sequenceNumber == 3)
    }

    @Test("Переполнение шестнадцатибитного счётчика не ломает порядок")
    func handlesSequenceWraparound() {
        // Наивное сравнение a < b ломается раз на 65536 пакетов — примерно раз
        // в 22 минуты разговора. Проявляется как секунда тишины на ровном месте.
        var buffer = makeBuffer(target: 3)
        buffer.push(packet(65_534))
        buffer.push(packet(65_535))
        buffer.push(packet(0))
        buffer.push(packet(1))

        var order: [UInt16] = []
        while let frame = buffer.pop() {
            order.append(frame.sequenceNumber)
        }
        #expect(order == [65_534, 65_535, 0, 1])
    }

    @Test("Сравнение номеров с учётом переполнения")
    func sequenceComparison() {
        #expect(JitterBuffer.isOlder(1, than: 2))
        #expect(!JitterBuffer.isOlder(2, than: 1))
        // Через границу: 65535 старше нуля, а не новее.
        #expect(JitterBuffer.isOlder(65_535, than: 0))
        #expect(!JitterBuffer.isOlder(0, than: 65_535))
        #expect(!JitterBuffer.isOlder(5, than: 5))
    }

    @Test("Сброс возвращает буфер в исходное состояние")
    func resetClearsState() {
        var buffer = makeBuffer(target: 2)
        buffer.push(packet(1))
        buffer.push(packet(2))
        _ = buffer.pop()

        buffer.reset()
        #expect(buffer.isEmpty)
        #expect(buffer.pop() == nil)

        // После сброса принимаются любые номера, включая меньшие прежних.
        buffer.push(packet(1))
        buffer.push(packet(2))
        #expect(buffer.pop()?.sequenceNumber == 1)
    }

    @Test("Заглушка соответствует кодеку")
    func concealmentMatchesCodec() {
        var buffer = JitterBuffer(targetDepth: 2, codec: .pcma)
        buffer.push(packet(1))
        buffer.push(packet(3))
        buffer.push(packet(4))
        _ = buffer.pop()

        let concealed = buffer.pop()
        #expect(concealed?.isConcealment == true)
        #expect(concealed?.payload.allSatisfy { $0 == G711.aLawSilence } == true)
    }

    @Test("Поток с потерями и перестановками проигрывается без сбоев порядка")
    func survivesMessyStream() {
        var buffer = makeBuffer(target: 3, maximum: 10)
        // Каждый седьмой теряется, каждый третий приходит с опережением.
        var incoming: [UInt16] = []
        for sequence in UInt16(1)...UInt16(60) where sequence % 7 != 0 {
            incoming.append(sequence)
        }
        for index in stride(from: 0, to: incoming.count - 1, by: 3) {
            incoming.swapAt(index, index + 1)
        }

        // Забираем ровно по одному кадру на пакет — так работает настоящее
        // воспроизведение, у которого свой ровный такт в 20 мс. Если вместо
        // этого выбирать буфер досуха, он после каждого недобора
        // пересинхронизируется, и пропуски просто перескакиваются вместо того,
        // чтобы маскироваться.
        var played: [UInt16] = []
        for sequence in incoming {
            buffer.push(packet(sequence))
            if let frame = buffer.pop() {
                played.append(frame.sequenceNumber)
            }
        }
        while let frame = buffer.pop() {
            played.append(frame.sequenceNumber)
        }

        // Главное свойство: на выход номера идут строго по возрастанию, без
        // повторов и без провалов назад.
        #expect(played == played.sorted())
        #expect(Set(played).count == played.count, "повторов быть не должно")
        #expect(played.count > 40, "проиграно всего \(played.count) кадров")
        #expect(buffer.statistics.concealed > 0, "потери должны быть замаскированы")
    }
}
