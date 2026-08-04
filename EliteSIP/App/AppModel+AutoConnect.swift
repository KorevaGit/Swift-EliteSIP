import AppKit
import Network
import SIPCore

/// Автоматическое подключение к серверу.
///
/// Кнопки «Подключить» в панели больше нет: оператор не должен помнить, что
/// софтфон надо включить, — и, что важнее, не должен по ней промахиваться в
/// разговоре. Значит, поднимать и восстанавливать регистрацию обязано само
/// приложение.
///
/// Повторы самой регистрации делает `SIPUserAgent`: при отказе он ставит
/// следующую попытку с шагом backoff и живёт дальше. Здесь закрыты те случаи,
/// до которых агент не доживает или в которых он бессилен:
///
///   - запуск: агента ещё нет вовсе;
///   - сеть появилась после того, как её не было (ноутбук открыли вне офиса);
///   - сеть сменилась (Wi-Fi → кабель, другой шлюз): сокет остался на старом
///     маршруте, и переоткрывать транспорт надо целиком;
///   - пробуждение из сна: сокет пережил сон только формально.
extension AppModel {

    /// Запускается один раз при старте приложения.
    func startAutoConnect() {
        guard networkMonitor == nil else { return }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let isSatisfied = path.status == .satisfied
            let interfaces = Set(path.availableInterfaces.map(\.name))
            Task { @MainActor [weak self] in
                await self?.handleNetworkPath(isSatisfied: isSatisfied, interfaces: interfaces)
            }
        }
        // Очередь фоновая: обработчик всё равно сразу уходит на главный актор,
        // а держать наблюдателя на главной очереди незачем.
        monitor.start(queue: DispatchQueue(label: "com.elitesochi.elitesip.network"))
        networkMonitor = monitor

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.restoreAfterWake()
            }
        }

        Task { await connectIfPossible() }
    }

    func stopAutoConnect() {
        networkMonitor?.cancel()
        networkMonitor = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    /// Подключиться, если есть чем: заполненная учётка, пароль и отсутствие уже
    /// поднятого агента. Молчит, когда подключаться нечем, — это не ошибка, а
    /// обычное состояние ненастроенной машины.
    func connectIfPossible() async {
        guard canConnect else { return }
        await connect()
    }

    private func handleNetworkPath(isSatisfied: Bool, interfaces: Set<String>) async {
        let wasSatisfied = lastNetworkPathIsSatisfied
        let previousInterfaces = lastNetworkInterfaces
        lastNetworkPathIsSatisfied = isSatisfied
        lastNetworkInterfaces = interfaces

        guard isSatisfied else {
            if wasSatisfied {
                append(level: .warning, message: "сеть пропала — подключимся, когда вернётся")
            }
            return
        }

        if !isAgentRunning {
            if !wasSatisfied {
                append(level: .info, message: "сеть вернулась — подключаемся")
            }
            await connectIfPossible()
            return
        }

        // Маршрут сменился под уже поднятым агентом: сокет остался привязан к
        // прежнему интерфейсу, и повторный REGISTER по нему уйдёт в никуда.
        // Помогает только переоткрыть транспорт целиком.
        guard wasSatisfied, previousInterfaces != interfaces, !previousInterfaces.isEmpty else { return }
        append(level: .info, message: "сеть сменилась — переподключаемся")
        await reconnectIfIdle()
    }

    private func restoreAfterWake() async {
        guard isAgentRunning else {
            await connectIfPossible()
            return
        }
        append(level: .info, message: "пробуждение — переподключаемся")
        await reconnectIfIdle()
    }

    /// Переподключение, которое никогда не рвёт разговор.
    ///
    /// В разговоре не делаем ничего: регистрация нужна для входящих, а текущий
    /// звонок держится своим диалогом и переживёт смену сети чаще, чем её
    /// переживёт наша попытка всё переоткрыть. Когда разговор закончится, сеть
    /// либо уже устоится, либо следующее событие пути придёт снова.
    private func reconnectIfIdle() async {
        guard canDisconnect else {
            append(level: .info, message: "переподключение отложено: идёт разговор")
            return
        }
        await reconnect()
    }
}
