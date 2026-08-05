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
            // Причину отказа уже написали в журнал и в строку состояния.
            // Следующая попытка придёт сама — со сменой сети, пробуждением или
            // сохранением пароля заново.
            guard await prepareSystemAccess() else { return }
            await connectIfPossible()

            // Пароля нет — спрашиваем его сами, здесь же, на запуске.
            //
            // Раньше запуск на этом и заканчивался: в строке состояния
            // появлялось «Нужен пароль», и всё. Кнопки «Подключить» нет, поле
            // пароля лежит в «Управлении» за административным паролем, и
            // человек, севший за машину, оставался перед софтфоном, который
            // сообщает о нехватке, но не принимает недостающее.
            if setupNeed == .password {
                onNeedsPassword?()
            }
        }
    }

    /// Всё, что просит разрешения у системы, — один раз на запуске, до первой
    /// регистрации.
    ///
    /// Разрешений два, и оба раньше спрашивались по ходу дела: микрофон — при
    /// выходе на линию, связка ключей — на чтении пароля внутри самой
    /// регистрации. Для софтфона без кнопки «Подключить» это неверный момент.
    /// Регистрация поднимается сама, значит, и запросы всплывают сами — под
    /// звонок, под смену сети, под пробуждение, — а отказ или незамеченный
    /// диалог оставляет оператора без линии без единого следа на экране.
    ///
    /// Порядок последовательный и он важен: два системных диалога разом человек
    /// читает как один, а отвечает на верхний. Сначала микрофон — он свой,
    /// приложение показывает его само; затем связка ключей — её диалог рисует
    /// система поверх всего.
    ///
    /// Возвращает `false`, если пароль сохранён, но связка ключей его не
    /// отдала: регистрировать нечем, и первый заход надо прекратить.
    private func prepareSystemAccess() async -> Bool {
        // Микрофон спрашиваем всегда, а не только при `notDetermined`: разбор
        // «почему нет звука» начинается с журнала, и запись о том, что доступа
        // нет, нужна там при каждом запуске, а не только при первом.
        if await VoiceAudioEngine.requestMicrophoneAccess() {
            append(level: .debug, message: "доступ к микрофону есть")
        } else {
            append(
                level: .warning,
                message: "нет доступа к микрофону — разрешите его в «Системных настройках → Конфиденциальность»"
            )
        }

        return await primeStoredPassword()
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
        guard canConnect else {
            // Молчать здесь нельзя: без кнопки «Подключить» единственный след
            // отказа — строка состояния, а в журнале должно остаться, чего
            // именно не хватило. Самый частый случай — пароль сохранён, но для
            // другого профиля: ключ связки это «номер@домен».
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
}
