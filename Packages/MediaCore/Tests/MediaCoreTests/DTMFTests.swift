import Foundation
import Testing
@testable import MediaCore

/// Раскладка DTMF на пакеты RTP.
///
/// Проверяется здесь то, что на живой АТС стоит дороже всего и видно только в
/// дампе трафика: нарастающая длительность, неизменная метка времени внутри
/// события, повторённый конец и сдвиг метки после него. Каждая из этих ошибок
/// на слух выглядит одинаково — «меню не приняло цифру».
@Suite("DTMF")
struct DTMFTests {

    // MARK: - Разбор записи

    @Test("Разбирает цифры, звёздочку и решётку")
    func parsesDigits() {
        let sequence = DTMFSequence("12*#")
        #expect(sequence.steps == [.tone(1), .tone(2), .tone(10), .tone(11)])
        #expect(sequence.hasTones)
    }

    @Test("Запятые складываются в одну паузу")
    func mergesPauses() {
        let sequence = DTMFSequence("1,,2", pauseMilliseconds: 500)
        #expect(sequence.steps == [.tone(1), .pause(milliseconds: 1000), .tone(2)])
    }

    @Test("Пробелы и дефисы только для читаемости")
    func ignoresDecoration() {
        #expect(DTMFSequence("*022 998-#").steps == DTMFSequence("*022998#").steps)
    }

    @Test("Непонятные символы видны до сохранения макроса")
    func reportsUnsupportedCharacters() {
        #expect(DTMFSequence.unsupportedCharacters(in: "12ы3") == ["ы"])
        #expect(DTMFSequence.unsupportedCharacters(in: "*022998#,,").isEmpty)
        // A–D — законные события DTMF, хоть их и нет на клавиатуре телефона.
        #expect(DTMFSequence.unsupportedCharacters(in: "ABCD").isEmpty)
    }

    @Test("Макрос из одних пауз бесполезен и это видно")
    func pauseOnlyMacroHasNoTones() {
        #expect(!DTMFSequence(",,,").hasTones)
    }

    // MARK: - Пакеты одного тона

    @Test("Длительность нарастает по такту пакета")
    func durationGrows() {
        let timing = DTMFTiming(toneMilliseconds: 100, packetTimeMilliseconds: 20)
        let packets = DTMFTests.packets(DTMFPlanner.actions(forEvent: 5, timing: timing))

        // Пять пакетов тона по 20 мс: 160 тактов на пакет при часах 8000 Гц.
        let growing = packets.filter { !$0.payload.isEnd }
        #expect(growing.map(\.payload.duration) == [160, 320, 480, 640, 800])
        #expect(growing.allSatisfy { $0.payload.event == 5 })
    }

    @Test("Маркер стоит только на первом пакете события")
    func markerOnlyOnFirst() {
        let packets = DTMFTests.packets(DTMFPlanner.actions(forEvent: 1))
        #expect(packets.first?.isFirst == true)
        #expect(packets.dropFirst().allSatisfy { !$0.isFirst })
    }

    @Test("Конец события повторяется трижды и несёт полную длительность")
    func endPacketIsRepeated() {
        let timing = DTMFTiming(toneMilliseconds: 100, packetTimeMilliseconds: 20)
        let packets = DTMFTests.packets(DTMFPlanner.actions(forEvent: 7, timing: timing))
        let ends = packets.filter(\.payload.isEnd)

        // Пакет конца ничем не защищён от потери, а потерянный конец — это тон,
        // который у собеседника длится, пока не придёт следующий.
        #expect(ends.count == 3)
        #expect(ends.allSatisfy { $0.payload.duration == 800 })
        #expect(ends.filter(\.completesEvent).count == 1, "сдвигать метку времени надо ровно один раз")
        #expect(ends.last?.completesEvent == true)
    }

    @Test("Метка времени сдвигается на всю длительность тона, а не на один пакет")
    func advancesTimestampByWholeTone() {
        let timing = DTMFTiming(toneMilliseconds: 120, packetTimeMilliseconds: 20)
        let packets = DTMFTests.packets(DTMFPlanner.actions(forEvent: 0, timing: timing))
        let completing = packets.first { $0.completesEvent }

        // Шесть пакетов по 160 тактов. Сдвинуть на один пакет значило бы
        // отправить остаток разговора со сбитыми на 100 мс часами.
        #expect(completing?.timestampAdvance == 960)
    }

    @Test("Пакеты тона идут через такт, а конец — без пауз")
    func waitsBetweenPacketsButNotBetweenEnds() {
        let timing = DTMFTiming(toneMilliseconds: 40, packetTimeMilliseconds: 20)
        let actions = DTMFPlanner.actions(forEvent: 3, timing: timing)

        // Два пакета тона, между и после каждого — такт, затем три конца подряд.
        #expect(actions.count == 7)
        if case .wait(let milliseconds) = actions[1] {
            #expect(milliseconds == 20)
        } else {
            Issue.record("после первого пакета обязан быть такт")
        }
        #expect(actions.suffix(3).allSatisfy { if case .packet = $0 { true } else { false } })
    }

    @Test("Тон короче такта всё равно даёт хотя бы один пакет")
    func neverSendsEmptyTone() {
        let timing = DTMFTiming(toneMilliseconds: 5, packetTimeMilliseconds: 20)
        #expect(!DTMFTests.packets(DTMFPlanner.actions(forEvent: 9, timing: timing)).isEmpty)
    }

    // MARK: - Последовательность целиком

    @Test("Между двумя тонами появляется пауза")
    func separatesTones() {
        let timing = DTMFTiming(toneMilliseconds: 20, gapMilliseconds: 80, packetTimeMilliseconds: 20)
        let actions = DTMFPlanner.actions(for: DTMFSequence("11"), timing: timing)

        // Две одинаковые цифры подряд без паузы принимающая сторона слышит как
        // одну длинную — и добавочный номер получается на цифру короче.
        let gaps = actions.compactMap { action -> Int? in
            if case .wait(let milliseconds) = action, milliseconds == 80 { milliseconds } else { nil }
        }
        #expect(gaps.count == 1)
    }

    @Test("Перед первым тоном паузы нет")
    func noLeadingGap() {
        let actions = DTMFPlanner.actions(for: DTMFSequence("5"))
        guard case .packet = actions.first else {
            Issue.record("набор обязан начинаться с пакета, а не с ожидания")
            return
        }
    }

    @Test("Своя пауза заменяет междуцифровую, а не складывается с ней")
    func explicitPauseReplacesGap() {
        let timing = DTMFTiming(toneMilliseconds: 20, gapMilliseconds: 80, packetTimeMilliseconds: 20)
        let actions = DTMFPlanner.actions(
            for: DTMFSequence("1,2", pauseMilliseconds: 1000), timing: timing
        )
        let waits = actions.compactMap { action -> Int? in
            if case .wait(let milliseconds) = action { milliseconds } else { nil }
        }
        #expect(waits.contains(1000))
        #expect(!waits.contains(80), "1080 мс там, где просили секунду, — это уже не то, что записал оператор")
    }

    @Test("Отображение показывает паузы, а не прячет их")
    func displayTextShowsPauses() {
        #expect(DTMFSequence("*022,998#").displayText == "*022·998#")
    }

    private static func packets(_ actions: [DTMFAction]) -> [DTMFPacket] {
        actions.compactMap { if case .packet(let packet) = $0 { packet } else { nil } }
    }
}
