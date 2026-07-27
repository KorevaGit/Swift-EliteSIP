import Foundation

/// Джиттер-буфер: превращает поток RTP-пакетов, приходящих неровно и не по
/// порядку, в ровную последовательность кадров для воспроизведения.
///
/// Нужен потому, что сеть не гарантирует ни порядок, ни равномерность. Без
/// буфера звук рассыпается на щелчки уже при джиттере в десяток миллисекунд, а
/// со слишком большим буфером разговор превращается в рацию. Отсюда две
/// настройки: целевая глубина (компромисс задержки и устойчивости) и предельная,
/// после которой буфер догоняет реальное время.
///
/// Тип намеренно синхронный и без состояния сети: он полностью тестируется без
/// сокетов и без звуковой карты.
public struct JitterBuffer: Sendable {

    public struct Frame: Sendable, Hashable {
        public var sequenceNumber: UInt16
        public var timestamp: UInt32
        public var payload: Data
        /// Кадр не пришёл и сгенерирован взамен потерянного.
        public var isConcealment: Bool

        public init(sequenceNumber: UInt16, timestamp: UInt32, payload: Data, isConcealment: Bool = false) {
            self.sequenceNumber = sequenceNumber
            self.timestamp = timestamp
            self.payload = payload
            self.isConcealment = isConcealment
        }
    }

    public struct Statistics: Sendable, Hashable {
        public var received = 0
        /// Пакеты, пришедшие после того, как их время уже прошло.
        public var late = 0
        public var duplicated = 0
        /// Кадры, которых не дождались и заменили заглушкой.
        public var concealed = 0
        /// Пакеты, выброшенные при переполнении буфера.
        public var dropped = 0
        /// Сколько раз буфер опустел и играть было нечего.
        public var underruns = 0
        /// Пакеты, пришедшие не в том порядке, но вовремя.
        public var reordered = 0

        public init() {}
    }

    /// Сколько кадров копить перед началом воспроизведения.
    public let targetDepth: Int
    /// Глубина, после которой буфер догоняет реальное время, выбрасывая старое.
    public let maximumDepth: Int
    /// Чем заполнять потерянный кадр.
    private let concealmentPayload: Data

    private var frames: [UInt16: Frame] = [:]
    /// Номер кадра, который должен выйти следующим.
    private var nextSequence: UInt16?
    /// Самый свежий номер, который вообще приходил. Нужен только для учёта
    /// перестановок: до начала воспроизведения `nextSequence` ещё не задан, а
    /// пакеты уже могут приходить не по порядку.
    private var highestSequence: UInt16?
    private var isPrimed = false

    public private(set) var statistics = Statistics()

    public init(
        targetDepth: Int = 3,
        maximumDepth: Int = 12,
        codec: AudioCodec = .pcmu,
        packetTimeMilliseconds: Int = defaultPacketTimeMilliseconds
    ) {
        precondition(targetDepth >= 1, "буфер без запаса бессмыслен")
        precondition(maximumDepth >= targetDepth, "предел не может быть меньше цели")
        self.targetDepth = targetDepth
        self.maximumDepth = maximumDepth
        // Заглушка — тишина в том же кодеке. Простейшее сокрытие потерь: оно не
        // маскирует пропажу так, как это делает интерполяция, зато не вносит
        // искажений и не требует состояния.
        self.concealmentPayload = Data(
            repeating: G711.silenceByte(for: codec),
            count: codec.byteCount(forPacketTime: packetTimeMilliseconds)
        )
    }

    public var depth: Int { frames.count }

    public var isEmpty: Bool { frames.isEmpty }

    // MARK: - Приём

    public mutating func push(_ packet: RTPPacket) {
        statistics.received += 1

        // Опоздавший пакет: его время уже прошло, вставлять некуда.
        if let next = nextSequence, Self.isOlder(packet.sequenceNumber, than: next) {
            statistics.late += 1
            return
        }

        guard frames[packet.sequenceNumber] == nil else {
            statistics.duplicated += 1
            return
        }

        if let highest = highestSequence, Self.isOlder(packet.sequenceNumber, than: highest) {
            statistics.reordered += 1
        } else {
            highestSequence = packet.sequenceNumber
        }

        frames[packet.sequenceNumber] = Frame(
            sequenceNumber: packet.sequenceNumber,
            timestamp: packet.timestamp,
            payload: packet.payload
        )

        trimIfOverflowing()
    }

    /// Если буфер распух, догоняем реальное время: иначе задержка растёт и
    /// уже не возвращается — разговор превращается в переписку.
    private mutating func trimIfOverflowing() {
        guard frames.count > maximumDepth else { return }

        while frames.count > targetDepth, let oldest = oldestSequence() {
            frames.removeValue(forKey: oldest)
            statistics.dropped += 1
        }
        nextSequence = oldestSequence()
    }

    // MARK: - Выдача

    /// Следующий кадр или nil, если играть пока нечего.
    ///
    /// nil означает «подожди»: либо буфер ещё набирается, либо случился
    /// недобор. Вызывающий в этот момент играет тишину.
    public mutating func pop() -> Frame? {
        if !isPrimed {
            // Пока не набралась целевая глубина, не начинаем: иначе первый же
            // всплеск джиттера вызовет недобор.
            guard frames.count >= targetDepth else { return nil }
            isPrimed = true
            nextSequence = oldestSequence()
        }

        guard let next = nextSequence else { return nil }

        if let frame = frames.removeValue(forKey: next) {
            nextSequence = next &+ 1
            return frame
        }

        // Ожидаемого кадра нет. Если в буфере есть более поздние — значит он
        // потерян, и ждать его дальше бессмысленно: подставляем заглушку и
        // идём вперёд.
        if !frames.isEmpty {
            statistics.concealed += 1
            nextSequence = next &+ 1
            return Frame(
                sequenceNumber: next,
                timestamp: 0,
                payload: concealmentPayload,
                isConcealment: true
            )
        }

        // Буфер пуст: играть нечего, но и терять позицию нельзя — пакет ещё
        // может прийти.
        statistics.underruns += 1
        isPrimed = false
        return nil
    }

    public mutating func reset() {
        frames.removeAll()
        nextSequence = nil
        highestSequence = nil
        isPrimed = false
    }

    public mutating func resetStatistics() {
        statistics = Statistics()
    }

    // MARK: - Порядковые номера

    /// Самый старый номер в буфере с учётом переполнения счётчика.
    private func oldestSequence() -> UInt16? {
        frames.keys.min { Self.isOlder($0, than: $1) }
    }

    /// Сравнение с учётом того, что номер шестнадцатибитный и переполняется.
    ///
    /// Наивное `a < b` ломается ровно один раз на каждые 65536 пакетов — это
    /// примерно раз в 22 минуты разговора при 20 мс на пакет. Ошибка выглядит
    /// как секунда тишины на ровном месте, и найти её потом почти невозможно.
    static func isOlder(_ lhs: UInt16, than rhs: UInt16) -> Bool {
        Int16(bitPattern: lhs &- rhs) < 0
    }
}
