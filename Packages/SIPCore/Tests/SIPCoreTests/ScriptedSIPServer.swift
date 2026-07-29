import Compat
import Foundation
@testable import SIPCore

/// Поддельный сервер вместо сети.
///
/// Существует ради того, чтобы гонять сценарии регистрации целиком — с вызовом
/// 401, ретрансмиссиями и правкой Contact — за миллисекунды и без Asterisk.
/// Живой сервер проверяет совместимость, а этот — логику.
final class ScriptedSIPServer: SIPTransportChannel, @unchecked Sendable {

    /// Что ответить на очередной запрос. `nil` — промолчать (проверка
    /// ретрансмиссий и таймаутов). Второй аргумент — номер запроса, начиная с 0.
    typealias Responder = @Sendable (SIPRequest, Int) -> SIPResponse?

    let transport: SIPTransport
    let remote: SIPEndpoint
    let local: SIPEndpoint
    let events: AsyncStream<SIPTransportEvent>

    private let continuation: AsyncStream<SIPTransportEvent>.Continuation
    private let responder: Responder
    private let lock = NSLock()

    private var receivedRequestsStorage: [SIPRequest] = []
    private var sentResponsesStorage: [SIPResponse] = []

    init(
        transport: SIPTransport = .udp,
        remote: SIPEndpoint = SIPEndpoint(host: "127.0.0.1", port: 5060),
        local: SIPEndpoint = SIPEndpoint(host: "192.168.1.50", port: 5060),
        responder: @escaping Responder
    ) {
        self.transport = transport
        self.remote = remote
        self.local = local
        self.responder = responder

        let (stream, continuation) = AsyncStream<SIPTransportEvent>.makeStream(bufferingPolicy: .unbounded)
        events = stream
        self.continuation = continuation
    }

    /// Запросы, которые прислал клиент.
    var receivedRequests: [SIPRequest] {
        lock.withLock { receivedRequestsStorage }
    }

    /// Ответы, которые прислал клиент (например на OPTIONS).
    var sentResponses: [SIPResponse] {
        lock.withLock { sentResponsesStorage }
    }

    func start() async {
        continuation.yield(.ready(local: local))
    }

    func send(_ data: Data) async throws {
        let message = try SIPParser.parse(data)

        switch message {
        case .response(let response):
            lock.withLock { sentResponsesStorage.append(response) }

        case .request(let request):
            let index = lock.withLock {
                receivedRequestsStorage.append(request)
                return receivedRequestsStorage.count - 1
            }

            if let response = responder(request, index) {
                continuation.yield(.received(response.encoded()))
            }
        }
    }

    func stop() async {
        continuation.finish()
    }

    /// Присылает клиенту запрос — так проверяются OPTIONS и входящий INVITE.
    func inject(request: SIPRequest) {
        continuation.yield(.received(request.encoded()))
    }

    /// Присылает клиенту ответ отдельно от `responder`.
    ///
    /// Нужно для INVITE: там на один запрос приходит несколько ответов (100,
    /// 180, потом 200), и выдать их одним возвратом из замыкания нельзя.
    func inject(response: SIPResponse) {
        continuation.yield(.received(response.encoded()))
    }

    func fail(reason: String) {
        continuation.yield(.failed(reason: reason))
    }
}

// MARK: - Сборка ответов

extension ScriptedSIPServer {

    /// Ответ с корректно скопированными заголовками, как это делает Asterisk,
    /// включая дописывание received и rport в верхний Via.
    static func response(
        to request: SIPRequest,
        status: Int,
        toTag: String = "as1a2b3c",
        observedAddress: SIPEndpoint? = SIPEndpoint(host: "192.168.65.1", port: 54321),
        extraHeaders: [(String, String)] = []
    ) -> SIPResponse {
        var headers = SIPHeaders()

        if var via = request.topVia {
            if let observedAddress {
                via[parameter: "received"] = observedAddress.host
                via[parameter: "rport"] = String(observedAddress.port)
            }
            headers.append(SIPHeaderName.via, via.description)
        }
        if let from = request.headers[SIPHeaderName.from] {
            headers.append(SIPHeaderName.from, from)
        }
        if var to = request.to {
            to.tag = toTag
            headers.append(SIPHeaderName.to, to.description)
        }
        if let callID = request.headers[SIPHeaderName.callID] {
            headers.append(SIPHeaderName.callID, callID)
        }
        if let cseq = request.headers[SIPHeaderName.cseq] {
            headers.append(SIPHeaderName.cseq, cseq)
        }
        for (name, value) in extraHeaders {
            headers.append(name, value)
        }

        return SIPResponse(statusCode: status, headers: headers)
    }

    /// 401 в том виде, в каком его шлёт chan_sip.
    static func unauthorized(
        to request: SIPRequest,
        nonce: String = "1234abcd",
        realm: String = "asterisk",
        observedAddress: SIPEndpoint? = SIPEndpoint(host: "192.168.65.1", port: 54321)
    ) -> SIPResponse {
        response(
            to: request,
            status: 401,
            observedAddress: observedAddress,
            extraHeaders: [(
                SIPHeaderName.wwwAuthenticate,
                "Digest algorithm=MD5, realm=\"\(realm)\", nonce=\"\(nonce)\""
            )]
        )
    }

    /// 200 OK на REGISTER с подтверждённым сроком в параметре Contact.
    static func registrationAccepted(
        to request: SIPRequest,
        expires: Int = 300,
        observedAddress: SIPEndpoint? = SIPEndpoint(host: "192.168.65.1", port: 54321)
    ) -> SIPResponse {
        let contact = request.contacts.first.map { contact -> String in
            var copy = contact
            copy[parameter: "expires"] = String(expires)
            return copy.description
        } ?? "<sip:100@127.0.0.1>;expires=\(expires)"

        return response(
            to: request,
            status: 200,
            observedAddress: observedAddress,
            extraHeaders: [(SIPHeaderName.contact, contact)]
        )
    }
}

// MARK: - Ожидание условий

/// Ждёт выполнения условия, опрашивая его часто.
///
/// В тестах асинхронных машин состояний фиксированный `sleep` — источник как
/// ложных падений, так и медленных прогонов. Опрос по условию быстрее и стабильнее.
@discardableResult
func waitUntil(
    _ timeout: Interval = .seconds(5),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = MonotonicClock.now + timeout
    while MonotonicClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(.milliseconds(5))
    }
    return await condition()
}

/// Быстрые таймеры: те же пропорции RFC, но в 10 раз короче, чтобы проверки
/// ретрансмиссий и таймаутов занимали доли секунды.
func fastTimers() -> SIPTransactionLayer.Timers {
    var timers = SIPTransactionLayer.Timers()
    timers.t1 = .milliseconds(50)
    timers.t2 = .milliseconds(400)
    timers.t4 = .milliseconds(500)
    // Таймер D по RFC — 32 секунды. В тестах он держал бы поток событий
    // открытым столько же, и прогон вырастал с семи секунд до тридцати двух.
    timers.completedLifetime = .milliseconds(300)
    return timers
}

func testAccount(transport: SIPTransport = .udp, expires: Int = 300) -> SIPAccount {
    SIPAccount(
        username: "100",
        displayName: "Agent 100",
        domain: "127.0.0.1",
        transport: transport,
        registrationExpires: expires
    )
}

let testCredentials = DigestAuthentication.Credentials(username: "100", password: "elite100")
