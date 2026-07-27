import Foundation

/// Слой транзакций: клиентские не-INVITE (RFC 3261 §17.1.2) и приём входящих
/// запросов.
///
/// Транзакция — это то, что отвечает за «дошло или нет». На UDP ответа можно не
/// дождаться просто потому, что пакет потерялся, и без ретрансмиссий регистрация
/// будет случайным образом отваливаться. INVITE-транзакции здесь нет намеренно:
/// у неё другая машина состояний, и она появится в M2 вместе со звонками.
public actor SIPTransactionLayer {

    public enum TransactionError: Error, Sendable, Equatable {
        /// Истёк таймер F: 64*T1, по умолчанию 32 секунды.
        case timeout
        case transportFailed(String)
        case cancelled
        case notReady
    }

    public struct Timers: Sendable, Hashable {
        /// Оценка RTT. Начальный интервал ретрансмиссий.
        public var t1: Duration = .milliseconds(500)
        /// Максимальный интервал ретрансмиссий.
        public var t2: Duration = .seconds(4)
        /// Максимальное время жизни сообщения в сети.
        public var t4: Duration = .seconds(5)

        public init() {}

        /// Таймер F — полный таймаут транзакции.
        public var transactionTimeout: Duration { t1 * 64 }
    }

    private struct ClientTransaction {
        let method: SIPMethod
        let data: Data
        var continuation: CheckedContinuation<SIPResponse, Error>?
        var retransmitTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
    }

    private let channel: SIPTransportChannel
    private let timers: Timers

    public nonisolated let inboundRequests: AsyncStream<SIPRequest>
    private nonisolated let inboundContinuation: AsyncStream<SIPRequest>.Continuation

    private var clientTransactions: [String: ClientTransaction] = [:]
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
        inboundContinuation.finish()
        await channel.stop()
    }

    /// Ждёт готовности канала и возвращает локальный адрес.
    ///
    /// Он нужен до отправки первого запроса: без него нечего писать в Via и
    /// Contact.
    public func waitUntilReady(timeout: Duration = .seconds(10)) async throws -> SIPEndpoint {
        if let localEndpoint { return localEndpoint }
        if let failureReason { throw TransactionError.transportFailed(failureReason) }

        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.failReadiness(with: .timeout)
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            readinessWaiters.append(continuation)
        }
    }

    // MARK: - Отправка

    /// Отправляет запрос и ждёт финального ответа.
    ///
    /// Ретрансмиссии и таймаут — внутри. Промежуточные ответы (1xx) не
    /// возвращаются: для не-INVITE они лишь переводят транзакцию в Proceeding.
    public func send(_ request: SIPRequest) async throws -> SIPResponse {
        var request = request

        // branch обязан быть, и он же — ключ транзакции.
        guard var via = request.topVia else { throw TransactionError.notReady }
        if via.branch == nil {
            via.branch = SIPToken.branch()
            request.headers.set(SIPHeaderName.via, to: via.description)
        }
        guard let branch = via.branch else { throw TransactionError.notReady }

        let data = request.encoded()
        let method = request.method

        return try await withCheckedThrowingContinuation { continuation in
            clientTransactions[branch] = ClientTransaction(
                method: method,
                data: data,
                continuation: continuation
            )

            let timeout = timers.transactionTimeout
            clientTransactions[branch]?.timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.finish(branch: branch, with: .failure(TransactionError.timeout))
            }

            Task { [weak self] in
                await self?.transmit(branch: branch, data: data)
            }
        }
    }

    /// Отправляет ответ на входящий запрос и запоминает его для ретрансмиссий.
    public func respond(to request: SIPRequest, with response: SIPResponse) async throws {
        if let branch = request.topVia?.branch {
            sentResponses[branch] = response
            // Держим ответ ровно столько, сколько сообщение может жить в сети.
            let lifetime = timers.t4 * 8
            Task { [weak self] in
                try? await Task.sleep(for: lifetime)
                await self?.forgetResponse(branch: branch)
            }
        }
        try await channel.send(response.encoded())
    }

    // MARK: - Внутреннее: передача

    private func transmit(branch: String, data: Data) async {
        do {
            try await channel.send(data)
        } catch {
            finish(branch: branch, with: .failure(TransactionError.transportFailed("\(error)")))
            return
        }

        // На надёжном транспорте повторять нельзя и не нужно: доставку
        // гарантирует TCP, а дубликат сервер воспримет как новый запрос.
        guard !channel.transport.isReliable else { return }

        let t1 = timers.t1
        let t2 = timers.t2
        clientTransactions[branch]?.retransmitTask = Task { [weak self] in
            var interval = t1
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                guard let self, await self.isPending(branch: branch) else { return }
                try? await self.resend(branch: branch)
                interval = min(interval * 2, t2)
            }
        }
    }

    private func isPending(branch: String) -> Bool {
        clientTransactions[branch] != nil
    }

    private func resend(branch: String) async throws {
        guard let data = clientTransactions[branch]?.data else { return }
        try await channel.send(data)
    }

    private func forgetResponse(branch: String) {
        sentResponses.removeValue(forKey: branch)
    }

    // MARK: - Внутреннее: приём

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
            handle(response: response)

        case .request(let request):
            // Ретрансмиссию уже отвеченного запроса гасим тем же ответом,
            // не поднимая её наверх.
            if let branch = request.topVia?.branch, let previous = sentResponses[branch] {
                try? await channel.send(previous.encoded())
                return
            }
            inboundContinuation.yield(request)
        }
    }

    private func handle(response: SIPResponse) {
        // Сопоставление по RFC 3261 §17.1.3: branch верхнего Via плюс метод из
        // CSeq. Только branch недостаточно — ответ на CANCEL несёт тот же
        // branch, что и отменяемый запрос.
        guard let branch = response.topVia?.branch,
              let transaction = clientTransactions[branch],
              response.cseq?.method == transaction.method
        else { return }

        guard response.isFinal else {
            // 1xx: Proceeding. Ретрансмиссии по RFC продолжаются с интервалом
            // T2, но запрос сервером уже получен, так что смысла в них нет —
            // прекращаем и ждём финальный ответ до таймера F.
            clientTransactions[branch]?.retransmitTask?.cancel()
            clientTransactions[branch]?.retransmitTask = nil
            return
        }

        finish(branch: branch, with: .success(response))
    }

    private func finish(branch: String, with result: Result<SIPResponse, Error>) {
        guard var transaction = clientTransactions.removeValue(forKey: branch) else { return }
        transaction.retransmitTask?.cancel()
        transaction.timeoutTask?.cancel()

        guard let continuation = transaction.continuation else { return }
        transaction.continuation = nil
        continuation.resume(with: result)
    }

    private func failAll(with error: TransactionError) {
        let branches = Array(clientTransactions.keys)
        for branch in branches {
            finish(branch: branch, with: .failure(error))
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
