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
        /// Нам звонят. Дальше решает тот, кто это событие получил:
        /// `answerIncomingCall` или `rejectIncomingCall`.
        case incomingCall(SIPIncomingCall)
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

    /// Текущий звонок. Линия одна: несколько линий появятся в M5 вместе с
    /// переводом, и тогда это станет словарём по Call-ID.
    private var activeCall: ActiveCall?

    private struct ActiveCall {

        /// Кто кому позвонил. От этого зависит буквально всё: как завершать до
        /// ответа (CANCEL против 486), чей тег в каком заголовке и кто должен
        /// прислать ACK.
        enum Role { case caller, callee }

        let role: Role
        let callID: String
        let localTag: String
        let branch: String
        /// Номер CSeq INVITE. ACK на 2xx обязан повторить его.
        let inviteSequence: Int
        let continuation: AsyncStream<SIPCallEvent>.Continuation
        var dialog: SIPDialog?
        var state: SIPCallState

        /// Входящий INVITE целиком: на него надо отвечать, и не один раз.
        var inviteRequest: SIPRequest?

        /// Последнее тело SDP, которое мы отправили по этому звонку.
        ///
        /// Нужно на повторный INVITE без предложения: такой запрос означает
        /// «объяви заново, чем ты располагаешь», и отвечать на него надо тем,
        /// о чём уже договорились.
        var localSDP: Data?

        /// Наш повторный INVITE в пути.
        ///
        /// Встречное предложение в этот момент обязано получить 491, а не
        /// второй ответ: два пересогласования одного диалога, разошедшиеся в
        /// пути, — это классическая ничья, из которой без 491 не выбраться.
        var isRenegotiating = false

        /// REFER уже принят в работу. Второй перевод того же диалога до
        /// финального NOTIFY двусмысленен и потому отклоняется локально.
        var isTransferring = false
    }

    /// Активная подписка, созданная REFER. Ключ — Call-ID исходного диалога:
    /// NOTIFY приходит внутри него и тем же ключом однозначно находится.
    private var transferSubscriptions:
        [String: AsyncStream<SIPTransferEvent>.Continuation] = [:]
    private var transferTimeoutTasks: [String: Task<Void, Never>] = [:]

    private var state: SIPRegistrationState = .idle
    private var registrationTask: Task<Void, Never>?
    private var requestPumpTask: Task<Void, Never>?
    private var serverInvitePumpTask: Task<Void, Never>?
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

        let serverInvites = transactions.serverInviteEvents
        serverInvitePumpTask = Task { [weak self] in
            for await event in serverInvites {
                await self?.handle(serverInvite: event)
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

        // Сначала закрываем текущий диалог, пока транспорт ещё доступен. Иначе
        // приложение уже отключено, а сервер продолжает держать канал; поток
        // событий звонка также обязан завершиться до остановки event pump.
        await hangUp()

        if state.isRegistered {
            set(state: .unregistering)
            // Именно register(expires: 0), а не одиночный sendRegister: снятие
            // регистрации сервер тоже требует авторизовать, и без обработки 401
            // пир остаётся зарегистрированным до истечения срока.
            let unregister = Task { try await self.register(expires: 0) }
            let timeout = Task {
                try? await Task.sleep(for: .seconds(3))
                unregister.cancel()
            }
            _ = try? await unregister.value
            timeout.cancel()
        }

        requestPumpTask?.cancel()
        requestPumpTask = nil
        serverInvitePumpTask?.cancel()
        serverInvitePumpTask = nil
        await transactions.stop()
        set(state: .idle)
        eventContinuation.finish()
    }

    // MARK: - Регистрация

    private func runRegistrationLoop() async {
        while !isStopping, !Task.isCancelled {
            do {
                set(state: .registering)
                let granted = try await register(expires: account.registrationExpires)
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
    ///
    /// `expires: 0` означает снятие регистрации — путь тот же, включая
    /// обязательную авторизацию.
    private func register(expires: Int) async throws -> Int {
        var requestedExpires = expires
        /// Сколько раз в рамках этой попытки мы уже ответили на вызов сервера.
        var challengeAnswers = 0
        /// Сколько раз уже правили Contact по подсказке сервера.
        var contactCorrections = 0

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
                // Правим Contact не более одного раза за попытку. Некоторые NAT
                // (и vpnkit в Docker Desktop) выдают новый внешний порт чуть ли
                // не на каждую датаграмму — без ограничения регистрация уходила
                // бы в круг «исправили Contact, сервер видит новый порт» и
                // падала по числу попыток.
                if contactChanged, contactCorrections == 0 {
                    contactCorrections += 1
                    log(.info, "Contact исправлен на внешний адрес, перерегистрируемся")
                    continue
                }
                if contactChanged {
                    log(.debug, "сервер снова сообщил другой адрес; регистрацию принимаем как есть")
                }
                return grantedExpires(from: response, requested: requestedExpires)
            }

            if response.isAuthenticationRequired {
                guard let offered = response.authenticationChallenges.first else {
                    throw RegistrationError.rejected(status: response.statusCode, reason: response.reasonPhrase)
                }

                // Второй вызов подряд после того, как мы уже ответили, означает
                // неверные креды. Asterisk с alwaysauthreject=yes на неверный
                // пароль отвечает не 403, а тем же 401 — чтобы не выдавать,
                // существует ли такой номер. Без этой проверки самая частая
                // реальная ошибка выглядела бы как «слишком много попыток».
                if challengeAnswers >= 1, !offered.challenge.stale {
                    throw RegistrationError.authenticationFailed
                }

                cachedChallenge = offered
                nonceCount = 0
                challengeAnswers += 1
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

    // MARK: - Исходящий звонок

    public var callState: SIPCallState? { activeCall?.state }

    /// Идентификатор текущего установленного диалога для Replaces.
    ///
    /// Он нужен второму разговору при консультационном переводе. До ответа
    /// диалога ещё нет, поэтому возвращается nil.
    public var currentDialogIdentifier: SIPDialogIdentifier? {
        activeCall?.dialog.map(SIPDialogIdentifier.init(dialog:))
    }

    /// Адрес, который надо указывать в SDP.
    ///
    /// Это тот же адрес, что в Contact, то есть внешний, сообщённый сервером в
    /// received. Указать в SDP локальный адрес за NAT — значит получить
    /// установленный звонок без звука.
    public var mediaAddress: String? { contactEndpoint?.host }

    /// Звонит по номеру и отдаёт поток событий звонка.
    ///
    /// `offer` — готовое тело SDP. Слой сигнализации его не разбирает: медиа
    /// согласовывает вызывающий, и благодаря этому SIPCore не зависит ни от
    /// кодеков, ни от аудио, и тестируется без звуковой карты.
    public func placeCall(
        to target: String,
        offer: Data,
        contentType: String = "application/sdp"
    ) -> AsyncStream<SIPCallEvent> {
        let (stream, continuation) = AsyncStream<SIPCallEvent>.makeStream(bufferingPolicy: .bufferingNewest(32))

        func reject(_ error: SIPCallError) -> AsyncStream<SIPCallEvent> {
            continuation.yield(.failed(status: 0, reason: error.description))
            continuation.finish()
            return stream
        }

        guard activeCall == nil else { return reject(.alreadyInCall) }

        let number = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !number.isEmpty else { return reject(.emptyTarget) }

        Task { [weak self] in
            await self?.runCall(to: number, offer: offer, contentType: contentType, continuation: continuation)
        }
        return stream
    }

    private func runCall(
        to target: String,
        offer: Data,
        contentType: String,
        continuation: AsyncStream<SIPCallEvent>.Continuation
    ) async {
        let callID = SIPToken.callID()
        let localTag = SIPToken.tag()
        var sequence = 0

        // Две попытки, а не одна: chan_sip требует авторизацию не только на
        // REGISTER, но и на INVITE, и первый запрос уходит без неё.
        for attempt in 0..<2 {
            do {
                let local = try await transactions.waitUntilReady()
                sequence += 1

                let request = makeInvite(
                    to: target,
                    callID: callID,
                    localTag: localTag,
                    sequence: sequence,
                    offer: offer,
                    contentType: contentType,
                    local: local
                )
                guard let branch = request.topVia?.branch else {
                    finishCall(with: .failed(status: 0, reason: "не удалось собрать запрос"), continuation: continuation)
                    return
                }

                activeCall = ActiveCall(
                    role: .caller,
                    callID: callID,
                    localTag: localTag,
                    branch: branch,
                    inviteSequence: sequence,
                    continuation: continuation,
                    dialog: nil,
                    state: .dialing,
                    localSDP: offer
                )
                emitCallState(.dialing)
                log(.info, "-> INVITE \(target)")

                var needsRetryWithAuth = false

                // Выходим из цикла на первом же финальном событии, а не по
                // закрытию потока: после отказа транзакция ещё живёт таймером D
                // тридцать две секунды, и ждать их незачем.
                events: for await event in await transactions.sendInvite(request) {
                    switch event {
                    case .provisional(let response):
                        log(.debug, "<- \(response.statusCode) \(response.reasonPhrase)")
                        if response.statusCode >= 180 {
                            emitCallState(.ringing)
                        }

                    case .success(let response):
                        await handleCallAnswered(request: request, response: response, local: local)
                        return

                    case .failure(let response):
                        if response.isAuthenticationRequired,
                           attempt == 0,
                           let offered = response.authenticationChallenges.first {
                            cachedChallenge = offered
                            nonceCount = 0
                            needsRetryWithAuth = true
                            break events
                        }
                        let reason = describeCallFailure(status: response.statusCode, reason: response.reasonPhrase)
                        log(.info, "<- \(response.statusCode) \(response.reasonPhrase)")
                        finishCall(with: .failed(status: response.statusCode, reason: reason), continuation: continuation)
                        return

                    case .timeout:
                        finishCall(with: .failed(status: 408, reason: "сервер не ответил"), continuation: continuation)
                        return

                    case .transportFailed(let reason):
                        finishCall(with: .failed(status: 0, reason: "сеть: \(reason)"), continuation: continuation)
                        return
                    }
                }

                guard needsRetryWithAuth else {
                    finishCall(with: .failed(status: 0, reason: "звонок прерван"), continuation: continuation)
                    return
                }
            } catch {
                finishCall(with: .failed(status: 0, reason: Self.describe(error)), continuation: continuation)
                return
            }
        }

        finishCall(with: .failed(status: 401, reason: "сервер не принял авторизацию"), continuation: continuation)
    }

    private func handleCallAnswered(request: SIPRequest, response: SIPResponse, local: SIPEndpoint) async {
        guard var call = activeCall else { return }

        guard let dialog = SIPDialog(initiatorRequest: request, response: response) else {
            log(.error, "в 200 OK нет Contact — диалог собрать невозможно")
            finishCall(with: .failed(status: 0, reason: "ответ без Contact"), continuation: call.continuation)
            return
        }

        call.dialog = dialog
        call.state = .answered
        activeCall = call

        // ACK на 2xx идёт ВНЕ транзакции, по маршруту диалога и с тем же
        // номером CSeq, что у INVITE.
        var via = SIPVia(transport: account.transport, host: local.host, port: local.port)
        via.branch = SIPToken.branch()
        via.requestRport()
        let ack = dialog.makeRequest(
            .ack,
            sequence: call.inviteSequence,
            via: via,
            contact: localContact(local),
            userAgent: userAgentName
        )
        try? await transactions.sendWithoutTransaction(ack)

        log(.info, "<- 200 OK, отправлен ACK")
        call.continuation.yield(.state(.answered))
        call.continuation.yield(.answered(body: response.body, contentType: response.contentType))
    }

    // MARK: - Пересогласование медиа

    /// Как отвечать на чужой повторный INVITE. Задаёт приложение.
    private var mediaRenegotiator: SIPMediaRenegotiator?

    public func setMediaRenegotiator(_ handler: SIPMediaRenegotiator?) {
        mediaRenegotiator = handler
    }

    /// Пересогласовывает медиа внутри идущего разговора — наш повторный INVITE.
    ///
    /// Так делается удержание: отдельной команды «hold» в SIP нет, есть
    /// повторный INVITE со сменой направления в SDP. В консультационном
    /// переводе им же исходная линия ставится на удержание перед вторым
    /// звонком; сам перевод затем выполняется REFER с Replaces.
    ///
    /// Возвращает тело ответа — новый SDP собеседника. Разбирает его вызывающий:
    /// граница слоёв та же, что у обычного звонка.
    @discardableResult
    public func reinvite(offer: Data, contentType: String = "application/sdp") async throws -> Data {
        guard let existing = activeCall, existing.dialog != nil, existing.state == .answered else {
            throw SIPRenegotiationError.noActiveCall
        }
        guard !existing.isRenegotiating else { throw SIPRenegotiationError.alreadyRenegotiating }

        setRenegotiating(true, callID: existing.callID)
        defer { setRenegotiating(false, callID: existing.callID) }

        // Две попытки по той же причине, что и у первого INVITE: chan_sip
        // требует авторизацию и на повторный.
        for attempt in 0..<2 {
            let local: SIPEndpoint
            do {
                local = try await transactions.waitUntilReady()
            } catch {
                throw SIPRenegotiationError.transportFailed(Self.describe(error))
            }

            guard var call = activeCall, let dialog = call.dialog else {
                throw SIPRenegotiationError.noActiveCall
            }

            let (updated, sequence) = dialog.nextSequence()
            call.dialog = updated
            activeCall = call

            var via = SIPVia(transport: account.transport, host: local.host, port: local.port)
            via.branch = SIPToken.branch()
            via.requestRport()

            var request = updated.makeRequest(
                .invite,
                sequence: sequence,
                via: via,
                contact: localContact(local),
                userAgent: userAgentName
            )
            request.body = offer
            request.headers.append(SIPHeaderName.contentType, contentType)
            request.headers.append(SIPHeaderName.allow, Self.allowedMethods)
            request.headers.append(SIPHeaderName.supported, "replaces")
            if let cached = cachedChallenge,
               let value = try? authorization(for: .invite, uri: request.uri, challenge: cached) {
                request.headers.append(cached.responseHeader, value)
            }

            log(.debug, "-> повторный INVITE cseq=\(sequence)")

            var needsRetryWithAuth = false

            events: for await event in await transactions.sendInvite(request) {
                switch event {
                case .provisional:
                    continue

                case .success(let response):
                    await acknowledge(reinvite: response, sequence: sequence, local: local, offer: offer)
                    log(.info, "<- 200 OK на повторный INVITE")
                    return response.body

                case .failure(let response):
                    if response.isAuthenticationRequired,
                       attempt == 0,
                       let offered = response.authenticationChallenges.first {
                        cachedChallenge = offered
                        nonceCount = 0
                        needsRetryWithAuth = true
                        break events
                    }
                    // 491 — не ошибка сети и не отказ по существу: собеседник
                    // просто успел первым. Решать, ждать ли и повторять,
                    // должен вызывающий — он один знает, зачем звал.
                    if response.statusCode == 491 {
                        throw SIPRenegotiationError.requestPending
                    }
                    throw SIPRenegotiationError.rejected(
                        status: response.statusCode,
                        reason: response.reasonPhrase
                    )

                case .timeout:
                    throw SIPRenegotiationError.timeout

                case .transportFailed(let reason):
                    throw SIPRenegotiationError.transportFailed(reason)
                }
            }

            guard needsRetryWithAuth else {
                throw SIPRenegotiationError.timeout
            }
        }

        throw SIPRenegotiationError.rejected(status: 401, reason: "сервер не принял авторизацию")
    }

    private func setRenegotiating(_ value: Bool, callID: String) {
        guard var call = activeCall, call.callID == callID else { return }
        call.isRenegotiating = value
        activeCall = call
    }

    /// Подтверждает 200 OK на наш повторный INVITE и запоминает новые параметры.
    private func acknowledge(
        reinvite response: SIPResponse,
        sequence: Int,
        local: SIPEndpoint,
        offer: Data
    ) async {
        guard var call = activeCall, var dialog = call.dialog else { return }

        // Contact в ответе может смениться: RFC 3261 §12.2.1.2 называет это
        // обновлением цели, и пропустить его значит слать следующий BYE туда,
        // где собеседника уже нет.
        if let contact = response.contacts.first?.uri {
            dialog.remoteTarget = contact
        }
        call.dialog = dialog
        call.localSDP = offer
        activeCall = call

        var via = SIPVia(transport: account.transport, host: local.host, port: local.port)
        via.branch = SIPToken.branch()
        via.requestRport()
        let ack = dialog.makeRequest(
            .ack,
            sequence: sequence,
            via: via,
            contact: localContact(local),
            userAgent: userAgentName
        )
        try? await transactions.sendWithoutTransaction(ack)
    }

    // MARK: - Перевод

    /// Переводит текущий разговор на номер через REFER (RFC 3515).
    ///
    /// Без `replacing` это слепой перевод. С `replacing` в Refer-To добавляется
    /// URI-header Replaces — адресат нового INVITE заменит уже идущий
    /// консультационный разговор (RFC 3891).
    public func transfer(
        to target: String,
        replacing: SIPDialogIdentifier? = nil
    ) -> AsyncStream<SIPTransferEvent> {
        let (stream, continuation) = AsyncStream<SIPTransferEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )

        func reject(_ error: SIPTransferError) -> AsyncStream<SIPTransferEvent> {
            let status: Int
            switch error {
            case .rejected(let code, _): status = code
            default: status = 0
            }
            continuation.yield(.failed(status: status, reason: error.description))
            continuation.finish()
            return stream
        }

        let number = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !number.isEmpty else { return reject(.emptyTarget) }
        guard number.rangeOfCharacter(
            from: .whitespacesAndNewlines.union(.controlCharacters)
        ) == nil else {
            return reject(.invalidTarget)
        }
        guard let call = activeCall, call.dialog != nil, call.state == .answered else {
            return reject(.noActiveCall)
        }
        guard !call.isTransferring else { return reject(.alreadyTransferring) }

        transferSubscriptions[call.callID] = continuation
        setTransferring(true, callID: call.callID)
        Task { [weak self] in
            await self?.runTransfer(
                callID: call.callID,
                target: number,
                replacing: replacing,
                continuation: continuation
            )
        }
        return stream
    }

    private func runTransfer(
        callID: String,
        target: String,
        replacing: SIPDialogIdentifier?,
        continuation: AsyncStream<SIPTransferEvent>.Continuation
    ) async {
        defer {
            // После 202 флаг останется до NOTIFY; при ранней ошибке подписка
            // уже снята `finishTransfer`, и здесь его можно отпустить.
            if transferSubscriptions[callID] == nil {
                setTransferring(false, callID: callID)
            }
        }

        // REFER, как INVITE и BYE, chan_sip может сначала вызвать на
        // авторизацию. Повторяем один раз со свежим challenge.
        for attempt in 0..<2 {
            let local: SIPEndpoint
            do {
                local = try await transactions.waitUntilReady()
            } catch {
                finishTransfer(
                    callID: callID,
                    event: .failed(status: 0, reason: SIPTransferError.transportFailed(Self.describe(error)).description)
                )
                return
            }

            guard var call = activeCall, call.callID == callID, let dialog = call.dialog else {
                finishTransfer(
                    callID: callID,
                    event: .failed(status: 0, reason: SIPTransferError.noActiveCall.description)
                )
                return
            }

            let (updated, sequence) = dialog.nextSequence()
            call.dialog = updated
            activeCall = call

            var via = SIPVia(transport: account.transport, host: local.host, port: local.port)
            via.branch = SIPToken.branch()
            via.requestRport()

            var request = updated.makeRequest(
                .refer,
                sequence: sequence,
                via: via,
                contact: localContact(local),
                userAgent: userAgentName
            )
            request.headers.append(SIPHeaderName.referTo, referTo(target: target, replacing: replacing))
            request.headers.append(SIPHeaderName.referredBy, NameAddress(uri: account.addressOfRecord).description)
            request.headers.append(SIPHeaderName.event, "refer")
            request.headers.append(SIPHeaderName.allow, Self.allowedMethods)

            if let cached = cachedChallenge,
               let value = try? authorization(for: .refer, uri: request.uri, challenge: cached) {
                request.headers.append(cached.responseHeader, value)
            }

            log(
                .info,
                replacing == nil
                    ? "-> REFER \(target)"
                    : "-> REFER \(target) с Replaces"
            )

            do {
                let response = try await transactions.send(request)
                if response.isAuthenticationRequired,
                   attempt == 0,
                   let offered = response.authenticationChallenges.first {
                    cachedChallenge = offered
                    nonceCount = 0
                    continue
                }

                guard response.isSuccess else {
                    finishTransfer(
                        callID: callID,
                        event: .failed(
                            status: response.statusCode,
                            reason: SIPTransferError.rejected(
                                status: response.statusCode,
                                reason: response.reasonPhrase
                            ).description
                        )
                    )
                    return
                }

                // На быстром сервере финальный NOTIFY теоретически может
                // обогнать 202 в транспортном потоке. Тогда подписка уже
                // закрыта, и заново заводить ей таймер нельзя.
                guard transferSubscriptions[callID] != nil else { return }
                continuation.yield(.accepted)
                transferTimeoutTasks[callID]?.cancel()
                transferTimeoutTasks[callID] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    await self?.expireTransfer(callID: callID)
                }
                log(.info, "<- \(response.statusCode) \(response.reasonPhrase) на REFER")
                return
            } catch let error as SIPTransactionLayer.TransactionError {
                let transferError: SIPTransferError = switch error {
                case .timeout: .timeout
                case .transportFailed(let reason): .transportFailed(reason)
                case .cancelled: .transportFailed("соединение закрыто")
                case .notReady: .transportFailed("транспорт не готов")
                case .unknownTransaction: .transportFailed("транзакция потеряна")
                }
                finishTransfer(
                    callID: callID,
                    event: .failed(status: 0, reason: transferError.description)
                )
                return
            } catch {
                finishTransfer(
                    callID: callID,
                    event: .failed(status: 0, reason: Self.describe(error))
                )
                return
            }
        }

        finishTransfer(
            callID: callID,
            event: .failed(
                status: 401,
                reason: SIPTransferError.rejected(
                    status: 401,
                    reason: "сервер не принял авторизацию"
                ).description
            )
        )
    }

    private func referTo(target: String, replacing: SIPDialogIdentifier?) -> String {
        // Номер — user-часть SIP URI, не готовая строка заголовка. Кодируем
        // разделители (`#`, `?`, `@`, `%`) и тем самым одновременно сохраняем
        // их смысл и исключаем подстановку второго заголовка.
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_.!~*'()+")
        )
        let encodedTarget = target.addingPercentEncoding(withAllowedCharacters: allowed) ?? target
        var value = "sip:\(encodedTarget)@\(account.domain)"
        if let replacing {
            value += "?Replaces=\(replacing.percentEncodedHeaderValue)"
        }
        return "<\(value)>"
    }

    private func setTransferring(_ value: Bool, callID: String) {
        guard var call = activeCall, call.callID == callID else { return }
        call.isTransferring = value
        activeCall = call
    }

    private func finishTransfer(callID: String, event: SIPTransferEvent) {
        transferTimeoutTasks.removeValue(forKey: callID)?.cancel()
        guard let continuation = transferSubscriptions.removeValue(forKey: callID) else { return }
        continuation.yield(event)
        continuation.finish()
        setTransferring(false, callID: callID)
    }

    private func expireTransfer(callID: String) {
        finishTransfer(
            callID: callID,
            event: .failed(status: 408, reason: "сервер не сообщил результат перевода")
        )
    }

    /// Завершает звонок со своей стороны.
    public func hangUp() async {
        guard var call = activeCall else { return }

        // Входящий, на который мы ещё не ответили, завершается отказом, а не
        // CANCEL: CANCEL отменяет СВОЙ запрос, а этот запрос не наш.
        if call.role == .callee, call.dialog == nil {
            await rejectIncomingCall(status: 486)
            return
        }

        if let dialog = call.dialog {
            emitCallState(.ending)
            let (updated, sequence) = dialog.nextSequence()
            call.dialog = updated
            activeCall = call

            if let local = try? await transactions.waitUntilReady() {
                await sendBye(dialog: updated, sequence: sequence, local: local)
            }
            finishCall(with: .ended(reason: "завершён"), continuation: call.continuation)
        } else {
            // Диалога ещё нет: собеседник не ответил, значит отменяем INVITE.
            emitCallState(.ending)
            _ = try? await transactions.cancelInvite(branch: call.branch)
            log(.info, "-> CANCEL")
            finishCall(with: .ended(reason: "отменён"), continuation: call.continuation)
        }
    }

    private func sendBye(dialog: SIPDialog, sequence: Int, local: SIPEndpoint) async {
        var via = SIPVia(transport: account.transport, host: local.host, port: local.port)
        via.branch = SIPToken.branch()
        via.requestRport()

        var bye = dialog.makeRequest(.bye, sequence: sequence, via: via, userAgent: userAgentName)
        if let cached = cachedChallenge, let value = try? authorization(for: .bye, uri: bye.uri, challenge: cached) {
            bye.headers.append(cached.responseHeader, value)
        }

        let response = try? await transactions.send(bye)
        log(.debug, "-> BYE, ответ \(response.map { String($0.statusCode) } ?? "нет")")

        // chan_sip может потребовать авторизацию и на BYE. Один повтор со
        // свежим вызовом: без него диалог на сервере остаётся висеть.
        if let response, response.isAuthenticationRequired,
           let offered = response.authenticationChallenges.first {
            cachedChallenge = offered
            nonceCount = 0

            var retryVia = via
            retryVia.branch = SIPToken.branch()
            var retry = dialog.makeRequest(.bye, sequence: sequence + 1, via: retryVia, userAgent: userAgentName)
            if let value = try? authorization(for: .bye, uri: retry.uri, challenge: offered) {
                retry.headers.append(offered.responseHeader, value)
            }
            _ = try? await transactions.send(retry)
        }
    }

    private func makeInvite(
        to target: String,
        callID: String,
        localTag: String,
        sequence: Int,
        offer: Data,
        contentType: String,
        local: SIPEndpoint
    ) -> SIPRequest {
        let targetURI = SIPURI(user: target, host: account.domain)
        var request = SIPRequest(method: .invite, uri: targetURI, body: offer)

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
        request.headers.append(SIPHeaderName.to, NameAddress(uri: targetURI).description)
        request.headers.append(SIPHeaderName.callID, callID)
        request.headers.append(SIPHeaderName.cseq, "\(sequence) \(SIPMethod.invite.rawValue)")
        request.headers.append(SIPHeaderName.contact, localContact(local).description)
        request.headers.append(SIPHeaderName.allow, Self.allowedMethods)
        request.headers.append(SIPHeaderName.supported, "replaces")
        request.headers.append(SIPHeaderName.userAgent, userAgentName)
        request.headers.append(SIPHeaderName.contentType, contentType)

        if let cached = cachedChallenge,
           let value = try? authorization(for: .invite, uri: targetURI, challenge: cached) {
            request.headers.append(cached.responseHeader, value)
        }

        return request
    }

    private func localContact(_ local: SIPEndpoint) -> NameAddress {
        let endpoint = contactEndpoint ?? local
        var uri = SIPURI(user: account.username, host: endpoint.host, port: endpoint.port)
        if account.transport != .udp {
            uri[parameter: "transport"] = account.transport.rawValue
        }
        return NameAddress(uri: uri)
    }

    private func authorization(
        for method: SIPMethod,
        uri: SIPURI,
        challenge: (challenge: DigestChallenge, responseHeader: String)
    ) throws -> String {
        nonceCount += 1
        return try DigestAuthentication.authorizationValue(
            credentials: DigestAuthentication.Credentials(
                username: account.effectiveAuthUsername,
                password: credentials.password
            ),
            challenge: challenge.challenge,
            method: method,
            digestURI: uri.description,
            nonceCount: nonceCount
        )
    }

    private func emitCallState(_ newState: SIPCallState) {
        guard var call = activeCall, call.state != newState else { return }
        call.state = newState
        activeCall = call
        call.continuation.yield(.state(newState))
    }

    private func finishCall(with event: SIPCallEvent, continuation: AsyncStream<SIPCallEvent>.Continuation) {
        // Серверную транзакцию снимаем вместе со звонком: ждать ACK на ответ
        // по завершённому вызову незачем, а её таймеры пережили бы сам звонок.
        if let call = activeCall, call.role == .callee {
            let callID = call.callID
            Task { await transactions.forgetServerInvite(callID: callID) }
        }
        if let callID = activeCall?.callID,
           let transfer = transferSubscriptions.removeValue(forKey: callID) {
            transferTimeoutTasks.removeValue(forKey: callID)?.cancel()
            transfer.yield(.failed(status: 0, reason: "разговор завершился во время перевода"))
            transfer.finish()
        }
        activeCall = nil

        let reason = switch event {
        case .failed(_, let text): text
        case .ended(let text): text
        default: "завершён"
        }

        continuation.yield(.state(.ended(reason: reason)))
        continuation.yield(event)
        continuation.finish()
    }

    // MARK: - Входящий звонок

    /// Принимает входящий INVITE и поднимает шум наверх.
    ///
    /// Быстрый порядок ответов важен: 100 гасит ретрансмиссии INVITE (на UDP
    /// они начинаются через полсекунды), 180 включает гудки у звонящего. Всё,
    /// что дольше, — уже решение оператора, и торопить его нечем.
    private func handle(invite request: SIPRequest) async {
        // Повторный INVITE внутри установленного диалога — это удержание или
        // смена медиа.
        if let call = activeCall, call.dialog != nil {
            if matchesDialog(request, call: call) {
                await handle(reinvite: request, call: call)
                return
            }

            // To-tag означает запрос внутри уже существующего диалога. Если
            // тройка идентификаторов не совпала, это не новый звонок и не
            // «занято», а неизвестный диалог.
            if request.to?.tag != nil {
                var missing = SIPResponse(
                    statusCode: 481,
                    headers: responseHeaders(for: request)
                )
                missing.headers.append(SIPHeaderName.userAgent, userAgentName)
                try? await transactions.respondToInvite(to: request, with: missing)
                log(.warning, "<- повторный INVITE с чужими тегами, ответили 481")
                return
            }
        }

        // Линия одна. Второй вызов получает «занято», а не молчание: очередь
        // раздачи должна сразу отдать лид следующему агенту.
        guard activeCall == nil else {
            var busy = SIPResponse(statusCode: 486, headers: responseHeaders(for: request))
            busy.headers.append(SIPHeaderName.userAgent, userAgentName)
            try? await transactions.respondToInvite(to: request, with: busy)
            log(.info, "<- INVITE, ответили 486: линия занята")
            return
        }

        guard let callID = request.callID, let branch = request.topVia?.branch else {
            var badRequest = SIPResponse(statusCode: 400, headers: responseHeaders(for: request))
            badRequest.headers.append(SIPHeaderName.userAgent, userAgentName)
            try? await transactions.respondToInvite(to: request, with: badRequest)
            return
        }

        // Без Contact диалог не собрать — значит и отвечать не на что: BYE
        // отправлять будет некуда. Отказ здесь честнее, чем разговор,
        // который невозможно завершить.
        guard request.contacts.first != nil else {
            var badRequest = SIPResponse(
                statusCode: 400,
                reasonPhrase: "Missing Contact",
                headers: responseHeaders(for: request)
            )
            badRequest.headers.append(SIPHeaderName.userAgent, userAgentName)
            try? await transactions.respondToInvite(to: request, with: badRequest)
            log(.warning, "<- INVITE без Contact, отклонён")
            return
        }

        let callTag = SIPToken.tag()
        let (stream, continuation) = AsyncStream<SIPCallEvent>.makeStream(bufferingPolicy: .bufferingNewest(32))

        activeCall = ActiveCall(
            role: .callee,
            callID: callID,
            localTag: callTag,
            branch: branch,
            inviteSequence: request.cseq?.number ?? 1,
            continuation: continuation,
            dialog: nil,
            state: .incoming,
            inviteRequest: request
        )

        let trying = SIPResponse(statusCode: 100, headers: responseHeaders(for: request, localTag: callTag))
        try? await transactions.respondToInvite(to: request, with: trying)

        var ringing = SIPResponse(statusCode: 180, headers: responseHeaders(for: request, localTag: callTag))
        ringing.headers.append(SIPHeaderName.allow, Self.allowedMethods)
        ringing.headers.append(SIPHeaderName.supported, "replaces")
        ringing.headers.append(SIPHeaderName.userAgent, userAgentName)
        try? await transactions.respondToInvite(to: request, with: ringing)

        let from = request.from
        let call = SIPIncomingCall(
            callID: callID,
            callerNumber: from?.uri.user ?? "",
            callerName: from?.displayName,
            calledNumber: request.to?.uri.user ?? account.username,
            offer: request.body,
            offerContentType: request.contentType,
            events: stream
        )

        log(.info, "<- INVITE от \(call.displayNumber), ответили 180")
        continuation.yield(.state(.incoming))
        eventContinuation.yield(.incomingCall(call))
    }

    /// Отвечает на чужой повторный INVITE.
    ///
    /// Это удержание с той стороны, снятие с удержания, смена кодека или
    /// переброс медиа на другой адрес. Отвечать прежним SDP, как делалось до
    /// M4, нельзя: на серверном удержании мы продолжали бы отправлять голос
    /// оператора в линию, где его слушает музыка ожидания.
    private func handle(reinvite request: SIPRequest, call: ActiveCall) async {
        // 100 сразу: разбор предложения и пересборка медиа занимают время, а
        // ретрансмиссии INVITE на UDP начинаются через полсекунды.
        let trying = SIPResponse(statusCode: 100, headers: responseHeaders(for: request, localTag: call.localTag))
        try? await transactions.respondToInvite(to: request, with: trying)

        // Встречное предложение. Ждать «своей очереди» здесь нельзя: пока мы
        // ждём, наш собственный INVITE ждёт ответа от собеседника — и это
        // взаимная блокировка, ради разрыва которой 491 и придуман.
        guard !call.isRenegotiating else {
            var pending = SIPResponse(
                statusCode: 491,
                headers: responseHeaders(for: request, localTag: call.localTag)
            )
            pending.headers.append(SIPHeaderName.userAgent, userAgentName)
            try? await transactions.respondToInvite(to: request, with: pending)
            log(.info, "<- повторный INVITE встретился с нашим, ответили 491")
            return
        }

        // Обновление цели: собеседник мог сменить Contact.
        if let contact = request.contacts.first?.uri,
           var current = activeCall, var dialog = current.dialog {
            dialog.remoteTarget = contact
            current.dialog = dialog
            activeCall = current
        }

        let answer: Data?
        if request.body.isEmpty {
            // INVITE без тела означает «объяви заново, чем располагаешь».
            // Ответ на него — наше прежнее описание, и это не заглушка.
            answer = call.localSDP
            log(.debug, "<- повторный INVITE без предложения, отвечаем прежним описанием")
        } else if let renegotiator = mediaRenegotiator {
            answer = await renegotiator(request.body)
        } else {
            // Пересогласователь не задан — значит медиа никто не держит. Так
            // бывает только в тестах сигнализации; в приложении и в sipcheck он
            // есть всегда, и умолчание тут сказано вслух, а не спрятано.
            answer = call.localSDP
            log(.warning, "<- повторный INVITE подтверждён прежним SDP: пересогласователь не задан")
        }

        // Пока пересогласователь работал, звонок мог завершиться.
        guard let current = activeCall, matchesDialog(request, call: current) else {
            log(.debug, "пересогласование закончилось позже звонка")
            return
        }

        guard let answer else {
            var unacceptable = SIPResponse(
                statusCode: 488,
                headers: responseHeaders(for: request, localTag: current.localTag)
            )
            unacceptable.headers.append(SIPHeaderName.userAgent, userAgentName)
            try? await transactions.respondToInvite(to: request, with: unacceptable)
            log(.warning, "<- повторный INVITE отклонён 488: предложение не подходит")
            return
        }

        var response = SIPResponse(
            statusCode: 200,
            headers: responseHeaders(for: request, localTag: current.localTag),
            body: answer
        )
        response.headers.append(SIPHeaderName.contentType, "application/sdp")
        response.headers.append(SIPHeaderName.allow, Self.allowedMethods)
        response.headers.append(SIPHeaderName.supported, "replaces")
        response.headers.append(SIPHeaderName.userAgent, userAgentName)

        var updated = current
        updated.localSDP = answer
        activeCall = updated

        try? await transactions.respondToInvite(to: request, with: response)
        log(.info, "<- повторный INVITE пересогласован")
    }

    /// Отвечает на входящий звонок: 200 OK с нашим SDP.
    ///
    /// Медиа надо поднимать сразу после возврата, не дожидаясь ACK: Asterisk
    /// начинает слать RTP по 200 OK, и первые полсекунды разговора иначе
    /// уходят в никуда.
    @discardableResult
    public func answerIncomingCall(answer: Data, contentType: String = "application/sdp") async -> Bool {
        guard var call = activeCall,
              call.role == .callee,
              call.state == .incoming,
              let invite = call.inviteRequest
        else { return false }

        guard let dialog = SIPDialog(responderRequest: invite, localTag: call.localTag) else {
            log(.error, "во входящем INVITE нет Contact — диалог собрать невозможно")
            await rejectIncomingCall(status: 400)
            return false
        }

        var response = SIPResponse(
            statusCode: 200,
            headers: responseHeaders(for: invite, localTag: call.localTag),
            body: answer
        )
        response.headers.append(SIPHeaderName.contentType, contentType)
        response.headers.append(SIPHeaderName.allow, Self.allowedMethods)
        response.headers.append(SIPHeaderName.supported, "replaces")
        response.headers.append(SIPHeaderName.userAgent, userAgentName)

        call.dialog = dialog
        call.state = .answered
        call.localSDP = answer
        activeCall = call

        do {
            try await transactions.respondToInvite(to: invite, with: response)
        } catch {
            log(.error, "не удалось отправить 200 OK: \(Self.describe(error))")
            finishCall(with: .failed(status: 0, reason: "ответ не ушёл"), continuation: call.continuation)
            return false
        }

        log(.info, "-> 200 OK, звонок принят")
        call.continuation.yield(.state(.answered))
        return true
    }

    /// Отклоняет входящий звонок.
    ///
    /// 486 «занято» по умолчанию, а не 603 «отклонён»: при раздаче лидов
    /// первое возвращает вызов в очередь следующему агенту, второе завершает
    /// его совсем.
    public func rejectIncomingCall(status: Int = 486) async {
        guard let call = activeCall,
              call.role == .callee,
              call.state == .incoming,
              let invite = call.inviteRequest
        else { return }

        var response = SIPResponse(
            statusCode: status,
            headers: responseHeaders(for: invite, localTag: call.localTag)
        )
        response.headers.append(SIPHeaderName.userAgent, userAgentName)
        try? await transactions.respondToInvite(to: invite, with: response)

        log(.info, "-> \(status), звонок отклонён")
        finishCall(with: .ended(reason: "отклонён"), continuation: call.continuation)
    }

    /// Судьба нашего 200 OK на входящий звонок.
    private func handle(serverInvite event: SIPServerInviteEvent) async {
        switch event {
        case .acknowledged(let callID):
            guard let call = activeCall, call.callID == callID else { return }
            log(.debug, "<- ACK, разговор подтверждён")

        case .notAcknowledged(let callID):
            guard let call = activeCall, call.callID == callID, call.dialog != nil else { return }
            // Диалог создан нашим 200, но подтверждения нет. RFC 3261 §13.3.1.4
            // требует закрыть его через BYE: иначе на нашей стороне разговор,
            // о котором собеседник не знает, а оператор говорит в пустоту.
            log(.warning, "ACK не пришёл за 32 с — закрываем звонок")
            await hangUp()
        }
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

        case .bye:
            guard let call = activeCall, matchesDialog(request, call: call) else {
                let missing = SIPResponse(
                    statusCode: 481,
                    headers: responseHeaders(for: request)
                )
                try? await transactions.respond(to: request, with: missing)
                log(.warning, "<- BYE вне активного диалога, ответили 481")
                return
            }

            // Собеседник положил трубку. Ответить обязаны, иначе Asterisk будет
            // повторять BYE и держать диалог открытым.
            let response = SIPResponse(statusCode: 200, headers: responseHeaders(for: request))
            try? await transactions.respond(to: request, with: response)
            log(.info, "<- BYE, собеседник завершил звонок")
            finishCall(
                with: .ended(reason: "собеседник завершил звонок"),
                continuation: call.continuation
            )

        case .ack:
            // ACK ответа не требует по определению: это подтверждение, а не
            // запрос. Отвечать на него 405 было бы протокольной ошибкой.
            break

        case .invite:
            await handle(invite: request)

        case .cancel:
            // CANCEL отменяет ещё не отвеченный INVITE. Отвечать надо дважды:
            // 200 на сам CANCEL и 487 на отменённый INVITE — иначе Asterisk
            // считает вызов живым и держит канал до таймаута.
            let response = SIPResponse(statusCode: 200, headers: responseHeaders(for: request))
            try? await transactions.respond(to: request, with: response)

            guard let call = activeCall,
                  call.role == .callee,
                  call.callID == request.callID,
                  call.dialog == nil,
                  let invite = call.inviteRequest
            else {
                log(.debug, "<- CANCEL, отменять нечего")
                return
            }

            var terminated = SIPResponse(
                statusCode: 487,
                headers: responseHeaders(for: invite, localTag: call.localTag)
            )
            terminated.headers.append(SIPHeaderName.userAgent, userAgentName)
            try? await transactions.respondToInvite(to: invite, with: terminated)

            log(.info, "<- CANCEL, вызов отменён до ответа")
            finishCall(with: .ended(reason: "отменён вызывающим"), continuation: call.continuation)

        case .notify:
            // REFER создаёт неявную подписку. Результат нового INVITE сервер
            // сообщает телом message/sipfrag. Чужой диалог подтверждать нельзя:
            // такой NOTIFY не относится к созданной нами подписке.
            guard let call = activeCall,
                  matchesDialog(request, call: call),
                  request.headers[SIPHeaderName.event]?
                .lowercased()
                .hasPrefix("refer") == true,
                let callID = request.callID,
                transferSubscriptions[callID] != nil
            else {
                let missing = SIPResponse(
                    statusCode: 481,
                    headers: responseHeaders(for: request)
                )
                try? await transactions.respond(to: request, with: missing)
                log(.debug, "<- NOTIFY без активного REFER-диалога, ответили 481")
                return
            }

            let response = SIPResponse(statusCode: 200, headers: responseHeaders(for: request))
            try? await transactions.respond(to: request, with: response)

            guard let fragment = parseSIPFragmentStatus(request.body) else {
                if request.headers[SIPHeaderName.subscriptionState]?
                    .lowercased()
                    .hasPrefix("terminated") == true {
                    finishTransfer(
                        callID: callID,
                        event: .failed(status: 500, reason: "сервер завершил перевод без результата")
                    )
                }
                return
            }

            if (200..<300).contains(fragment.status) {
                log(.info, "<- NOTIFY: перевод завершён")
                finishTransfer(callID: callID, event: .succeeded)
            } else if fragment.status >= 300 {
                let reason = describeCallFailure(status: fragment.status, reason: fragment.reason)
                log(.warning, "<- NOTIFY: перевод не состоялся, \(fragment.status) \(fragment.reason)")
                finishTransfer(
                    callID: callID,
                    event: .failed(status: fragment.status, reason: reason)
                )
            }

        case .refer:
            // В M5 перевод инициирует оператор. Управлять нашим разговором
            // удалённой стороне не разрешаем: это отдельная политика, а не
            // обязательная часть поддержки исходящего REFER.
            var response = SIPResponse(statusCode: 501, headers: responseHeaders(for: request))
            response.headers.append(SIPHeaderName.allow, Self.allowedMethods)
            try? await transactions.respond(to: request, with: response)
            eventContinuation.yield(.unsupportedRequest(method: request.method))

        default:
            var response = SIPResponse(statusCode: 405, headers: responseHeaders(for: request))
            response.headers.append(SIPHeaderName.allow, Self.allowedMethods)
            try? await transactions.respond(to: request, with: response)
            eventContinuation.yield(.unsupportedRequest(method: request.method))
        }
    }

    /// Проверяет полную тройку идентификаторов диалога.
    ///
    /// В запросе с удалённой стороны наш тег находится в To, удалённый — во
    /// From. Один Call-ID недостаточен для BYE, re-INVITE и REFER-NOTIFY.
    private func matchesDialog(_ request: SIPRequest, call: ActiveCall) -> Bool {
        guard let dialog = call.dialog, let callID = request.callID else {
            return false
        }
        return dialog.matches(
            callID: callID,
            localTag: request.to?.tag,
            remoteTag: request.from?.tag
        )
    }

    /// Заголовки ответа, скопированные из запроса по RFC 3261 §8.2.6.2.
    ///
    /// Тег по умолчанию — регистрационный: им подписаны ответы на OPTIONS, и
    /// он постоянен, пока агент жив. У звонка тег свой: диалог опознаётся по
    /// тройке Call-ID и двух тегов, и подписывать разные звонки одним тегом
    /// значит склеивать их при перезвоне с тем же Call-ID.
    private func responseHeaders(for request: SIPRequest, localTag: String? = nil) -> SIPHeaders {
        let tag = localTag ?? self.localTag
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
                to.tag = tag
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
    /// обрабатываем. NOTIFY появился в M5 вместе с переводом. REFER здесь нет:
    /// мы умеем его отправлять, но входящий явно получает 501, потому что
    /// удалённое управление нашим разговором — отдельная политика.
    ///
    /// INFO в списке не появился и в M4: DTMF мы шлём по RFC 4733, внутри
    /// потока RTP, и отдельный метод SIP для этого не нужен. Заявить INFO
    /// значило бы разрешить серверу присылать нам DTMF тем путём, которого мы
    /// не обрабатываем.
    static let allowedMethods = "INVITE, ACK, CANCEL, BYE, OPTIONS, NOTIFY"

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
            case .unknownTransaction: "ответ не относится ни к одному запросу"
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
        case authenticationFailed
        case tooManyAttempts

        public var description: String {
            switch self {
            case .rejected(let status, let reason):
                switch status {
                case 403: "неверный логин или пароль (403)"
                case 404: "такого номера нет на сервере (404)"
                default: "сервер ответил \(status) \(reason)"
                }
            case .authenticationFailed:
                "неверный логин или пароль"
            case .tooManyAttempts:
                "слишком много попыток подряд"
            }
        }
    }
}
