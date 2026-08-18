import Compat
import Darwin
import Foundation
import SIPCore

/// Разовая проверка «этот добавочный с этим паролем действительно встаёт на АТС».
///
/// Нужна мастеру первоначальной настройки (этап 9): без неё «мастер пройден»
/// означало бы только «поля заполнены», а неверный пароль обнаруживал бы не тот,
/// кто его вписал, а сотрудник, у которого через час не поднимется регистрация.
///
/// **Почему отдельно от `AppModel.connect`.** Тот поднимает рабочую регистрацию
/// из настроек и живёт до выхода: держит агент, качает события в панель, ведёт
/// историю. Проверке нужно обратное — взять данные, которых в настройках ещё нет,
/// один раз попробовать и убрать за собой, ничего не записав. Общий код здесь был
/// бы общим только по виду.
///
/// **Исходы разобраны типом, а не строкой.** `SIPRegistrationState.failed` несёт
/// готовую подпись для оператора, и она переведена — сравнивать её в коде нельзя.
/// Поэтому причина берётся из `SIPUserAgent.lastRegistrationFailure`, а сетевые
/// беды отделяются до регистрации, разрешением имени.
enum RegistrationProbe {

    /// Чем закончилась проверка.
    enum Outcome: Equatable {
        case registered
        /// Сети нет вовсе.
        case noNetwork
        /// Имя не разрешается: опечатка в адресе или нет DNS.
        case unknownHost
        /// АТС не ответила. На удалённом месте это же выглядит как не прошедший
        /// стук — различить их нечем, и обещать различие не надо.
        case noAnswer(isRemote: Bool)
        /// Сервер ответил, но не принял: 401, 403 или 404.
        case rejected

        /// Что показать техподдержке. Коротко и по делу: экран мастера — не
        /// место для разбора протокола, разбор уходит в журнал.
        var title: String {
            switch self {
            case .registered:
                return NSLocalizedString("Телефон зарегистрирован.", comment: "исход живой проверки регистрации")
            case .noNetwork:
                return NSLocalizedString("Нет сети. Проверьте подключение.", comment: "исход живой проверки регистрации")
            case .unknownHost:
                return NSLocalizedString("Адрес АТС не найден. Проверьте адрес.", comment: "исход живой проверки регистрации")
            case .noAnswer(let isRemote):
                return isRemote
                    ? NSLocalizedString("АТС не отвечает. Проверьте доступ к сети конторы.", comment: "исход живой проверки регистрации")
                    : NSLocalizedString("АТС не отвечает.", comment: "исход живой проверки регистрации")
            case .rejected:
                // Намеренно не различает, что именно не сошлось: на 401 сервер
                // этого не говорит, а угадывать в подписи — врать оператору.
                return NSLocalizedString("Неверный добавочный или пароль.", comment: "исход живой проверки регистрации")
            }
        }

        var isSuccess: Bool { self == .registered }
    }

    /// Пробует зарегистрироваться и убирает за собой.
    ///
    /// - Parameters:
    ///   - account: учётная запись целиком, уже с номером и доменом.
    ///   - password: пароль SIP.
    ///   - site: площадка. Решает, стучать ли перед регистрацией.
    ///   - knock: последовательность стука из настроек.
    ///   - acceptsAnyCertificate: доверие к сертификату TLS из того же профиля.
    ///     Проверка обязана ходить ровно так, как потом пойдёт рабочее
    ///     подключение: с системным доверием она отказывала бы на лабораторном
    ///     профиле с самоподписанным сертификатом там, где приложение
    ///     регистрируется, и говорила бы при этом «АТС не отвечает» — то есть
    ///     уводила бы искать сеть.
    ///   - log: куда писать подробности. В интерфейс уходит один исход, в
    ///     журнал — весь разбор: тому, кто потом читает жалобу «не
    ///     регистрируется», нужна именно трасса.
    static func run(
        account: SIPAccount,
        password: String,
        site: SIPProfileSite,
        knock: PortKnockSequence,
        acceptsAnyCertificate: Bool = false,
        log: @escaping @Sendable (SIPLogLevel, String) -> Void
    ) async -> Outcome {
        let host = account.signalingEndpoint.host
        let isRemote = PortKnockPolicy.needsKnocking(serverHost: host, site: site)

        // Имя разрешается до регистрации, и это не оптимизация: опечатка в адресе
        // иначе выглядит точно так же, как молчащая АТС, — тайм-аутом. Разница
        // для техподдержки существенная: в одном случае надо править поле, в
        // другом — идти смотреть сеть.
        switch await resolve(host: host) {
        case .resolved:
            break
        case .unknownHost:
            log(.warning, "живая проверка: адрес \(host) не разрешается")
            return .unknownHost
        case .noNetwork:
            log(.warning, "живая проверка: сети нет")
            return .noNetwork
        }

        let channel = NetworkSIPTransport(
            remote: account.signalingEndpoint,
            transport: account.transport,
            tlsTrust: acceptsAnyCertificate ? .acceptAnyCertificateInsecurely : .system,
            serverName: account.domain
        )
        let knocker = PortKnocker.forServer(host, site: site, sequence: knock) { level, message in
            log(level, message)
        }
        let agent = SIPUserAgent(
            account: account,
            credentials: DigestAuthentication.Credentials(
                username: account.effectiveAuthUsername,
                password: password
            ),
            channel: channel,
            pathOpener: knocker
        )

        log(.info, "живая проверка регистрации: \(account.username)@\(host)")

        // Срок ожидания складывается, а не берётся круглым числом: на удалённом
        // месте перед первым REGISTER уходит стук, и он один стоит несколько
        // секунд. Круглые «десять секунд» отсекали бы удалённые машины по
        // тайм-ауту раньше, чем они успевали постучать.
        let deadline = Interval.seconds(8) + knock.estimatedDuration
        let outcome = await attempt(agent: agent, within: deadline, isRemote: isRemote)

        // Убираем за собой всегда: агент проверки не должен пережить экран, иначе
        // он продолжит обновлять регистрацию рядом с рабочим агентом.
        await agent.stop()
        // не переводится: строка журнала. Решение этапа 8 — журнал остаётся
        // техническим, его сравнивают между машинами, и перевод сделал бы одно
        // событие двумя разными строками.
        log(
            outcome.isSuccess ? .info : .warning,
            "живая проверка: \(outcome.isSuccess ? "успех" : "неудача")"
        )
        return outcome
    }

    /// Ждёт исхода регистрации не дольше срока.
    private static func attempt(
        agent: SIPUserAgent,
        within deadline: Interval,
        isRemote: Bool
    ) async -> Outcome {
        let events = agent.events
        await agent.start()

        let waiting = Task { () -> Outcome? in
            for await event in events {
                guard case .registration(let state) = event else { continue }
                switch state {
                case .registered:
                    return .registered
                case .failed:
                    // Разбор — по типу из агента, а не по подписи состояния:
                    // подпись переведена и в коде не сравнивается.
                    if await agent.lastRegistrationFailure != nil { return .rejected }
                    return .noAnswer(isRemote: isRemote)
                case .idle, .registering, .unregistering:
                    continue
                }
            }
            return nil
        }

        let timeout = Task {
            try? await Task.sleep(deadline)
            waiting.cancel()
        }
        let outcome = await waiting.value
        timeout.cancel()

        // Ни одного решающего события за срок — значит АТС молчит. У удалённого
        // места это же означает «стук не дошёл», и различить их нечем: стук —
        // посылки ICMP без ответа.
        return outcome ?? .noAnswer(isRemote: isRemote)
    }

    // MARK: - Разрешение имени

    private enum Resolution {
        case resolved
        case unknownHost
        case noNetwork
    }

    /// Разрешает имя средствами системы.
    ///
    /// `getaddrinfo`, а не `NWPathMonitor`: нужен ответ на «этот адрес вообще
    /// существует», а не наблюдение за путём во времени. Числовой адрес
    /// (`192.168.1.2` из боевой предустановки) проходит здесь мгновенно и без
    /// сети — и это правильно: сеть у него проверяется уже попыткой регистрации.
    ///
    /// Различение «нет сети» и «имя не найдено» держится на коде ошибки:
    /// `EAI_NONAME` — такого имени нет, всё остальное (`EAI_FAIL`, `EAI_AGAIN`,
    /// отсутствие маршрута) считается отсутствием сети. Это огрубление, и оно
    /// названо: на машине без сети имя тоже «не найдено», но подсказка «проверьте
    /// подключение» полезнее, чем «проверьте адрес», ровно в этом случае.
    private static func resolve(host: String) async -> Resolution {
        // На своей очереди, а не на кооперативном пуле. Довод тот же, что у
        // `PortKnocker`, и записан там же: `getaddrinfo` умеет думать
        // секундами, а потоков в пуле немного, и один заблокированный отнимает
        // их у звука и у транзакций. Здесь это ровно тот случай — проверка идёт
        // из мастера, пока приложение уже работает.
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: blockingResolve(host: host)) }
        }
    }

    /// Отдельная очередь под блокирующие вызовы имени.
    private static let queue = DispatchQueue(label: "com.elitesip.registration-probe")

    private static func blockingResolve(host: String) -> Resolution {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?

        let status = getaddrinfo(host, nil, &hints, &result)
        if let result { freeaddrinfo(result) }

        guard status != 0 else { return .resolved }
        return status == EAI_NONAME ? .unknownHost : .noNetwork
    }
}
