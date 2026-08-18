import Foundation
import Testing
@testable import MediaCore

@Suite("Наблюдение за входящим потоком")
struct InboundStreamWatchTests {

    @Test("Пока пакеты идут, сообщать не о чем")
    func flowingIsQuiet() {
        var watch = InboundStreamWatch()
        var received = 0
        for tick in stride(from: 0.0, through: 10, by: 0.05) {
            received += 1
            #expect(watch.update(received: received, at: tick) == .flowing)
        }
    }

    @Test("Разбег в начале разговора не считается поломкой")
    func startupIsForgiven() {
        // RTP начинается сразу за подтверждением, но доли секунды разбега
        // законны. Ругаться на них — приучить оператора не читать сообщения.
        var watch = InboundStreamWatch(startupGrace: 3, stallTimeout: 2)
        #expect(watch.update(received: 0, at: 0) == .flowing)
        #expect(watch.update(received: 0, at: 2.9) == .flowing)
        #expect(watch.update(received: 1, at: 2.95) == .flowing)
    }

    @Test("Поток, который так и не начался, замечается")
    func neverStartedIsReported() {
        // Ровно случай стенда 3 августа: 29 секунд разговора, принято ноль
        // пакетов, и приложение об этом молчало.
        var watch = InboundStreamWatch(startupGrace: 3, stallTimeout: 2)
        #expect(watch.update(received: 0, at: 0) == .flowing)
        #expect(watch.update(received: 0, at: 3) == .neverStarted(seconds: 3))
        #expect(watch.update(received: 0, at: 29) == .neverStarted(seconds: 29))
    }

    @Test("Первый же пакет снимает тревогу")
    func firstPacketClearsTheAlarm() {
        var watch = InboundStreamWatch(startupGrace: 3, stallTimeout: 2)
        // Отсчёт идёт от первого замера, а не от нуля шкалы: наблюдение
        // заводится вместе с медиа, и «сколько ждём» считается от него.
        #expect(watch.update(received: 0, at: 100) == .flowing)
        #expect(watch.update(received: 0, at: 105) == .neverStarted(seconds: 5))
        #expect(watch.update(received: 1, at: 106) == .flowing)
    }

    @Test("Оборвавшийся поток замечается")
    func stallIsReported() {
        var watch = InboundStreamWatch(startupGrace: 3, stallTimeout: 2)
        _ = watch.update(received: 10, at: 0)
        #expect(watch.update(received: 10, at: 1.9) == .flowing, "две секунды ещё не прошли")
        #expect(watch.update(received: 10, at: 2) == .stalled(seconds: 2))
        #expect(watch.update(received: 10, at: 8) == .stalled(seconds: 8))
    }

    @Test("Вернувшийся поток снимает тревогу")
    func recoveryClearsTheStall() {
        var watch = InboundStreamWatch(startupGrace: 3, stallTimeout: 2)
        _ = watch.update(received: 10, at: 0)
        #expect(watch.update(received: 10, at: 3) == .stalled(seconds: 3))
        #expect(watch.update(received: 11, at: 4) == .flowing)
        // И отсчёт следующего перерыва идёт от возврата, а не от старого замера.
        #expect(watch.update(received: 11, at: 5) == .flowing)
        #expect(watch.update(received: 11, at: 6) == .stalled(seconds: 2))
    }

    @Test("Короткая потеря не поднимает тревогу")
    func shortLossIsNotAStall() {
        // Одиночные потери — дело джиттер-буфера, он их скрывает. Здесь ловится
        // только грубое, иначе сообщение обесценится.
        var watch = InboundStreamWatch(startupGrace: 3, stallTimeout: 2)
        _ = watch.update(received: 100, at: 0)
        // Сто миллисекунд тишины — пять потерянных кадров подряд, предел
        // сокрытия. Тревоги быть не должно.
        #expect(watch.update(received: 100, at: 0.1) == .flowing)
    }

    @Test("Сброс возвращает наблюдение в исходное")
    func resetStartsOver() {
        var watch = InboundStreamWatch(startupGrace: 3, stallTimeout: 2)
        _ = watch.update(received: 5, at: 0)
        #expect(watch.update(received: 5, at: 4) == .stalled(seconds: 4))
        watch.reset()
        // После сброса счётчик пакетов новой сессии начинается с нуля, и старое
        // значение не должно выглядеть как «поток уже шёл».
        #expect(watch.update(received: 0, at: 10) == .flowing)
        #expect(watch.update(received: 0, at: 13) == .neverStarted(seconds: 3))
    }
}

/// Состояние без подробностей.
///
/// Живой прогон 18 августа 2026: в архиве для поддержки 62 строки из 266
/// оказались одним и тем же предупреждением, повторённым двадцать раз в
/// секунду. Причина была в самом `State` — счётчик секунд внутри него растёт на
/// каждом опросе, и сравнение «состояние то же?» отвечало «нет» всегда, хотя
/// сказать надо было один раз на переходе.
@Suite("Состояние потока без подробностей")
struct InboundStreamWatchKindTests {

    @Test("Растущие секунды не меняют состояния")
    func growingSecondsKeepTheSameKind() {
        var watch = InboundStreamWatch(startupGrace: 1, stallTimeout: 1)

        // Первый замер задаёт начало отсчёта: фора считается от него, а не от
        // нуля шкалы.
        _ = watch.update(received: 0, at: 0)

        let first = watch.update(received: 0, at: 1.5)
        let later = watch.update(received: 0, at: 9.0)

        #expect(first != later, "подробности разные — секунд прошло больше")
        #expect(first.kind == later.kind, "а состояние одно, и говорить второй раз не о чем")
        #expect(first.kind == .neverStarted)
    }

    @Test("Переход между состояниями виден по тому же признаку")
    func kindChangesOnRealTransitions() {
        var watch = InboundStreamWatch(startupGrace: 1, stallTimeout: 1)

        #expect(watch.update(received: 0, at: 0.1).kind == .flowing)
        #expect(watch.update(received: 0, at: 2.0).kind == .neverStarted)
        #expect(watch.update(received: 1, at: 2.5).kind == .flowing)
        #expect(watch.update(received: 1, at: 4.0).kind == .stalled)
        #expect(watch.update(received: 2, at: 4.5).kind == .flowing)
    }
}
