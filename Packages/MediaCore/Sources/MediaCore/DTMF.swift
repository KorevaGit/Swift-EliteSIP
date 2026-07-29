import Foundation

/// Один шаг набора: тон или пауза.
///
/// Пауза — полноправный шаг, а не украшение: голосовые меню на той стороне
/// живые, и «набрать 2, дождаться приглашения, набрать добавочный» без пауз
/// превращается в один слипшийся набор, который меню не разбирает.
public enum DTMFStep: Sendable, Hashable {
    case tone(UInt8)
    case pause(milliseconds: Int)
}

/// Последовательность DTMF: то, что нажал оператор, или то, что записано в макросе.
///
/// Разбор строки живёт здесь, а не в приложении, ровно по той же причине, по
/// которой здесь же лежит SDP: это часть протокола, а не интерфейса, и
/// проверяется она таблицей, а не глазами.
public struct DTMFSequence: Sendable, Hashable {

    /// Пауза по умолчанию — секунда.
    ///
    /// Формат макроса заказчиком пока не задан (открытый вопрос 1 в README), и
    /// секунда взята как то, к чему привыкли по мобильным телефонам: там запятая
    /// в номере значит ровно это. Длительность настраивается.
    public static let defaultPauseMilliseconds = 1000

    /// Символы паузы. Запятая — как в номерах на телефоне, `p` — как в модемных
    /// строках набора; обе записи в ходу, и спорить о них незачем.
    public static let pauseCharacters: Set<Character> = [",", "p", "P"]

    /// Символы, которые в записи ничего не значат и просто повышают читаемость.
    public static let ignoredCharacters: Set<Character> = [" ", "-", "\t"]

    public var steps: [DTMFStep]

    public init(steps: [DTMFStep]) {
        self.steps = steps
    }

    /// Разбирает запись макроса. Непонятные символы молча пропускаются —
    /// проверять их до сохранения должен тот, кто макрос вводит: см.
    /// ``unsupportedCharacters(in:)``.
    public init(_ text: some StringProtocol, pauseMilliseconds: Int = defaultPauseMilliseconds) {
        var steps: [DTMFStep] = []
        for character in text {
            if Self.ignoredCharacters.contains(character) { continue }
            if Self.pauseCharacters.contains(character) {
                // Паузы подряд складываются: «,,» — это две секунды, и так
                // записывать удобнее, чем заводить второй символ.
                if case .pause(let already) = steps.last {
                    steps[steps.count - 1] = .pause(milliseconds: already + pauseMilliseconds)
                } else {
                    steps.append(.pause(milliseconds: pauseMilliseconds))
                }
                continue
            }
            if let event = TelephoneEventPayload.event(for: character) {
                steps.append(.tone(event))
            }
        }
        self.init(steps: steps)
    }

    public var isEmpty: Bool { steps.isEmpty }

    /// Есть ли в записи хоть один тон. Макрос из одних пауз бессмыслен.
    public var hasTones: Bool {
        steps.contains { if case .tone = $0 { true } else { false } }
    }

    /// Символы, которые разобрать не удалось. Для проверки ввода в настройках.
    public static func unsupportedCharacters(in text: some StringProtocol) -> [Character] {
        text.filter { character in
            !ignoredCharacters.contains(character)
                && !pauseCharacters.contains(character)
                && TelephoneEventPayload.event(for: character) == nil
        }
    }

    /// Как последовательность выглядит для человека: тоны как есть, пауза точкой.
    public var displayText: String {
        steps.map { step in
            switch step {
            case .tone(let event): TelephoneEventPayload.character(for: event).map(String.init) ?? "?"
            case .pause: "·"
            }
        }
        .joined()
    }
}

/// Сколько длится тон, пауза между тонами и как громко.
public struct DTMFTiming: Sendable, Hashable {

    /// Длительность самого тона. RFC 4733 требует минимум 40 мс, но телефонные
    /// меню на той стороне бывают глухие; 120 мс — то, что шлют аппаратные
    /// телефоны, и оно проходит везде.
    public var toneMilliseconds: Int

    /// Тишина между двумя тонами. Без неё две одинаковые цифры подряд
    /// принимающая сторона слышит как одну длинную.
    public var gapMilliseconds: Int

    /// Сколько раз повторить пакет конца события.
    ///
    /// Три — по RFC 4733 §2.5.1.2. Пакет конца ничем не защищён от потери, а
    /// потерянный конец означает тон, который у собеседника длится вечно.
    public var endPacketRepeats: Int

    /// Громкость в -dBm0: меньше значит громче. 10 — обычное значение.
    public var volume: UInt8

    /// Такт отправки. Совпадает с пакетным временем звука: события идут в том
    /// же потоке RTP и в том же ритме.
    public var packetTimeMilliseconds: Int

    public init(
        toneMilliseconds: Int = 120,
        gapMilliseconds: Int = 80,
        endPacketRepeats: Int = 3,
        volume: UInt8 = 10,
        packetTimeMilliseconds: Int = defaultPacketTimeMilliseconds
    ) {
        self.toneMilliseconds = toneMilliseconds
        self.gapMilliseconds = gapMilliseconds
        self.endPacketRepeats = endPacketRepeats
        self.volume = volume
        self.packetTimeMilliseconds = packetTimeMilliseconds
    }
}

/// Пакет события в готовом к отправке виде.
public struct DTMFPacket: Sendable, Hashable {

    public var payload: TelephoneEventPayload

    /// Маркер RTP. Ставится на первом пакете события — по нему принимающая
    /// сторона понимает, что начался новый тон, а не продолжается прежний.
    public var isFirst: Bool

    /// Последний пакет события. После него поток возвращается к звуку.
    public var completesEvent: Bool

    /// На сколько тактов сдвинуть метку времени, когда событие закончится.
    ///
    /// Внутри события метка не растёт (RFC 4733 §2.5.1: все пакеты одного
    /// нажатия несут время его начала), но время-то идёт. Если не досдвинуть
    /// метку на длительность тона, весь остаток разговора уедет назад
    /// относительно часов, и джиттер-буфер собеседника будет разгребать это
    /// как рассинхронизацию.
    public var timestampAdvance: UInt32
}

/// Что делать дальше: отправить пакет или подождать.
public enum DTMFAction: Sendable, Hashable {
    case packet(DTMFPacket)
    case wait(milliseconds: Int)
}

/// Раскладка набора на пакеты RTP.
///
/// Чистая функция от последовательности и таймингов — ровно по той же границе,
/// по которой в CallGuard отделена проверяемая часть от часов и мыши. Здесь
/// проверяется таблица пакетов, а сеть и сон остаются снаружи, в ``MediaSession``.
public enum DTMFPlanner {

    /// Такты часов telephone-event на один пакет.
    ///
    /// Часы события — всегда 8000 Гц (RFC 4733), независимо от кодека звука. У
    /// нас это совпадает с шагом метки времени и у G.711, и у G.722: последний
    /// по RFC 3551 тоже тактируется от 8000, хотя отсчётов в пакете вдвое больше.
    static func ticksPerPacket(_ packetTimeMilliseconds: Int) -> UInt32 {
        UInt32(packetTimeMilliseconds) * TelephoneEvent.clockRate / 1000
    }

    /// Пакеты одного тона: нарастающая длительность, потом повторённый конец.
    public static func actions(forEvent event: UInt8, timing: DTMFTiming = DTMFTiming()) -> [DTMFAction] {
        let ticks = ticksPerPacket(timing.packetTimeMilliseconds)
        let packetCount = max(1, timing.toneMilliseconds / max(timing.packetTimeMilliseconds, 1))
        let totalTicks = UInt32(packetCount) * ticks

        var actions: [DTMFAction] = []

        for index in 1...packetCount {
            let duration = UInt16(clamping: UInt32(index) * ticks)
            actions.append(.packet(DTMFPacket(
                payload: TelephoneEventPayload(
                    event: event, isEnd: false, volume: timing.volume, duration: duration
                ),
                isFirst: index == 1,
                completesEvent: false,
                timestampAdvance: 0
            )))
            actions.append(.wait(milliseconds: timing.packetTimeMilliseconds))
        }

        // Пакеты конца идут подряд, без пауз: это три копии одного и того же
        // сообщения, страховка от потери, а не три события.
        let repeats = max(1, timing.endPacketRepeats)
        for index in 1...repeats {
            actions.append(.packet(DTMFPacket(
                payload: TelephoneEventPayload(
                    event: event, isEnd: true, volume: timing.volume,
                    duration: UInt16(clamping: totalTicks)
                ),
                isFirst: false,
                completesEvent: index == repeats,
                timestampAdvance: totalTicks
            )))
        }

        return actions
    }

    /// Раскладка всей последовательности.
    public static func actions(for sequence: DTMFSequence, timing: DTMFTiming = DTMFTiming()) -> [DTMFAction] {
        var actions: [DTMFAction] = []
        var previousWasTone = false

        for step in sequence.steps {
            switch step {
            case .tone(let event):
                // Пауза между тонами нужна только между ними: перед первым
                // тоном она была бы задержкой на ровном месте.
                if previousWasTone, timing.gapMilliseconds > 0 {
                    actions.append(.wait(milliseconds: timing.gapMilliseconds))
                }
                actions.append(contentsOf: Self.actions(forEvent: event, timing: timing))
                previousWasTone = true

            case .pause(let milliseconds):
                actions.append(.wait(milliseconds: milliseconds))
                // Своя пауза заменяет междуцифровую: складывать их значит
                // получить секунду с хвостиком там, где просили секунду.
                previousWasTone = false
            }
        }

        return actions
    }
}
