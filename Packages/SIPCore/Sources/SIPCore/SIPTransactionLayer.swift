import Foundation

/// Слой транзакций: клиентские не-INVITE (RFC 3261 §17.1.2), клиентские INVITE
/// (§17.1.1) и приём входящих запросов.
///
/// Транзакция — это то, что отвечает за «дошло или нет». На UDP ответа можно не
/// дождаться просто потому, что пакет потерялся, и без ретрансмиссий регистрация
/// и звонки будут случайным образом отваливаться.
public actor SIPTransactionLayer {

    public enum TransactionError: Error, Sendable, Equatable {
        /// Истёк таймер F (не-INVITE) или B (INVITE): 64*T1, по умолчанию 32 с.
        case timeout
        case transportFailed(String)
        case cancelled
        case notReady
        case unknownTransaction
    }

    public struct Timers: Sendable, Hashable {
        /// Оценка RTT. Начальный интервал ретрансмиссий.
        public var t1: Duration = .milliseconds(500)
        /// Максимальный интервал ретрансмиссий.
        public var t2: Duration = .seconds(4)
        /// Максимальное время жизни сообщения в сети.
        public var t4: Duration = .seconds(5)

        /// Таймер D: сколько держать завершённую INVITE-транзакцию, чтобы
        /// поглощать ретрансмиссии неуспешного ответа.
        ///
        /// По RFC 3261 §17.1.1.2 он не выводится из T1, а задаётся отдельно и
        /// должен быть не меньше 32 секунд. Хранимое свойство, а не вычисляемое,
        /// именно поэтому — и чтобы тесты могли его укоротить.
        public var completedLifetime: Duration = .seconds(32)

        public init() {}

        /// Таймер F для не-INVITE и таймер B для INVITE.
        public var transactionTimeout: Duration { t1 * 64 }
    }

    private struct ClientTransaction {
        let method: SIPMethod
        let data: Data
        var continuation: CheckedContinuation<SIPResponse, Error>?
        var retransmitTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
    }

    private struct InviteTransaction {
        enum State { case calling, proceeding, completed }

        let request: SIPRequest
        let data: Data
        let continuation: AsyncStream<SIPInviteEvent>.Continuation
        var state: State = .calling
        var retransmitTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
        var completedTask: Task<Void, Never>?
    }

    /// Серверная сторона INVITE: RFC 3261 §17.2.1 плюс §13.3.1.4 для 2xx.
    ///
    /// Отдельный тип, а не переиспользование клиентской: у сторон разные
    /// состояния и разный смысл ретрансмиссий. Клиент повторяет запрос, пока не
    /// услышит ответ; сервер повторяет ОТВЕТ, пока не услышит подтверждение.
    private struct ServerInviteTransaction {
        enum State {
            /// Ответили 1xx, финального ещё нет.
            case proceeding
            /// Ответили 3xx–6xx, ждём ACK и повторяем ответ (таймеры G и H).
            case completed
            /// Ответили 2xx, ждём ACK и повторяем ответ (§13.3.1.4).
            case accepted
        }

        let request: SIPRequest
        let callID: String
        var state: State = .proceeding
        var retransmitTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
    }

    private let channel: SIPTransportChannel
    private let timers: Timers

    public nonisolated let inboundRequests: AsyncStream<SIPRequest>
    private nonisolated let inboundContinuation: AsyncStream<SIPRequest>.Continuation

    /// Судьба финальных ответов на входящие INVITE: дошли или нет.
    public nonisolated let serverInviteEvents: AsyncStream<SIPServerInviteEvent>
    private nonisolated let serverInviteContinuation: AsyncStream<SIPServerInviteEvent>.Continuation

    /// Ключ — branch плюс метод: CANCEL несёт тот же branch, что отменяемый
    /// INVITE, и без метода в ключе транзакции затирали бы друг друга.
    private var clientTransactions: [String: ClientTransaction] = [:]
    private var inviteTransactions: [String: InviteTransaction] = [:]

    /// Серверные INVITE по branch входящего запроса.
    private var serverInvites: [String: ServerInviteTransaction] = [:]
    /// Call-ID плюс CSeq → branch: по этой паре ACK находит свою транзакцию,
    /// даже когда приходит со своим branch (случай 2xx).
    private var serverInviteKeys: [String: String] = [:]

    /// Ответы на входящие запросы, чтобы отвечать одинаково на ретрансмиссии
    /// (RFC 3261 §17.2.2). Ключ — branch входящего запроса.
    private var sentResponses: [String: SIPResponse] = [:]

    private var localEndpoint: SIPEndpoint?
    private var readinessWaiters: [CheckedContinuation<SIPEndpoint, Error>] = []
    private var pumpTask: Task<Void, Never>?
    private var failureReason: String?

    public init(channel: SIPTransportChannel, timers: Timers = Timers()) {
        self.channel = channel
        self.timers = timers
        let (stream, continuation) = AsyncStream<SIPRequest>.makeStream(bufferingPolicy: .bufferingNewest(64))
        inboundRequests = stream
        inboundContinuation = continuation

        let (serverStream, serverContinuation) =
            AsyncStream<SIPServerInviteEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
        serverInviteEvents = serverStream
        serverInviteContinuation = serverContinuation
    }

    public var transport: SIPTransport { channel.transport }
    public var remote: SIPEndpoint { channel.remote }

    // MARK: - Жизненный цикл

    public func start() async {
        guard pumpTask == nil else { return }

        let events = channel.events
        pumpTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
        }
        await channel.start()
    }

    public func stop() async {
        pumpTask?.cancel()
        pumpTask = nil
        failAll(with: .cancelled)
        for key in Array(serverInvites.keys) {
            forgetServerInvite(branch: key)
        }
        inboundContinuation.finish()
        serverInviteContinuation.finish()
        await channel.stop()
    }

    /// Ждёт готовности канала и возвращает локальный адрес.
    public func waitUntilReady(timeout: Duration = .seconds(10)) async throws -> SIPEndpoint {
        if let localEndpoint { return localEndpoint }
        if let failureReason { throw TransactionError.transportFailed(failureReason) }

        let timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            await self?.failReadiness(with: .timeout)
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            readinessWaiters.append(continuation)
        }
    }

    // MARK: - Не-INVITE

    /// Отправляет запрос и ждёт финального ответа.
    public func send(_ request: SIPRequest) async throws -> SIPResponse {
        var request = request
        guard var via = request.topVia else { throw TransactionError.notReady }
        if via.branch == nil {
            via.branch = SIPToken.branch()
            request.headers.set(SIPHeaderName.via, to: via.description)
        }
        guard let branch = via.branch else { throw TransactionError.notReady }

        let data = request.encoded()
        let method = request.method
        let key = Self.transactionKey(branch: branch, method: method)

        return try await withCheckedThrowingContinuation { continuation in
            clientTransactions[key] = ClientTransaction(
                method: method,
                data: data,
                continuation: continuation
            )

            let timeout = timers.transactionTimeout
            clientTransactions[key]?.timeoutTask = Task { [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                await self?.finish(key: key, with: .failure(TransactionError.timeout))
            }

            Task { [weak self] in
                await self?.transmit(key: key, data: data)
            }
        }
    }

    // MARK: - INVITE

    /// Отправляет INVITE и отдаёт поток событий транзакции.
    ///
    /// Поток заканчивается на финальном ответе, таймауте или отказе транспорта.
    public func sendInvite(_ request: SIPRequest) -> AsyncStream<SIPInviteEvent> {
        var request = request
        var branchValue: String?
        if var via = request.topVia {
            if via.branch == nil {
                via.branch = SIPToken.branch()
                request.headers.set(SIPHeaderName.via, to: via.description)
            }
            branchValue = via.branch
        }

        let (stream, continuation) = AsyncStream<SIPInviteEvent>.makeStream(bufferingPolicy: .bufferingNewest(32))

        guard let branch = branchValue else {
            continuation.yield(.transportFailed(reason: "в запросе нет Via"))
            continuation.finish()
            return stream
        }

        let data = request.encoded()
        let key = Self.transactionKey(branch: branch, method: .invite)

        inviteTransactions[key] = InviteTransaction(
            request: request,
            data: data,
            continuation: continuation
        )

        // Таймер B живёт только в состоянии Calling: после первого 1xx сервер
        // уже получил запрос, и гудки могут идти сколько угодно — обрывать их
        // по таймеру нельзя, это решение пользователя.
        let timeout = timers.transactionTimeout
        // catch с возвратом, а не try?: отменённая задача обязана замолчать.
        // Иначе `try?` проглатывает CancellationError, и таймер срабатывает
        // ровно тогда, когда его уже отменили за ненадобностью.
        inviteTransactions[key]?.timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            await self?.expireInvite(key: key)
        }

        Task { [weak self] in
            await self?.transmitInvite(key: key, data: data)
        }

        return stream
    }

    /// Отменяет INVITE, на который ещё не пришёл финальный ответ.
    ///
    /// Возвращает false, если отменять уже нечего. CANCEL имеет смысл только
    /// после первого 1xx: до него сервер мог ещё не создать транзакцию, и
    /// отменять было бы нечего (RFC 3261 §9.1).
    @discardableResult
    public func cancelInvite(branch: String) async throws -> Bool {
        let key = Self.transactionKey(branch: branch, method: .invite)
        guard let transaction = inviteTransactions[key], transaction.state != .completed else {
            return false
        }

        let cancel = Self.makeCancel(for: transaction.request)
        _ = try? await send(cancel)
        return true
    }

    /// Отправляет ответ на входящий запрос и запоминает его для ретрансмиссий.
    public func respond(to request: SIPRequest, with response: SIPResponse) async throws {
        if let branch = request.topVia?.branch {
            remember(response: response, branch: branch)
        }
        try await channel.send(response.encoded())
    }

    /// Отправляет ответ на входящий INVITE и ведёт серверную транзакцию.
    ///
    /// Отдельный вход, а не `respond`, потому что у INVITE ответ живёт своей
    /// жизнью: 1xx можно послать сколько угодно, а финальный надо повторять,
    /// пока не придёт ACK. Молча положиться на ретрансмиссии самого INVITE
    /// нельзя — на 2xx собеседник INVITE больше не повторяет, и потерянный
    /// 200 OK означает разговор, о котором знаем только мы.
    public func respondToInvite(to request: SIPRequest, with response: SIPResponse) async throws {
        guard request.method == .invite, let branch = request.topVia?.branch else {
            throw TransactionError.notReady
        }
        guard let callID = request.callID else { throw TransactionError.notReady }

        var transaction = serverInvites[branch]
            ?? ServerInviteTransaction(request: request, callID: callID)
        transaction.retransmitTask?.cancel()
        transaction.retransmitTask = nil
        transaction.timeoutTask?.cancel()
        transaction.timeoutTask = nil

        // Ретрансмиссия самого INVITE обязана получить последний наш ответ, а
        // не второй новый: иначе собеседник увидит два разных 1xx на один запрос.
        remember(response: response, branch: branch)

        guard response.isFinal else {
            transaction.state = .proceeding
            serverInvites[branch] = transaction
            if let key = Self.acknowledgementKey(for: request) {
                serverInviteKeys[key] = branch
            }
            try await channel.send(response.encoded())
            return
        }

        transaction.state = response.isSuccess ? .accepted : .completed
        serverInvites[branch] = transaction
        if let key = Self.acknowledgementKey(for: request) {
            serverInviteKeys[key] = branch
        }

        try await channel.send(response.encoded())

        // На надёжном транспорте повторять нечего: TLS сам гарантирует доставку.
        // Ждать ACK всё равно надо — он подтверждает не доставку, а согласие.
        startAwaitingAcknowledgement(branch: branch, repeats: !channel.transport.isReliable)
    }

    /// Запускает ожидание ACK: повторы финального ответа и общий предел 64*T1.
    ///
    /// Таймеры G (повтор) и H (предел) по RFC 3261 §17.2.1 — и та же схема для
    /// 2xx по §13.3.1.4. Разница между случаями только в том, что делать по
    /// истечении: на 3xx–6xx транзакция просто умирает, а на 2xx наверх уходит
    /// `notAcknowledged`, потому что диалог уже создан и его надо закрывать.
    private func startAwaitingAcknowledgement(branch: String, repeats: Bool) {
        guard var transaction = serverInvites[branch] else { return }

        let limit = timers.transactionTimeout
        transaction.timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: limit) } catch { return }
            await self?.expireServerInvite(branch: branch)
        }

        if repeats {
            let t1 = timers.t1
            let t2 = timers.t2
            transaction.retransmitTask = Task { [weak self] in
                var interval = t1
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled, let self else { return }
                    guard await self.resendServerInviteResponse(branch: branch) else { return }
                    interval = min(interval * 2, t2)
                }
            }
        }

        serverInvites[branch] = transaction
    }

    /// Повторяет последний финальный ответ. false — повторять больше нечего.
    private func resendServerInviteResponse(branch: String) async -> Bool {
        guard let transaction = serverInvites[branch], transaction.state != .proceeding else {
            return false
        }
        guard let response = sentResponses[branch] else { return false }
        try? await channel.send(response.encoded())
        return true
    }

    private func expireServerInvite(branch: String) {
        guard let transaction = serverInvites[branch] else { return }
        let wasAccepted = transaction.state == .accepted
        forgetServerInvite(branch: branch)
        if wasAccepted {
            serverInviteContinuation.yield(.notAcknowledged(callID: transaction.callID))
        }
    }

    /// Принимает ACK на наш финальный ответ.
    ///
    /// Возвращает true, если ACK относился к известной серверной транзакции —
    /// тогда наверх его отдавать незачем.
    private func absorbAcknowledgement(_ request: SIPRequest) -> Bool {
        // Сначала по branch: так приходит ACK на 3xx–6xx, он часть той же
        // транзакции. Потом по Call-ID и CSeq: ACK на 2xx идёт со своим branch.
        var found: String?
        if let branch = request.topVia?.branch, serverInvites[branch] != nil {
            found = branch
        } else if let key = Self.acknowledgementKey(for: request) {
            found = serverInviteKeys[key]
        }
        guard let branch = found, let transaction = serverInvites[branch] else { return false }
        guard transaction.state != .proceeding else { return false }

        let wasAccepted = transaction.state == .accepted
        forgetServerInvite(branch: branch)

        // Ответ из кэша убираем вместе с транзакцией: ретрансмиссии INVITE
        // после ACK не бывает, а вот перезвон с тем же branch — бывает.
        sentResponses.removeValue(forKey: branch)

        if wasAccepted {
            serverInviteContinuation.yield(.acknowledged(callID: transaction.callID))
        }
        return true
    }

    private func forgetServerInvite(branch: String) {
        guard let transaction = serverInvites.removeValue(forKey: branch) else { return }
        transaction.retransmitTask?.cancel()
        transaction.timeoutTask?.cancel()
        if let key = Self.acknowledgementKey(for: transaction.request) {
            serverInviteKeys.removeValue(forKey: key)
        }
    }

    /// Снимает серверную транзакцию по Call-ID.
    ///
    /// Нужно ровно на одном переходе: мы ответили 200, ACK пришёл, разговор
    /// завершился. Ждать таймеров после этого не за чем.
    public func forgetServerInvite(callID: String) {
        for (branch, transaction) in serverInvites where transaction.callID == callID {
            forgetServerInvite(branch: branch)
            sentResponses.removeValue(forKey: branch)
        }
    }

    private func remember(response: SIPResponse, branch: String) {
        sentResponses[branch] = response
        let lifetime = timers.t4 * 8
        Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            await self?.forgetResponse(branch: branch)
        }
    }

    /// Отправляет запрос, не создавая транзакцию и не ожидая ответа.
    ///
    /// Нужно ровно для одного случая: ACK на 2xx. Он идёт вне транзакции, и
    /// ответа на него не бывает.
    public func sendWithoutTransaction(_ request: SIPRequest) async throws {
        try await channel.send(request.encoded())
    }

    // MARK: - Передача

    private func transmit(key: String, data: Data) async {
        do {
            try await channel.send(data)
        } catch {
            finish(key: key, with: .failure(TransactionError.transportFailed("\(error)")))
            return
        }

        guard !channel.transport.isReliable else { return }

        let t1 = timers.t1
        let t2 = timers.t2
        clientTransactions[key]?.retransmitTask = Task { [weak self] in
            var interval = t1
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                guard let self, await self.isPending(key: key) else { return }
                try? await self.resend(key: key)
                interval = min(interval * 2, t2)
            }
        }
    }

    private func transmitInvite(key: String, data: Data) async {
        do {
            try await channel.send(data)
        } catch {
            failInvite(key: key, reason: "\(error)")
            return
        }

        guard !channel.transport.isReliable else { return }

        // Таймер A: интервал удваивается без ограничения T2 — в отличие от
        // не-INVITE. Так требует RFC 3261 §17.1.1.2.
        let t1 = timers.t1
        inviteTransactions[key]?.retransmitTask = Task { [weak self] in
            var interval = t1
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                guard let self, await self.isInviteCalling(key: key) else { return }
                try? await self.resendInvite(key: key)
                interval = interval * 2
            }
        }
    }

    private func isPending(key: String) -> Bool {
        clientTransactions[key] != nil
    }

    private func isInviteCalling(key: String) -> Bool {
        inviteTransactions[key]?.state == .calling
    }

    private func resend(key: String) async throws {
        guard let data = clientTransactions[key]?.data else { return }
        try await channel.send(data)
    }

    private func resendInvite(key: String) async throws {
        guard let data = inviteTransactions[key]?.data else { return }
        try await channel.send(data)
    }

    private func forgetResponse(branch: String) {
        sentResponses.removeValue(forKey: branch)
    }

    // MARK: - Приём

    private func handle(_ event: SIPTransportEvent) async {
        switch event {
        case .ready(let local):
            localEndpoint = local
            failureReason = nil
            let waiters = readinessWaiters
            readinessWaiters.removeAll()
            for waiter in waiters {
                waiter.resume(returning: local)
            }

        case .received(let data):
            await handleReceived(data)

        case .failed(let reason):
            failureReason = reason
            failReadiness(with: .transportFailed(reason))
            failAll(with: .transportFailed(reason))

        case .cancelled:
            failReadiness(with: .cancelled)
            failAll(with: .cancelled)
        }
    }

    private func handleReceived(_ data: Data) async {
        let message: SIPMessage
        do {
            message = try SIPParser.parse(data)
        } catch {
            // Битое сообщение — не повод рвать канал: на UDP это может быть
            // чужой мусор, залетевший на наш порт.
            return
        }

        switch message {
        case .response(let response):
            await handle(response: response)

        case .request(let request):
            // ACK — подтверждение, а не запрос: отвечать на него нечем, и
            // повторять ему кэшированный ответ нельзя. А он приходит с тем же
            // branch, что INVITE, и без этой проверки на каждый ACK уходил бы
            // повтор нашего же 486 — собеседник читал бы это как новый отказ.
            if request.method == .ack {
                if absorbAcknowledgement(request) { return }
                inboundContinuation.yield(request)
                return
            }

            // Ретрансмиссия: тот же branch и тот же метод, что у уже отвеченного
            // запроса. Метод проверяем обязательно — CANCEL несёт branch
            // отменяемого INVITE, и без проверки получил бы в ответ его 180.
            if let branch = request.topVia?.branch,
               let previous = sentResponses[branch],
               previous.cseq?.method == request.method {
                try? await channel.send(previous.encoded())
                return
            }
            inboundContinuation.yield(request)
        }
    }

    private func handle(response: SIPResponse) async {
        // Сопоставление по RFC 3261 §17.1.3: branch верхнего Via плюс метод из
        // CSeq. Только branch недостаточно.
        guard let branch = response.topVia?.branch, let cseq = response.cseq else { return }
        let key = Self.transactionKey(branch: branch, method: cseq.method)

        if cseq.method == .invite {
            await handleInvite(response: response, key: key)
            return
        }

        guard clientTransactions[key] != nil else { return }

        guard response.isFinal else {
            // 1xx на не-INVITE: запрос сервером получен, ретрансмиссии больше
            // не нужны.
            clientTransactions[key]?.retransmitTask?.cancel()
            clientTransactions[key]?.retransmitTask = nil
            return
        }

        finish(key: key, with: .success(response))
    }

    private func handleInvite(response: SIPResponse, key: String) async {
        guard var transaction = inviteTransactions[key], transaction.state != .completed else { return }

        if response.isProvisional {
            transaction.retransmitTask?.cancel()
            transaction.retransmitTask = nil
            transaction.timeoutTask?.cancel()
            transaction.timeoutTask = nil
            transaction.state = .proceeding
            inviteTransactions[key] = transaction
            transaction.continuation.yield(.provisional(response))
            return
        }

        transaction.retransmitTask?.cancel()
        transaction.timeoutTask?.cancel()

        if response.isSuccess {
            // Транзакция на 2xx завершается немедленно, а ACK отправит
            // вызывающая сторона — он идёт вне транзакции.
            inviteTransactions.removeValue(forKey: key)
            transaction.continuation.yield(.success(response))
            transaction.continuation.finish()
            return
        }

        // Состояние меняем и записываем ДО отправки ACK.
        //
        // Отправка асинхронная, а актор на каждом await переоткрывается: пока
        // ACK уходит в сеть, внутрь успевает войти уже отменённая задача
        // таймера B, увидеть состояние calling и объявить транзакцию
        // истёкшей — вместо полученного отказа. Ошибка воспроизводилась
        // стабильно и выглядела как таймаут через девять миллисекунд.
        transaction.state = .completed
        inviteTransactions[key] = transaction
        transaction.continuation.yield(.failure(response))

        // Неуспешный финальный ответ: ACK — наша обязанность и часть транзакции.
        let ack = Self.makeFailureACK(for: transaction.request, response: response)
        try? await channel.send(ack.encoded())

        // Таймер D: держим состояние, чтобы поглощать ретрансмиссии ответа и
        // отвечать на них тем же ACK.
        let lifetime = channel.transport.isReliable ? Duration.zero : timers.completedLifetime
        inviteTransactions[key]?.completedTask = Task { [weak self] in
            if lifetime > .zero {
                do { try await Task.sleep(for: lifetime) } catch { return }
            }
            await self?.removeInvite(key: key)
        }
    }

    private func expireInvite(key: String) {
        guard let transaction = inviteTransactions[key], transaction.state == .calling else { return }
        inviteTransactions.removeValue(forKey: key)
        transaction.retransmitTask?.cancel()
        transaction.continuation.yield(.timeout)
        transaction.continuation.finish()
    }

    private func failInvite(key: String, reason: String) {
        guard let transaction = inviteTransactions.removeValue(forKey: key) else { return }
        transaction.retransmitTask?.cancel()
        transaction.timeoutTask?.cancel()
        transaction.continuation.yield(.transportFailed(reason: reason))
        transaction.continuation.finish()
    }

    private func removeInvite(key: String) {
        guard let transaction = inviteTransactions.removeValue(forKey: key) else { return }
        transaction.completedTask?.cancel()
        transaction.continuation.finish()
    }

    private func finish(key: String, with result: Result<SIPResponse, Error>) {
        guard var transaction = clientTransactions.removeValue(forKey: key) else { return }
        transaction.retransmitTask?.cancel()
        transaction.timeoutTask?.cancel()

        guard let continuation = transaction.continuation else { return }
        transaction.continuation = nil
        continuation.resume(with: result)
    }

    private func failAll(with error: TransactionError) {
        for key in Array(clientTransactions.keys) {
            finish(key: key, with: .failure(error))
        }
        for key in Array(inviteTransactions.keys) {
            failInvite(key: key, reason: "\(error)")
        }
    }

    private func failReadiness(with error: TransactionError) {
        let waiters = readinessWaiters
        readinessWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }
}
