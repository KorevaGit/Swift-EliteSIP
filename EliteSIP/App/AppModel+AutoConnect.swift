import AppKit
import MediaCore
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

        Task {
            await requestMicrophoneAccess()
            await connectIfPossible()
        }
    }

    /// Микрофон — один раз на запуске, до первой регистрации.
    ///
    /// Раньше разрешение спрашивалось при выходе на линию, и для софтфона без
    /// кнопки «Подключить» это неверный момент: регистрация поднимается сама,
    /// значит и системный диалог всплывает сам — под звонок, под смену сети,
    /// под пробуждение. Здесь он приходит на пустой экран сразу после запуска,
    /// когда оператор ещё смотрит на приложение, а не на входящий вызов.
    ///
    /// Второго разрешения больше нет: пароль от добавочного лежит в настройках
    /// профиля, а не в связке ключей, и ни у кого ничего не спрашивает.
    private func requestMicrophoneAccess() async {
        // Спрашиваем всегда, а не только при `notDetermined`: разбор «почему
        // нет звука» начинается с журнала, и запись о том, что доступа нет,
        // нужна там при каждом запуске, а не только при первом.
        if await VoiceAudioEngine.requestMicrophoneAccess() {
            append(level: .debug, message: "доступ к микрофону есть")
        } else {
            append(
                level: .warning,
                message: "нет доступа к микрофону — разрешите его в «Системных настройках → Конфиденциальность»"
            )
        }
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
        // Оператор ушёл с линии сам — и все остальные поводы подключиться
        // (сеть вернулась, машина проснулась, маршрут сменился) его решение не
        // отменяют. Иначе «Отключён» держался бы ровно до первой смены Wi-Fi.
        guard !isOfflineByChoice else { return }

        guard canConnect else {
            // Молчать здесь нельзя: без кнопки «Подключить» единственный след
            // отказа — строка состояния, а в журнале должно остаться, чего
            // именно не хватило и у какого профиля. Чинит это администратор в
            // «Управлении», и по журналу ему видно, что чинить.
            if let hint = setupHint {
                append(
                    level: .warning,
                    message: "автоподключение отложено: \(hint.lowercased()) — профиль «\(settings.profiles.active.label)», \(settings.account.username)@\(settings.account.domain)"
                )
            }
            return
        }
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

    // MARK: - Закрытый канал

    /// Канал закрылся насовсем.
    ///
    /// До появления этого пути такое состояние было тупиком, и самым дорогим из
    /// найденных аудитом. `NWConnection` в `.failed` не поднимается никаким
    /// `start()`, а поток его событий кончается — то есть транспорт мёртв, а
    /// узнать об этом было неоткуда. Регистрация продолжала ходить по кругу с
    /// backoff, каждая попытка падала мгновенно, и рабочее место молча выпадало
    /// из раздачи лидов до перезапуска приложения. На экране при этом стояло
    /// «повтор через N с» — обещание, которое не могло сбыться.
    ///
    /// Лечится это только пересборкой транспорта, и сделать её может лишь тот,
    /// кто его создавал, — то есть мы.
    func handleChannelClosed(reason: String) async {
        append(level: .error, message: "соединение с сервером закрыто: \(reason)")

        // Решение оператора уйти с линии сильнее любой автоматики — тот же
        // довод, что и в `connectIfPossible`.
        guard !isOfflineByChoice else { return }

        guard canDisconnect else {
            // Разговор рвать нельзя. Сигнализация к этому моменту уже мертва —
            // BYE не уйдёт, — но звук идёт своим сокетом и живёт, а оператор
            // говорит с клиентом. Пересоберём, как только линия освободится.
            isReconnectPending = true
            append(level: .info, message: "пересборка соединения отложена: идёт разговор")
            return
        }

        isReconnectPending = false
        await reconnect()
    }

    /// Пересобирает соединение, если оно этого ждало.
    ///
    /// Зовётся из `teardown`, когда снялась последняя линия.
    func reconnectIfPending() {
        guard isReconnectPending, canDisconnect, !isOfflineByChoice else { return }
        isReconnectPending = false
        append(level: .info, message: "разговор закончен — пересобираем соединение")
        Task { [weak self] in await self?.reconnect() }
    }

    // MARK: - Страховка

    /// Сколько отказов регистрации подряд считать поводом пересобрать всё.
    ///
    /// Пять — это около двух с половиной минут: backoff идёт 5, 10, 20, 40, 80.
    static let failuresBeforeRebuild = 5

    /// Не чаще раза в пять минут.
    static let safetyRebuildInterval: TimeInterval = 300

    /// Страховка от отказов, которые мы не научились узнавать.
    ///
    /// `channelClosed` закрывает те случаи, которые удалось перечислить.
    /// Перечислить все нельзя, а цена пропущенного — рабочее место без
    /// входящих до перезапуска, и узнаёт о нём не оператор, а колл-центр по
    /// недостаче лидов. Поэтому здесь стоит грубая мера: регистрация не
    /// поднимается подряд много раз — пересобираем соединение целиком, ровно
    /// как это сделал бы человек кнопкой.
    ///
    /// Две оговорки не дают ей превратиться в круг пересборок. Реже раза в пять
    /// минут — потому что есть отказы, которых пересборка не лечит в принципе
    /// (неверный пароль, выключенный на сервере TLS), и биться в них чаще
    /// бессмысленно. И только при свободных линиях — разговор дороже
    /// регистрации.
    func noteRegistrationFailed() {
        consecutiveRegistrationFailures += 1
        guard consecutiveRegistrationFailures >= Self.failuresBeforeRebuild else { return }
        guard isAgentRunning, canDisconnect, !isOfflineByChoice else { return }

        if let last = lastSafetyReconnect,
            Date().timeIntervalSince(last) < Self.safetyRebuildInterval
        {
            return
        }

        lastSafetyReconnect = Date()
        consecutiveRegistrationFailures = 0
        append(
            level: .warning,
            message: "регистрация не поднимается \(Self.failuresBeforeRebuild) раз подряд —"
                + " пересобираем соединение"
        )
        Task { [weak self] in await self?.reconnect() }
    }
}
