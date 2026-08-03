import Foundation

/// Что делать, когда тракт не удалось пересобрать.
///
/// **Зачем отдельный тип.** До этого политики не было вовсе: одна неудачная
/// пересборка означала конец разговора. `VoiceAudioEngine.rebuild` ловил любую
/// ошибку, объявлял `.broken`, и приложение вешало трубку. Для настоящей потери
/// устройства это верно — молчащий разговор хуже завершённого, — но для
/// **временной** это приговор без вины.
///
/// А временная — обычный случай. Перевод AirPods на телефон и обратно снимает
/// устройство с Mac на несколько секунд: в этом окне CoreAudio законно
/// отказывает и в `setVoiceProcessingEnabled`, и в `engine.start()`. Прежний код
/// принимал этот отказ за окончательный и ронял звонок, который через секунду
/// починился бы сам. Хуже того, движок после отказа не воскресал никогда:
/// `runningFlag` сбрасывался, а `scheduleRebuild` выходит по нему же — даже
/// вернувшиеся наушники уже ничего не меняли.
///
/// **Почему это отдельный тип, а не пара полей в движке.** Ровно затем, чтобы
/// эту логику можно было проверить тестом. `VoiceAudioEngine` без CoreAudio не
/// заводится, поэтому всё, что живёт внутри него, проверяется только руками — и
/// именно поэтому дефект дожил до боя. Здесь нет ни звуковой карты, ни времени
/// из системных часов: момент передаётся аргументом.
public struct AudioRestartPolicy: Sendable, Equatable {

    /// Решение по одной неудаче.
    public enum Decision: Sendable, Hashable {
        /// Пробуем ещё раз через столько секунд. `attempt` — номер попытки,
        /// начиная с первой; нужен для сообщения оператору.
        case retry(after: TimeInterval, attempt: Int)
        /// Отступаемся: звука больше не будет, разговор пора закрывать.
        case giveUp(attempts: Int, elapsed: TimeInterval)
    }

    /// Отсрочка перед первой повторной попыткой.
    ///
    /// Совпадает с окном склейки уведомлений о смене конфигурации, и это не
    /// совпадение: если устройство ещё в переходе, повторить раньше — значит
    /// получить тот же отказ и потратить попытку зря.
    public let firstDelay: TimeInterval
    /// Потолок отсрочки. Дальше растить бессмысленно: разговор идёт, и редкие
    /// попытки означают лишние секунды тишины после того, как устройство уже
    /// вернулось.
    public let maximumDelay: TimeInterval
    /// Сколько всего терпим, считая от первой неудачи.
    ///
    /// Десять секунд — это компромисс между двумя одинаково плохими исходами.
    /// Меньше — обрыв на обычном переходе Bluetooth, ради которого всё и
    /// затевалось. Больше — оператор десятки секунд говорит в тишину и всё
    /// равно теряет разговор, только позже и злее.
    public let budget: TimeInterval

    private var attempts = 0
    private var firstFailure: TimeInterval?
    private var nextDelay: TimeInterval

    public init(
        firstDelay: TimeInterval = 0.3,
        maximumDelay: TimeInterval = 2,
        budget: TimeInterval = 10
    ) {
        precondition(firstDelay > 0, "нулевая отсрочка — это цикл на отказе")
        precondition(maximumDelay >= firstDelay, "потолок не может быть меньше первой отсрочки")
        precondition(budget > 0, "нулевой запас терпения — это прежнее поведение")
        self.firstDelay = firstDelay
        self.maximumDelay = maximumDelay
        self.budget = budget
        self.nextDelay = firstDelay
    }

    /// Идёт ли сейчас серия попыток. По этому признаку движок отличает
    /// «тракта нет, но мы его чиним» от «тракта нет и не будет».
    public var isRecovering: Bool { firstFailure != nil }

    /// Сколько попыток уже сделано в текущей серии.
    public var attemptCount: Int { attempts }

    /// Записывает неудачу и говорит, что делать дальше.
    ///
    /// Момент передаётся аргументом, а не берётся из часов: иначе проверить
    /// исчерпание запаса можно было бы только реальным ожиданием.
    /// Часы обязаны быть монотонными — перевод системного времени посреди
    /// разговора не должен ни продлевать запас, ни сжигать его.
    public mutating func recordFailure(
        at now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Decision {
        attempts += 1
        let start = firstFailure ?? now
        firstFailure = start

        let elapsed = max(now - start, 0)
        // Проверяем ДО выдачи отсрочки, а не после неё: иначе последняя попытка
        // назначается на момент, когда запас уже кончился, и оператор ждёт
        // отсрочку впустую.
        guard elapsed + nextDelay <= budget else {
            return .giveUp(attempts: attempts, elapsed: elapsed)
        }

        let delay = nextDelay
        nextDelay = min(nextDelay * 2, maximumDelay)
        return .retry(after: delay, attempt: attempts)
    }

    /// Тракт собрался — серия закончена, счётчики в исходное.
    public mutating func recordSuccess() {
        attempts = 0
        firstFailure = nil
        nextDelay = firstDelay
    }
}
