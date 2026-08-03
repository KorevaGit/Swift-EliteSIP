import Foundation

/// Следит за тем, идёт ли вообще поток от собеседника.
///
/// **Зачем.** Разговор, в котором не пришло ни одного RTP-пакета, снаружи
/// выглядит ровно так же, как сломанный звук: в трубке тишина. Разница
/// принципиальная — в первом случае чинить надо сеть или собеседника, во втором
/// нас, — но по звуку она неразличима, и разбор каждый раз начинается с
/// нескольких неверных гипотез.
///
/// Случай не выдуманный. Разговор на стенде 3 августа 2026: 29 секунд, принято
/// **ноль** пакетов, при этом RTCP собеседника исправно приходил и сообщал 0 %
/// потерь на нашем потоке. То есть мы его слышать не могли по причине, к
/// аудиотракту отношения не имеющей, — а приложение за все 29 секунд не сказало
/// об этом ни слова. Итог виден только в сводке после звонка, когда разбираться
/// уже поздно.
///
/// **Что это не.** Не замена статистике потерь: одиночные потери и джиттер —
/// дело джиттер-буфера, он их скрывает и считает. Здесь ловится грубое —
/// «поток не начинался» и «поток кончился», то есть состояния, в которых
/// скрывать уже нечего.
///
/// Тип синхронный и без часов внутри: момент передаётся аргументом, поэтому
/// проверяется тестом целиком.
public struct InboundStreamWatch: Sendable {

    /// Что происходит с входящим потоком.
    public enum State: Sendable, Hashable {
        /// Пакеты идут. Обычное состояние, сообщать не о чем.
        case flowing
        /// Разговор идёт, но не пришло ещё ни одного пакета.
        case neverStarted(seconds: TimeInterval)
        /// Поток шёл и прекратился.
        case stalled(seconds: TimeInterval)
    }

    /// Сколько ждать первого пакета, прежде чем сказать о его отсутствии.
    ///
    /// Три секунды: RTP начинается сразу за подтверждением разговора, и любая
    /// законная задержка старта укладывается в доли секунды. Меньше — поймаем
    /// нормальный разбег и напугаем оператора зря.
    public let startupGrace: TimeInterval
    /// Сколько терпеть перерыв в уже идущем потоке.
    ///
    /// Две секунды: сокрытие потерь работает до 60 мс, джиттер-буфер держит
    /// запас в кадрах, то есть в десятках миллисекунд. Две секунды — это уже не
    /// сеть дрогнула, а поток встал.
    public let stallTimeout: TimeInterval

    private var lastCount = 0
    private var lastGrowth: TimeInterval?
    private var start: TimeInterval?
    private var hasEverReceived = false

    public init(startupGrace: TimeInterval = 3, stallTimeout: TimeInterval = 2) {
        precondition(startupGrace > 0 && stallTimeout > 0, "нулевой порог сработает на первом же опросе")
        self.startupGrace = startupGrace
        self.stallTimeout = stallTimeout
    }

    /// Принимает очередной замер счётчика принятых пакетов.
    ///
    /// Считает по приросту, а не по абсолютному значению: важно не сколько
    /// пришло всего, а идёт ли поток прямо сейчас.
    public mutating func update(
        received: Int,
        at now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> State {
        let start = self.start ?? now
        self.start = start

        if received > lastCount {
            lastCount = received
            lastGrowth = now
            hasEverReceived = true
            return .flowing
        }

        guard hasEverReceived else {
            let waiting = max(now - start, 0)
            return waiting >= startupGrace ? .neverStarted(seconds: waiting) : .flowing
        }

        let quiet = max(now - (lastGrowth ?? start), 0)
        return quiet >= stallTimeout ? .stalled(seconds: quiet) : .flowing
    }

    public mutating func reset() {
        lastCount = 0
        lastGrowth = nil
        start = nil
        hasEverReceived = false
    }
}
