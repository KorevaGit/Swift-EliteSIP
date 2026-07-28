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
    ///
    /// Не константа: подстраивается под замеренный джиттер сети. Фиксированное
    /// значение всегда неверно — на хорошей сети оно добавляет задержку зря, на
    /// плохой не спасает. Замеры на нашем же стенде давали то 7 недоборов за
    /// 45 секунд, то 34 за 21, при одной и той же тройке кадров.
    public private(set) var targetDepth: Int
    /// Нижняя граница подстройки. Ниже двух кадров любая неровность — недобор.
    public let minimumDepth: Int
    /// Глубина, после которой буфер догоняет реальное время, выбрасывая старое.
    public let maximumDepth: Int
    /// Тишина в текущем кодеке. Нужна на самый первый кадр, когда повторять
    /// ещё нечего.
    private let silencePayload: Data

    private let samplesPerFrame: Int
    private let clockRate: Int

    // MARK: Оценка джиттера
    // По RFC 3550 §6.4.1: сглаженное среднее отклонение интервалов прихода от
    // интервалов меток времени.

    private var previousArrival: (time: TimeInterval, timestamp: UInt32)?
    private var jitterEstimate = 0.0
    /// Сколько подряд выдач подряд запас оказывался избыточным. Растёт глубина
    /// сразу, уменьшается только после долгой спокойной жизни — иначе буфер
    /// начинает дёргаться туда-сюда и щёлкать на каждом изменении.
    private var calmPops = 0

    // MARK: Сокрытие потерь

    /// Последний по-настоящему пришедший кадр. Им и затыкается дыра: повтор
    /// звучит несравнимо лучше тишины, потому что сохраняет и громкость, и
    /// основной тон голоса.
    private var lastGoodPayload: Data?
    /// Сколько кадров подряд уже спрятано. Дальше предела повторять нельзя —
    /// получится заевшая пластинка.
    private var concealmentRun = 0

    private var frames: [UInt16: Frame] = [:]
    /// Номер кадра, который должен выйти следующим.
    private var nextSequence: UInt16?
    /// Самый свежий номер, который вообще приходил. Нужен только для учёта
    /// перестановок: до начала воспроизведения `nextSequence` ещё не задан, а
    /// пакеты уже могут приходить не по порядку.
    private var highestSequence: UInt16?
    /// Сколько раз номер обернулся через ноль. Нужен только для RTCP.
    private var sequenceCycles = 0
    private var firstSequence: UInt32?
    private var highestAtLastReport: Int64 = 0
    private var receivedAtLastReport: Int64 = 0
    private var isPrimed = false

    public private(set) var statistics = Statistics()

    /// Сколько кадров подряд можно спрятать повтором. Пять — это 100 мс:
    /// дольше повтор перестаёт быть незаметным и превращается в дребезг.
    public static let maximumConcealmentRun = 5

    public init(
        targetDepth: Int = 3,
        minimumDepth: Int = 2,
        maximumDepth: Int = 12,
        codec: AudioCodec = .pcmu,
        packetTimeMilliseconds: Int = defaultPacketTimeMilliseconds
    ) {
        precondition(minimumDepth >= 1, "буфер без запаса бессмыслен")
        precondition(maximumDepth >= minimumDepth, "предел не может быть меньше нижней границы")
        self.targetDepth = min(max(targetDepth, minimumDepth), maximumDepth)
        self.minimumDepth = minimumDepth
        self.maximumDepth = maximumDepth
        self.samplesPerFrame = Int(codec.timestampIncrement(forPacketTime: packetTimeMilliseconds))
        self.clockRate = Int(codec.rtpClockRate)
        self.silencePayload = codec.silencePayload(forPacketTime: packetTimeMilliseconds)
    }

    /// Замеренный джиттер сети в миллисекундах. Для журнала и для RTCP.
    public var jitterMilliseconds: Double {
        jitterEstimate / Double(clockRate) * 1000
    }

    /// Джиттер в единицах часов RTP — в таком виде он уезжает в отчёт RTCP.
    public var jitterInClockUnits: UInt32 {
        UInt32(min(max(jitterEstimate, 0), Double(UInt32.max)))
    }

    /// Самый свежий принятый номер, расширенный до 32 бит.
    ///
    /// В отчёте RTCP старшая половина — счётчик оборотов шестнадцатибитного
    /// номера. Без него собеседник не отличит первый круг от двадцатого и
    /// посчитает потери неверно после двадцати двух минут разговора.
    public var extendedHighestSequenceNumber: UInt32 {
        UInt32(sequenceCycles) << 16 | UInt32(highestSequence ?? 0)
    }

    /// Сколько пакетов не доехало за всё время, в терминах RFC 3550: сколько
    /// должно было прийти минус сколько пришло.
    public var cumulativePacketsLost: Int32 {
        guard let first = firstSequence else { return 0 }
        let expected = Int64(extendedHighestSequenceNumber) - Int64(first) + 1
        let lost = expected - Int64(statistics.received)
        return Int32(min(max(lost, Int64(Int32.min)), Int64(Int32.max)))
    }

    /// Доля потерь с прошлого отчёта, 0…1.
    public mutating func fractionLostSinceLastReport() -> Double {
        let expected = Int64(extendedHighestSequenceNumber) - Int64(highestAtLastReport)
        let received = Int64(statistics.received) - Int64(receivedAtLastReport)

        highestAtLastReport = Int64(extendedHighestSequenceNumber)
        receivedAtLastReport = Int64(statistics.received)

        guard expected > 0 else { return 0 }
        let lost = max(expected - received, 0)
        return min(Double(lost) / Double(expected), 1)
    }

    public var depth: Int { frames.count }

    public var isEmpty: Bool { frames.isEmpty }

    // MARK: - Приём

    /// Кладёт пакет в буфер.
    ///
    /// Время прихода передаётся явно, а не берётся внутри: без этого оценку
    /// джиттера нельзя проверить тестом, а именно она решает, какую задержку
    /// будет держать разговор. Часы монотонные — настройка системного времени
    /// посреди разговора не должна выглядеть как всплеск джиттера.
    public mutating func push(
        _ packet: RTPPacket,
        arrivedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        statistics.received += 1
        updateJitter(with: packet, arrivedAt: arrivedAt)

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
            // Оборот счётчика: новый номер меньше прежнего, хотя он новее.
            if let highest = highestSequence, packet.sequenceNumber < highest {
                sequenceCycles += 1
            }
            highestSequence = packet.sequenceNumber
        }
        if firstSequence == nil {
            firstSequence = UInt32(packet.sequenceNumber)
            highestAtLastReport = Int64(packet.sequenceNumber)
        }

        frames[packet.sequenceNumber] = Frame(
            sequenceNumber: packet.sequenceNumber,
            timestamp: packet.timestamp,
            payload: packet.payload
        )

        trimIfOverflowing()
    }

    /// Оценка джиттера по RFC 3550 §6.4.1.
    ///
    /// Считается разница между тем, насколько разошлись приходы пакетов, и тем,
    /// насколько разошлись их метки времени. Для ровного потока она нулевая;
    /// всё, что сеть добавила от себя, оседает здесь. Сглаживание с
    /// коэффициентом 1/16 — из того же параграфа: оно достаточно инертно, чтобы
    /// один опоздавший пакет не раздувал буфер.
    private mutating func updateJitter(with packet: RTPPacket, arrivedAt: TimeInterval) {
        defer { previousArrival = (arrivedAt, packet.timestamp) }
        guard let previous = previousArrival else { return }

        let arrivalDelta = (arrivedAt - previous.time) * Double(clockRate)
        // Метки времени тоже переполняются, поэтому разность берётся со знаком
        // через Int32 — иначе один переход через ноль даёт джиттер в сутки.
        let timestampDelta = Double(Int32(bitPattern: packet.timestamp &- previous.timestamp))
        let deviation = abs(arrivalDelta - timestampDelta)

        jitterEstimate += (deviation - jitterEstimate) / 16
    }

    /// Пересчитывает целевую глубину под замеренный джиттер.
    ///
    /// Запас — удвоенный джиттер плюс кадр. Удвоение не суеверие: оценка по RFC
    /// это среднее отклонение, а держать надо близко к пику, иначе половина
    /// всплесков окажется недоборами.
    ///
    /// Растёт глубина сразу, а уменьшается только после долгого спокойствия.
    /// Несимметрично намеренно: не набрать вовремя — это слышимый провал, а
    /// лишний кадр запаса — двадцать миллисекунд, которых никто не замечает.
    private mutating func adaptTargetDepth() {
        let needed = (2 * jitterEstimate + Double(samplesPerFrame)) / Double(samplesPerFrame)
        let desired = min(max(Int(needed.rounded(.up)), minimumDepth), maximumDepth)

        if desired > targetDepth {
            targetDepth = desired
            calmPops = 0
            return
        }

        guard desired < targetDepth else {
            calmPops = 0
            return
        }

        // 250 выдач — это пять секунд разговора при 20 мс на кадр.
        calmPops += 1
        if calmPops >= 250 {
            targetDepth -= 1
            calmPops = 0
        }
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
    /// nil означает «подожди»: буфер набирает запас. Потерянный или ещё не
    /// доехавший кадр возвращается как сокрытие — повтор последнего хорошего, —
    /// и это заметно лучше тишины: сохраняются и громкость, и основной тон, так
    /// что одиночная потеря на слух почти не читается. Затухание накладывает
    /// воспроизведение, ему для этого и сообщается `isConcealment`.
    public mutating func pop() -> Frame? {
        if !isPrimed {
            // Пока не набралась целевая глубина, не начинаем: иначе первый же
            // всплеск джиттера вызовет недобор.
            guard frames.count >= targetDepth else { return nil }
            isPrimed = true
            nextSequence = oldestSequence()
            concealmentRun = 0
        }

        guard let next = nextSequence else { return nil }

        if let frame = frames.removeValue(forKey: next) {
            nextSequence = next &+ 1
            lastGoodPayload = frame.payload
            concealmentRun = 0
            adaptTargetDepth()
            return frame
        }

        // Ожидаемого кадра нет. Пустой буфер — это недобор, непустой — потеря
        // одного кадра, но играть в обоих случаях всё равно что-то надо.
        if frames.isEmpty {
            if concealmentRun == 0 {
                statistics.underruns += 1
            }
            // Дальше предела повторять нельзя: если поток встал совсем,
            // повтор превратится в дребезг. Отдаём nil и копим заново.
            if concealmentRun >= Self.maximumConcealmentRun {
                isPrimed = false
                concealmentRun = 0
                // Ожидаемый номер сбрасывается вместе с накоплением. Иначе он
                // остаётся впереди на все спрятанные кадры, и первый же пакет,
                // пришедший после перерыва, будет отвергнут как опоздавший —
                // разговор после короткого пропадания сети не восстановится.
                nextSequence = nil
                return nil
            }
        }

        statistics.concealed += 1
        concealmentRun += 1
        nextSequence = next &+ 1
        return Frame(
            sequenceNumber: next,
            timestamp: 0,
            payload: lastGoodPayload ?? silencePayload,
            isConcealment: true
        )
    }

    public mutating func reset() {
        frames.removeAll()
        nextSequence = nil
        highestSequence = nil
        isPrimed = false
        lastGoodPayload = nil
        concealmentRun = 0
        previousArrival = nil
        jitterEstimate = 0
        calmPops = 0
        sequenceCycles = 0
        firstSequence = nil
        highestAtLastReport = 0
        receivedAtLastReport = 0
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
