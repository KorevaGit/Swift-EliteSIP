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
        JitterBuffer(targetDepth: target, minimumDepth: target, maximumDepth: maximum)
    }

    /// Номера настоящих кадров, без сокрытий.
    ///
    /// Раньше здесь хватало `while let frame = buffer.pop()`: буфер отдавал nil,
    /// как только настоящие кадры кончались. Теперь дыру он затыкает повтором
    /// последнего хорошего, поэтому выдача сама не заканчивается — и вызовы надо
    /// ограничивать снаружи.
    private func drain(_ buffer: inout JitterBuffer, calls: Int = 40) -> [UInt16] {
        var result: [UInt16] = []
        for _ in 0..<calls {
            guard let frame = buffer.pop() else { break }
            if !frame.isConcealment {
                result.append(frame.sequenceNumber)
            }
        }
        return result
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

        #expect(drain(&buffer) == [10, 11, 12, 13, 14])
    }

    @Test("Переставленные пакеты выстраиваются обратно")
    func reordersPackets() {
        var buffer = makeBuffer(target: 3)
        // Пришли не по порядку — ровно то, ради чего буфер и существует.
        buffer.push(packet(3))
        buffer.push(packet(1))
        buffer.push(packet(2))

        #expect(drain(&buffer) == [1, 2, 3])
        #expect(buffer.statistics.reordered > 0)
    }

    @Test("Потерянный кадр заменяется повтором последнего, а не тишиной")
    func concealsLossByRepeating() {
        var buffer = makeBuffer(target: 2)
        buffer.push(packet(1, byte: 0x7A))
        buffer.push(packet(3))   // второй потерян
        buffer.push(packet(4))

        let good = buffer.pop()
        #expect(good?.sequenceNumber == 1)

        let concealed = buffer.pop()
        #expect(concealed?.sequenceNumber == 2)
        #expect(concealed?.isConcealment == true)
        // Длина обязана совпадать с кадром, иначе поедет выравнивание на
        // воспроизведении.
        #expect(concealed?.payload.count == 160)
        // И это именно повтор: тишина на месте потери слышна как провал, а
        // повтор сохраняет громкость и основной тон — одиночную потерю на слух
        // почти не поймать. Затухание накладывает воспроизведение.
        #expect(concealed?.payload == good?.payload)

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

    @Test("Опустевший буфер сначала прячет потерю, и только потом сдаётся")
    func concealsThenGivesUpOnUnderrun() {
        var buffer = makeBuffer(target: 2)
        buffer.push(packet(1))
        buffer.push(packet(2))
        #expect(buffer.pop()?.sequenceNumber == 1)
        #expect(buffer.pop()?.sequenceNumber == 2)

        // Короткий перерыв в потоке затыкается повтором: провал слышен, повтор
        // почти нет.
        for _ in 0..<JitterBuffer.maximumConcealmentRun {
            let frame = buffer.pop()
            #expect(frame?.isConcealment == true)
        }
        #expect(buffer.statistics.underruns == 1, "недобор считается один на весь перерыв, а не на кадр")

        // Дольше повторять нельзя — получится заевшая пластинка.
        #expect(buffer.pop() == nil)

        // И дальше буфер снова копит запас, а не отдаёт по одному кадру.
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

        #expect(drain(&buffer) == [65_534, 65_535, 0, 1])
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

    @Test("Пока повторять нечего, дыра затыкается тишиной кодека")
    func firstConcealmentFallsBackToSilence() {
        // Случай редкий, но настоящий: первый же ожидаемый кадр не доехал, и
        // хорошего кадра для повтора ещё не было. Тишина должна быть в текущем
        // кодеке — в A-law и µ-law это разные байты, и перепутать их значит
        // получить ровный треск вместо паузы.
        var buffer = JitterBuffer(targetDepth: 1, minimumDepth: 1, codec: .pcma)
        buffer.push(packet(2))
        buffer.push(packet(3))
        // Ждём первый номер, а пришли второй и третий: выдача начнётся со
        // второго, поэтому дыру создаём иначе — забираем второй и теряем третий.
        _ = buffer.pop()

        var buffer2 = JitterBuffer(targetDepth: 1, minimumDepth: 1, codec: .pcma)
        buffer2.push(packet(5))
        buffer2.push(packet(7))
        _ = buffer2.pop()          // пятый
        let concealed = buffer2.pop()   // шестого нет
        #expect(concealed?.isConcealment == true)
        #expect(concealed?.payload.count == 160)
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

    // MARK: - Подстройка глубины

    /// Поток пакетов с заданным разбросом прихода.
    ///
    /// Метки времени идут ровно, а приходы — вразнобой: это и есть джиттер в
    /// том смысле, в каком его считает RFC 3550.
    private func feed(
        _ buffer: inout JitterBuffer,
        packets: Int,
        packetTime: TimeInterval = 0.02,
        jitter: TimeInterval,
        drainingEvery: Bool = true
    ) {
        var arrival = 1000.0
        var wobble = jitter
        for index in 0..<packets {
            arrival += packetTime + wobble
            wobble = -wobble
            buffer.push(packet(UInt16(index + 1)), arrivedAt: arrival)
            if drainingEvery { _ = buffer.pop() }
        }
    }

    @Test("На ровной сети глубина опускается до нижней границы")
    func shrinksOnCalmNetwork() {
        var buffer = JitterBuffer(targetDepth: 6, minimumDepth: 2, maximumDepth: 12)
        // 300 пакетов — это шесть секунд, дольше окна спокойствия в пять.
        feed(&buffer, packets: 300, jitter: 0)

        #expect(buffer.jitterMilliseconds < 1)
        #expect(buffer.targetDepth < 6, "ровный поток не должен держать запас на шесть кадров")
    }

    @Test("Всплеск джиттера поднимает глубину сразу")
    func growsImmediatelyOnJitter() {
        var buffer = JitterBuffer(targetDepth: 2, minimumDepth: 2, maximumDepth: 12)
        // Разброс ±30 мс — это полтора кадра в каждую сторону, на таком буфер
        // из двух кадров гарантированно недобирает.
        feed(&buffer, packets: 120, jitter: 0.03)

        #expect(buffer.jitterMilliseconds > 20, "джиттер \(buffer.jitterMilliseconds) мс")
        #expect(buffer.targetDepth > 2, "запас обязан вырасти, глубина \(buffer.targetDepth)")
    }

    @Test("Глубина не выходит за заданные границы")
    func staysWithinBounds() {
        var buffer = JitterBuffer(targetDepth: 3, minimumDepth: 2, maximumDepth: 5)
        // Разброс в четверть секунды — заведомо больше потолка.
        feed(&buffer, packets: 200, jitter: 0.25)
        #expect(buffer.targetDepth <= 5)

        var calm = JitterBuffer(targetDepth: 3, minimumDepth: 3, maximumDepth: 12)
        feed(&calm, packets: 400, jitter: 0)
        #expect(calm.targetDepth >= 3, "ниже нижней границы опускаться нельзя")
    }

    @Test("Переполнение метки времени не выглядит как всплеск джиттера")
    func survivesTimestampWraparound() {
        // Метка времени тридцатидвухбитная и переполняется примерно раз в шесть
        // суток непрерывного разговора, но начальное значение случайно по
        // RFC 3550, так что переход может случиться на любой минуте. Наивная
        // разность даёт джиттер в сутки и раздувает буфер до потолка.
        var buffer = JitterBuffer(targetDepth: 2, minimumDepth: 2, maximumDepth: 12)
        var arrival = 500.0
        var timestamp = UInt32.max - 480

        for index in 0..<50 {
            arrival += 0.02
            timestamp = timestamp &+ 160
            buffer.push(
                RTPPacket(
                    payloadType: 0,
                    sequenceNumber: UInt16(index + 1),
                    timestamp: timestamp,
                    ssrc: 0x1234,
                    payload: Data(repeating: 0x11, count: 160)
                ),
                arrivedAt: arrival
            )
            _ = buffer.pop()
        }

        #expect(buffer.jitterMilliseconds < 5, "джиттер \(buffer.jitterMilliseconds) мс")
        #expect(buffer.targetDepth == 2)
    }
}
