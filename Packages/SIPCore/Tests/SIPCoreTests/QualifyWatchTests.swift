import Compat
import Testing

@testable import SIPCore

/// Сторож за опросом сервера.
///
/// Ловит расхождение, которое иначе не видно ниоткуда: регистрация свежая,
/// клиент показывает «На линии», а обратной дороги нет и звонки не приходят.
/// Разбирается это по журналу задним числом, когда лиды уже ушли соседям.
@Suite("Опрос сервера")
struct QualifyWatchTests {

    /// Боевая картина: `qualify` раз в минуту.
    private let minute = Interval.seconds(60)

    private func instant(_ seconds: Double) -> MonotonicClock.Instant {
        MonotonicClock.Instant(rawNanoseconds: UInt64(seconds * 1_000_000_000))
    }

    @Test("Одного опроса мало: судить не по чему")
    func silenceNeedsALearnedInterval() {
        var watch = QualifyWatch()
        watch.noteQualify(at: instant(0))

        // Интервал неизвестен, и молчать сервер может законно — например
        // потому, что qualify у него выключен вовсе.
        #expect(watch.silenceIfLost(at: instant(3600)) == nil)
    }

    @Test("Привычный интервал выучивается со второго опроса")
    func intervalIsLearned() {
        var watch = QualifyWatch()
        watch.noteQualify(at: instant(0))
        watch.noteQualify(at: instant(60))

        #expect(watch.learnedInterval == minute)
    }

    @Test("Один пропущенный опрос тревогой не считается")
    func singleMissIsTolerated() {
        var watch = QualifyWatch()
        watch.noteQualify(at: instant(0))
        watch.noteQualify(at: instant(60))

        // Два интервала молчания — это один потерянный пакет, а не потерянная
        // дорога. Дёргать регистрацию из-за него значит менять редкую беду на
        // частую.
        #expect(watch.silenceIfLost(at: instant(60 + 120)) == nil)
    }

    @Test("Три пропущенных опроса — потеря дороги")
    func threeMissesRaiseAlarm() {
        var watch = QualifyWatch()
        watch.noteQualify(at: instant(0))
        watch.noteQualify(at: instant(60))

        let silence = watch.silenceIfLost(at: instant(60 + 180))
        #expect(silence == .seconds(180))
    }

    @Test("Потери не задирают порог: интервал берётся минимальный")
    func lossesDoNotInflateTheInterval() {
        var watch = QualifyWatch()
        watch.noteQualify(at: instant(0))
        watch.noteQualify(at: instant(60))
        // Провал, ровно как в архиве 18 августа: 210 секунд тишины, потом опрос.
        watch.noteQualify(at: instant(270))

        // Если бы интервалом считался последний промежуток, порог стал бы
        // десятью минутами — сторож ослеп бы ровно после первого провала.
        #expect(watch.learnedInterval == minute)
        #expect(watch.silenceIfLost(at: instant(270 + 180)) == .seconds(180))
    }

    @Test("Внеочередной опрос после регистрации не занижает порог")
    func burstDoesNotShrinkTheInterval() {
        var watch = QualifyWatch()
        watch.noteQualify(at: instant(0))
        watch.noteQualify(at: instant(60))
        // Asterisk опрашивает пир сразу после REGISTER — промежуток в секунды.
        watch.noteQualify(at: instant(62))

        // Без нижней границы порог стал бы шестью секундами, и сторож
        // перерегистрировал бы машину каждые несколько секунд.
        #expect(watch.learnedInterval == QualifyWatch.minimumInterval)
        #expect(watch.silenceIfLost(at: instant(62 + 60)) == nil)
    }

    @Test("Тревога сдвигает отсчёт: в цикл она не уходит")
    func alarmDoesNotRepeatImmediately() {
        var watch = QualifyWatch()
        watch.noteQualify(at: instant(0))
        watch.noteQualify(at: instant(60))

        #expect(watch.silenceIfLost(at: instant(240)) != nil)
        // Сервер, до которого не достучаться вовсе, не должен превращаться в
        // поток перерегистраций.
        #expect(watch.silenceIfLost(at: instant(241)) == nil)
        #expect(watch.silenceIfLost(at: instant(300)) == nil)
        #expect(watch.silenceIfLost(at: instant(420)) != nil)
    }

    @Test("Удавшаяся регистрация считается доказательством дороги")
    func registrationCountsAsReachability() {
        var watch = QualifyWatch()
        watch.noteQualify(at: instant(0))
        watch.noteQualify(at: instant(60))

        // Ответ сервера на наш REGISTER дошёл — значит дорога есть, и молчание
        // опроса отсчитывается заново.
        watch.noteReachable(at: instant(200))
        #expect(watch.silenceIfLost(at: instant(300)) == nil)
        // При этом частоту опроса регистрация не переучивает.
        #expect(watch.learnedInterval == minute)
    }
}
