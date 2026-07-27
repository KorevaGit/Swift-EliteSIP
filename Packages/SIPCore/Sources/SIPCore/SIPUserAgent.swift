import Foundation

/// Пользовательский агент SIP: регистрация и ответы на входящие запросы.
///
/// На M1 умеет ровно две вещи — держать регистрацию и отвечать на OPTIONS.
/// Второе не менее важно первого: chan_sip с `qualify=yes` опрашивает пир
/// каждые 30 секунд, и молчание в ответ переводит пир в UNREACHABLE, после чего
/// входящие звонки на него не приходят вообще.
public actor SIPUserAgent {

    public enum Event: Sendable {
        case registration(SIPRegistrationState)
        case log(level: SIPLogLevel, message: String)
        /// Запрос, на который мы ответили отказом, потому что он ещё не
        /// поддерживается. Нужен, чтобы такие вещи было видно, а не только в логе.
        case unsupportedRequest(method: SIPMethod)
    }

    public static let defaultUserAgentName = "EliteSIP/0.1 (macOS)"

    private let account: SIPAccount
    private let credentials: DigestAuthentication.Credentials
    private let transactions: SIPTransactionLayer
    private let userAgentName: String

    public nonisolated let events: AsyncStream<Event>
    private nonisolated let eventContinuation: AsyncStream<Event>.Continuation

    // Идентификаторы серии регистраций: Call-ID и tag постоянны, пока агент жив.
    private let registrationCallID = SIPToken.callID()
    private let localTag = SIPToken.tag()
    private var cseq = 0

    /// Адрес, который мы указываем в Contact. Сначала локальный, после первого
    /// ответа — тот, которым нас видит сервер.
    private var contactEndpoint: SIPEndpoint?
    private var cachedChallenge: (challenge: DigestChallenge, responseHeader: String)?
    private var nonceCount = 0

    private var state: SIPRegistrationState = .idle
    private var registrationTask: Task<Void, Never>?
    private var requestPumpTask: Task<Void, Never>?
    private var isStopping = false
    private var consecutiveFailures = 0

    public init(
        account: SIPAccount,
        credentials: DigestAuthentication.Credentials,
        channel: SIPTransportChannel,
        timers: SIPTransactionLayer.Timers = .init(),
        userAgentName: String = SIPUserAgent.defaultUserAgentName
    ) {
        self.account = account
        self.credentials = credentials
        self.transactions = SIPTransactionLayer(channel: channel, timers: timers)
        self.userAgentName = userAgentName

        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(256))
        events = stream
        eventContinuation = continuation
    }

    public var registrationState: SIPRegistrationState { state }

    // MARK: - Жизненный цикл

    public func start() async {
        guard registrationTask == nil else { return }
        isStopping = false

        await transactions.start()

        let inbound = transactions.inboundRequests
        requestPumpTask = Task { [weak self] in
            for await request in inbound {
                await self?.handle(inbound: request)
            }
        }

        registrationTask = Task { [weak self] in
            await self?.runRegistrationLoop()
        }
    }

    /// Немедленно перерегистрироваться, не дожидаясь планового обновления.
    ///
    /// Нужна и пользователю (кнопка «Переподключить»), и при смене сети: старая
    /// регистрация после смены адреса указывает не туда, и ждать её истечения
    /// значит не принимать звонки несколько минут.
    public func reregisterNow() async {
        guard !isStopping else { return }
        registrationTask?.cancel()
        consecutiveFailures = 0
        registrationTask = Task { [weak self] in
            await self?.runRegistrationLoop()
        }
    }

    /// Снимает регистрацию и закрывает канал.
    ///
    /// Снятие делается best-effort с коротким таймаутом: если сервер недоступен,
    /// приложение не должно висеть на выходе. Регистрация всё равно истечёт сама.
    public func stop() async {
        isStopping = true
        registrationTask?.cancel()
        registrationTask = nil

        if state.isRegistered {
            set(state: .unregistering)
            let unregister = Task { try await self.sendRegister(expires: 0) }
            let timeout = Task {
                try? await Task.sleep(for: .seconds(3))
                unregister.cancel()
            }
            _ = try? await unregister.value
            timeout.cancel()
        }

        requestPumpTask?.cancel()
        requestPumpTask = nil
        await transactions.stop()
        set(state: .idle)
        eventContinuation.finish()
    }

    // MARK: - Регистрация

    private func runRegistrationLoop() async {
        while !isStopping, !Task.isCancelled {
            do {
                set(state: .registering)
                let granted = try await register()
                consecutiveFailures = 0

                let expiresAt = Date().addingTimeInterval(Double(granted))
                let contact = contactEndpoint.map(\.description) ?? "—"
                set(state: .registered(expiresAt: expiresAt, contact: contact))
                log(.info, "зарегистрирован на \(granted) с, Contact \(contact)")

                let refreshAfter = Self.refreshInterval(forGrantedExpires: granted)
                log(.debug, "обновление регистрации через \(refreshAfter) с")
                try await Task.sleep(for: .seconds(refreshAfter))
            } catch is CancellationError {
                return
            } catch {
                guard !isStopping else { return }
                consecutiveFailures += 1
                let delay = Self.backoffDelay(forAttempt: consecutiveFailures)
                let reason = Self.describe(error)
                set(state: .failed(reason: reason, retryAt: Date().addingTimeInterval(Double(delay))))
                log(.warning, "регистрация не удалась: \(reason). Повтор через \(delay) с")
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
            }
        }
    }

    /// Одна попытка регистрации. Возвращает выданный сервером срок в секундах.
    private func register() async throws -> Int {
        var requestedExpires = account.registrationExpires

        // Попыток немного и они разные по смыслу: ответ на вызов, повтор с
        // увеличенным сроком по 423 и повтор с исправленным Contact после того,
        // как сервер сообщил наш внешний адрес.
        for _ in 0..<4 {
            let response = try await sendRegister(expires: requestedExpires)

            // Внешний адрес узнаём из ЛЮБОГО ответа, включая 401. Тогда повтор
            // с авторизацией уже несёт правильный Contact, и лишнего круга
            // регистрации не происходит.
            let contactChanged = learnObservedEndpoint(from: response)

            if response.isSuccess {
                if contactChanged {
                    log(.info, "Contact исправлен на внешний адрес, перерегистрируемся")
                    continue
                }
                return grantedExpires(from: response, requested: requestedExpires)
            }

            if response.isAuthenticationRequired {
                guard let offered = response.authenticationChallenges.first else {
                    throw RegistrationError.rejected(status: response.statusCode, reason: response.reasonPhrase)
                }
                // Новый вызов от сервера: сбрасываем счётчик nonce.
                cachedChallenge = offered
                nonceCount = 0
                continue
            }

            if response.statusCode == 423 {
                // Сервер считает срок слишком коротким и говорит минимум.
                guard let minimum = response.headers.integer(SIPHeaderName.minExpires),
                      minimum > requestedExpires
                else {
                    throw RegistrationError.rejected(status: 423, reason: "Interval Too Brief без Min-Expires")
                }
                log(.info, "сервер требует минимум \(minimum) с")
                requestedExpires = minimum
                continue
            }

            throw RegistrationError.rejected(status: response.statusCode, reason: response.reasonPhrase)
        }

        throw RegistrationError.tooManyAttempts
    }

    private func sendRegister(expires: Int) async throws -> SIPResponse {
        let request = try await makeRegister(expires: expires)
        log(.debug, "-> REGISTER expires=\(expires) cseq=\(cseq)")
        let response = try await transactions.send(request)
        log(.debug, "<- \(response.statusCode) \(response.reasonPhrase)")
        return response
    }

    private func makeRegister(expires: Int) async throws -> SIPRequest {
        let local = try await transactions.waitUntilReady()
        if contactEndpoint == nil {
            contactEndpoint = local
        }
        let contact = contactEndpoint ?? local

        var request = SIPRequest(method: .register, uri: account.registrarURI)

        // Via содержит адрес, С КОТОРОГО отправляем, а не тот, которым нас видно:
        // rport просит сервер сообщить второе, и подменять первое нельзя.
        var via = SIPVia(transport: account.transport, host: local.host, port: local.port)
        via.branch = SIPToken.branch()
        via.requestRport()
        request.headers.append(SIPHeaderName.via, via.description)

        request.headers.append(SIPHeaderName.maxForwards, "70")

        var from = NameAddress(
            displayName: account.displayName.isEmpty ? nil : account.displayName,
            uri: account.addressOfRecord
        )
        from.tag = localTag
        request.headers.append(SIPHeaderName.from, from.description)
        request.headers.append(SIPHeaderName.to, NameAddress(uri: account.addressOfRecord).description)
        request.headers.append(SIPHeaderName.callID, registrationCallID)

        cseq += 1
        request.headers.append(SIPHeaderName.cseq, "\(cseq) \(SIPMethod.register.rawValue)")

        var contactURI = SIPURI(user: account.username, host: contact.host, port: contact.port)
        if account.transport != .udp {
            contactURI[parameter: "transport"] = account.transport.rawValue
        }
        request.headers.append(SIPHeaderName.contact, NameAddress(uri: contactURI).description)

        request.headers.append(SIPHeaderName.expires, String(expires))
        request.headers.append(SIPHeaderName.allow, Self.allowedMethods)
        request.headers.append(SIPHeaderName.supported, "replaces")
        request.headers.append(SIPHeaderName.userAgent, userAgentName)

        // Упреждающая авторизация: если вызов уже известен, отвечаем сразу и
        // экономим полный обмен 401 на каждом обновлении. Если nonce устарел,
        // сервер пришлёт новый вызов, и мы повторим.
        if let cached = cachedChallenge {
            nonceCount += 1
            let value = try DigestAuthentication.authorizationValue(
                credentials: DigestAuthentication.Credentials(
                    username: account.effectiveAuthUsername,
                    password: credentials.password
                ),
                challenge: cached.challenge,
                method: .register,
                digestURI: account.registrarURI.description,
                nonceCount: nonceCount
            )
            request.headers.append(cached.responseHeader, value)
        }

        return request
    }

    /// Запоминает внешний адрес, сообщённый сервером в received/rport.
    ///
    /// Возвращает true, если адрес отличается от того, что уже стоит в Contact.
    /// Без этой правки при работе через NAT регистрация формально успешна, а
    /// входящие звонки уходят на локальный адрес и не доходят никогда.
    private func learnObservedEndpoint(from response: SIPResponse) -> Bool {
        guard let observed = response.topVia?.observedAddress,
              let port = observed.port
        else { return false }

        let discovered = SIPEndpoint(host: observed.host, port: port)
        guard discovered != contactEndpoint else { return false }

        log(.debug, "сервер видит нас как \(discovered), в Contact было \(contactEndpoint?.description ?? "—")")
        contactEndpoint = discovered
        return true
    }

    private func grantedExpires(from response: SIPResponse, requested: Int) -> Int {
        // Срок может приехать и в Expires, и параметром у Contact. Второе
        // приоритетнее: оно относится именно к нашей привязке.
        if let ours = response.contacts.first(where: { $0.uri.user == account.username })?.expires {
            return ours
        }
        if let contactExpires = response.contacts.compactMap(\.expires).first {
            return contactExpires
        }
        if let header = response.expires {
            return header
        }
        return requested
    }

    // MARK: - Входящие запросы

    private func handle(inbound request: SIPRequest) async {
        switch request.method {
        case .options:
            // Ответ на OPTIONS — это то, что держит пир в состоянии OK.
            var response = SIPResponse(statusCode: 200, headers: responseHeaders(for: request))
            response.headers.append(SIPHeaderName.allow, Self.allowedMethods)
            response.headers.append(SIPHeaderName.supported, "replaces")
            response.headers.append(SIPHeaderName.userAgent, userAgentName)
            try? await transactions.respond(to: request, with: response)
            log(.debug, "<- OPTIONS, ответили 200")

        case .invite:
            // Медиа появится в M2, а звонки — в M3. Пока честный отказ: тишина
            // заставила бы сервер ждать таймаута и держать канал.
            var response = SIPResponse(statusCode: 480, headers: responseHeaders(for: request))
            response.headers.append(SIPHeaderName.userAgent, userAgentName)
            try? await transactions.respond(to: request, with: response)
            eventContinuation.yield(.unsupportedRequest(method: .invite))
            log(.info, "входящий INVITE отклонён: приём звонков появится в M3")

        default:
            var response = SIPResponse(statusCode: 405, headers: responseHeaders(for: request))
            response.headers.append(SIPHeaderName.allow, Self.allowedMethods)
            try? await transactions.respond(to: request, with: response)
            eventContinuation.yield(.unsupportedRequest(method: request.method))
        }
    }

    /// Заголовки ответа, скопированные из запроса по RFC 3261 §8.2.6.2.
    private func responseHeaders(for request: SIPRequest) -> SIPHeaders {
        var headers = SIPHeaders()

        // Весь стек Via в исходном порядке — по нему ответ находит дорогу обратно.
        for via in request.headers.values(SIPHeaderName.via) {
            headers.append(SIPHeaderName.via, via)
        }
        if let from = request.headers[SIPHeaderName.from] {
            headers.append(SIPHeaderName.from, from)
        }

        // В To добавляем свой тег, если его там не было.
        if var to = request.to {
            if to.tag == nil {
                to.tag = localTag
            }
            headers.append(SIPHeaderName.to, to.description)
        }
        if let callID = request.headers[SIPHeaderName.callID] {
            headers.append(SIPHeaderName.callID, callID)
        }
        if let cseq = request.headers[SIPHeaderName.cseq] {
            headers.append(SIPHeaderName.cseq, cseq)
        }
        if let contact = contactEndpoint {
            var uri = SIPURI(user: account.username, host: contact.host, port: contact.port)
            if account.transport != .udp {
                uri[parameter: "transport"] = account.transport.rawValue
            }
            headers.append(SIPHeaderName.contact, NameAddress(uri: uri).description)
        }
        return headers
    }

    // MARK: - Служебное

    /// Список растёт по этапам, и в нём только то, что мы действительно
    /// обрабатываем. Заявить REFER или INFO заранее — значит соврать серверу:
    /// Asterisk на основании Allow решает, что нам можно присылать.
    /// REFER и NOTIFY добавятся в M5 (перевод), INFO — в M4 (DTMF по SIP INFO).
    static let allowedMethods = "INVITE, ACK, CANCEL, BYE, OPTIONS"

    /// Когда обновлять регистрацию.
    ///
    /// Обновляемся заведомо раньше истечения: если ждать до последней секунды,
    /// любая потеря пакета оставит нас незарегистрированными, и входящие звонки
    /// пропадут до следующей попытки.
    static func refreshInterval(forGrantedExpires expires: Int) -> Int {
        guard expires > 0 else { return 30 }
        if expires <= 20 { return max(expires - 5, 5) }
        return max(expires - 30, expires / 2)
    }

    /// Задержка перед повтором: 5, 10, 20, 40, 80, 160, дальше 300.
    static func backoffDelay(forAttempt attempt: Int) -> Int {
        guard attempt > 0 else { return 5 }
        let exponent = min(attempt - 1, 6)
        return min(5 << exponent, 300)
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case let error as RegistrationError: error.description
        case let error as SIPTransactionLayer.TransactionError:
            switch error {
            case .timeout: "сервер не ответил"
            case .transportFailed(let reason): "сеть: \(reason)"
            case .cancelled: "соединение закрыто"
            case .notReady: "транспорт не готов"
            }
        default: "\(error)"
        }
    }

    private func set(state newState: SIPRegistrationState) {
        guard state != newState else { return }
        state = newState
        eventContinuation.yield(.registration(newState))
    }

    private func log(_ level: SIPLogLevel, _ message: String) {
        eventContinuation.yield(.log(level: level, message: message))
    }

    public enum RegistrationError: Error, Sendable, Equatable, CustomStringConvertible {
        case rejected(status: Int, reason: String)
        case tooManyAttempts

        public var description: String {
            switch self {
            case .rejected(let status, let reason):
                switch status {
                case 403: "отказано: неверный логин или пароль (403)"
                case 404: "такого номера нет на сервере (404)"
                default: "сервер ответил \(status) \(reason)"
                }
            case .tooManyAttempts:
                "слишком много попыток подряд"
            }
        }
    }
}
