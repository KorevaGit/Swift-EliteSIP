import Testing
@testable import MediaCore

/// Владение общим аудиотрактом.
///
/// Проверяется без звуковой карты намеренно: разрешения на микрофон в CI никто
/// не выдаст, а ошибка здесь стоит заглушенного живого разговора — то есть
/// того, что на живом железе замечает уже собеседник.
@Suite("Владение аудиотрактом")
struct AudioOwnershipTests {

    /// Ключом служит ссылочная тождественность, поэтому в тесте нужны объекты.
    private final class Line {}

    @Test("Свободный тракт достаётся тому, кто попросил")
    func grantsFreeBus() {
        var ownership = AudioOwnership()
        let line = Line()
        #expect(!ownership.isBusy)
        let outcome = ownership.take(ObjectIdentifier(line))
        #expect(outcome == .granted)
        #expect(ownership.isBusy)
        #expect(ownership.isOwner(ObjectIdentifier(line)))
    }

    @Test("Снятая линия не глушит разговор на живой")
    func strangerCannotRelease() {
        var ownership = AudioOwnership()
        let live = Line()
        let removed = Line()

        _ = ownership.take(ObjectIdentifier(live))

        // Ровно тот случай, ради которого написан тип: отложенный `deinit`
        // снятой линии приходит отпускать тракт через секунду после того, как
        // его забрала другая линия. Отпустить он не имеет права.
        let releasedByStranger = ownership.release(ObjectIdentifier(removed))
        #expect(!releasedByStranger)
        #expect(ownership.isOwner(ObjectIdentifier(live)))
        #expect(ownership.isBusy)
    }

    @Test("Переключение линий отбирает тракт у прежней")
    func switchingLinesReplacesOwner() {
        var ownership = AudioOwnership()
        let first = Line()
        let second = Line()

        _ = ownership.take(ObjectIdentifier(first))
        let outcome = ownership.take(ObjectIdentifier(second))
        #expect(outcome == .replaced)
        #expect(ownership.isOwner(ObjectIdentifier(second)))
        #expect(!ownership.isOwner(ObjectIdentifier(first)))

        // И прежняя после этого не может отпустить чужое.
        let releasedByPrevious = ownership.release(ObjectIdentifier(first))
        #expect(!releasedByPrevious)
        #expect(ownership.isOwner(ObjectIdentifier(second)))
    }

    @Test("Повторный захват своего же тракта — не ошибка")
    func repeatedTakeIsIdempotent() {
        var ownership = AudioOwnership()
        let line = Line()

        _ = ownership.take(ObjectIdentifier(line))
        let outcome = ownership.take(ObjectIdentifier(line))
        #expect(outcome == .alreadyOwned)
        #expect(ownership.isOwner(ObjectIdentifier(line)))
    }

    @Test("Второй отбой по той же линии проходит вхолостую")
    func doubleReleaseIsHarmless() {
        var ownership = AudioOwnership()
        let line = Line()

        _ = ownership.take(ObjectIdentifier(line))
        let first = ownership.release(ObjectIdentifier(line))
        let second = ownership.release(ObjectIdentifier(line))
        #expect(first)
        #expect(!second)
        #expect(!ownership.isBusy)
    }

    @Test("Отпущенный тракт достаётся следующему")
    func releasedBusIsFree() {
        var ownership = AudioOwnership()
        let first = Line()
        let second = Line()

        _ = ownership.take(ObjectIdentifier(first))
        _ = ownership.release(ObjectIdentifier(first))
        let outcome = ownership.take(ObjectIdentifier(second))
        #expect(outcome == .granted)
    }
}
