import Compat
import Foundation
import Testing
@testable import SIPCore

@Suite("Регистрация", .timeLimit(.minutes(1)))
struct RegistrationTests {

    private func makeAgent(
        server: ScriptedSIPServer,
        account: SIPAccount? = nil
    ) -> SIPUserAgent {
        SIPUserAgent(
            account: account ?? testAccount(transport: server.transport),
            credentials: testCredentials,
            channel: server,
            timers: fastTimers()
        )
    }

    @Test("Проходит вызов 401 и регистрируется")
    func registersAfterChallenge() async throws {
        let server = ScriptedSIPServer { request, index in
            index == 0
                ? ScriptedSIPServer.unauthorized(to: request)
                : ScriptedSIPServer.registrationAccepted(to: request, expires: 300)
        }

        let agent = makeAgent(server: server)
        await agent.start()

        #expect(await waitUntil { await agent.registrationState.isRegistered })
        await agent.stop()

        let requests = server.receivedRequests
        #expect(requests.count >= 2)

        // Первый запрос идёт без авторизации: пароль отдаём только в ответ на
        // конкретный nonce, а не всем, кто попросит.
        #expect(requests[0].headers["Authorization"] == nil)

        let authorization = try #require(requests[1].headers["Authorization"])
        #expect(authorization.contains("Digest "))
        #expect(authorization.contains(#"username="100""#))
        #expect(authorization.contains(#"realm="asterisk""#))
        #expect(authorization.contains(#"nonce="1234abcd""#))
        #expect(authorization.contains(#"uri="sip:127.0.0.1""#))

        // CSeq обязан расти: повтор с тем же номером Asterisk сочтёт
        // ретрансмиссией и ответит тем же 401.
        let firstCSeq = try #require(requests[0].cseq?.number)
        let secondCSeq = try #require(requests[1].cseq?.number)
        #expect(secondCSeq == firstCSeq + 1)

        // Call-ID и tag в серии регистраций не меняются.
        #expect(requests[0].callID == requests[1].callID)
        #expect(requests[0].from?.tag == requests[1].from?.tag)
    }

    @Test("Contact берёт внешний адрес из received и rport")
    func usesObservedAddressInContact() async throws {
        // Ключевая проверка для удалённых сотрудников: за NAT локальный адрес в
        // Contact означает «регистрация есть, звонки не приходят».
        let observed = SIPEndpoint(host: "203.0.113.7", port: 41234)
        let server = ScriptedSIPServer { request, index in
            index == 0
                ? ScriptedSIPServer.unauthorized(to: request, observedAddress: observed)
                : ScriptedSIPServer.registrationAccepted(to: request, observedAddress: observed)
        }

        let agent = makeAgent(server: server)
        await agent.start()
        #expect(await waitUntil { await agent.registrationState.isRegistered })
        await agent.stop()

        let requests = server.receivedRequests
        let firstContact = try #require(requests[0].contacts.first)
        #expect(firstContact.uri.host == "192.168.1.50", "до ответа сервера знаем только локальный адрес")

        let authorizedContact = try #require(requests[1].contacts.first)
        #expect(authorizedContact.uri.host == "203.0.113.7")
        #expect(authorizedContact.uri.port == 41234)

        // Via при этом остаётся с локальным адресом: это адрес отправителя, а
        // не тот, которым нас видно.
        #expect(requests[1].topVia?.host == "192.168.1.50")
        #expect(requests[1].topVia?.hasParameter("rport") == true)
    }

    @Test("Повторная регистрация несёт авторизацию сразу")
    func refreshUsesPreemptiveAuthorization() async throws {
        let server = ScriptedSIPServer { request, index in
            index == 0
                ? ScriptedSIPServer.unauthorized(to: request)
                : ScriptedSIPServer.registrationAccepted(to: request)
        }

        let agent = makeAgent(server: server)
        await agent.start()
        #expect(await waitUntil { await agent.registrationState.isRegistered })

        await agent.reregisterNow()
        #expect(await waitUntil { server.receivedRequests.count >= 3 })
        await agent.stop()

        // Третий запрос — уже обновление. Оно должно нести Authorization без
        // нового круга 401, иначе каждое обновление удваивает трафик.
        let refresh = server.receivedRequests[2]
        let authorization = try #require(refresh.headers["Authorization"])
        #expect(authorization.contains("nonce=\"1234abcd\""))
        #expect(server.receivedRequests.count < 5, "лишних кругов авторизации быть не должно")
    }

    @Test("423 Interval Too Brief повторяется с Min-Expires")
    func honoursMinExpires() async throws {
        let server = ScriptedSIPServer { request, index in
            switch index {
            case 0:
                ScriptedSIPServer.unauthorized(to: request)
            case 1:
                ScriptedSIPServer.response(
                    to: request,
                    status: 423,
                    extraHeaders: [(SIPHeaderName.minExpires, "600")]
                )
            default:
                ScriptedSIPServer.registrationAccepted(to: request, expires: 600)
            }
        }

        let agent = makeAgent(server: server, account: testAccount(expires: 120))
        await agent.start()
        #expect(await waitUntil { await agent.registrationState.isRegistered })
        await agent.stop()

        let requests = server.receivedRequests
        #expect(requests[1].expires == 120)
        #expect(requests[2].expires == 600, "после 423 срок берётся из Min-Expires")
    }

    @Test("403 объясняется человеческим языком и не повторяется бесконечно")
    func rejectsBadCredentials() async throws {
        let server = ScriptedSIPServer { request, index in
            index == 0
                ? ScriptedSIPServer.unauthorized(to: request)
                : ScriptedSIPServer.response(to: request, status: 403)
        }

        let agent = makeAgent(server: server)
        await agent.start()

        #expect(await waitUntil {
            if case .failed = await agent.registrationState { return true }
            return false
        })

        guard case .failed(let reason, _) = await agent.registrationState else {
            Issue.record("ожидалось состояние ошибки")
            return
        }
        await agent.stop()

        #expect(reason.contains("логин") || reason.contains("пароль"), "получили: \(reason)")
    }

    @Test("Повторный 401 на уже подписанный запрос — это неверный пароль")
    func detectsWrongPasswordBehindRepeatedChallenge() async throws {
        // Asterisk с alwaysauthreject=yes на неверный пароль отвечает не 403, а
        // тем же 401, чтобы не выдавать, существует ли номер. Если не распознать
        // это, самая частая реальная ошибка выглядит как «слишком много попыток».
        let server = ScriptedSIPServer { request, index in
            ScriptedSIPServer.unauthorized(to: request, nonce: "nonce-\(index)")
        }

        let agent = makeAgent(server: server)
        await agent.start()

        #expect(await waitUntil {
            if case .failed = await agent.registrationState { return true }
            return false
        })

        guard case .failed(let reason, _) = await agent.registrationState else {
            Issue.record("ожидалось состояние ошибки")
            return
        }
        await agent.stop()

        #expect(reason.contains("пароль"), "получили: \(reason)")
        #expect(server.receivedRequests.count <= 3, "не должно долбить сервер по кругу")
    }

    @Test("Снятие регистрации тоже проходит авторизацию")
    func unregisterAnswersChallenge() async throws {
        // Первый REGISTER, вызов, успех — а на снятии сервер выдаёт НОВЫЙ nonce.
        // Без обработки этого 401 пир остаётся зарегистрированным до истечения.
        let server = ScriptedSIPServer { request, index in
            switch index {
            case 0: ScriptedSIPServer.unauthorized(to: request, nonce: "first")
            case 1: ScriptedSIPServer.registrationAccepted(to: request)
            case 2: ScriptedSIPServer.unauthorized(to: request, nonce: "second")
            default: ScriptedSIPServer.registrationAccepted(to: request, expires: 0)
            }
        }

        let agent = makeAgent(server: server)
        await agent.start()
        #expect(await waitUntil { await agent.registrationState.isRegistered })
        await agent.stop()

        let requests = server.receivedRequests
        #expect(requests.count >= 4, "снятие должно быть повторено с новым вызовом")

        let unregisters = requests.filter { $0.expires == 0 }
        #expect(unregisters.count == 2)
        let authorized = try #require(unregisters.last?.headers["Authorization"])
        #expect(authorized.contains("nonce=\"second\""), "повтор обязан использовать свежий nonce")
    }

    @Test("На UDP запрос повторяется, если ответа нет")
    func retransmitsOverUDP() async throws {
        // Потеря одной датаграммы не должна ронять регистрацию — иначе она будет
        // случайным образом отваливаться на плохой сети.
        let server = ScriptedSIPServer { request, index in
            index == 0 ? nil : ScriptedSIPServer.unauthorized(to: request)
        }

        let agent = makeAgent(server: server)
        await agent.start()
        #expect(await waitUntil { server.receivedRequests.count >= 2 })
        await agent.stop()

        let requests = server.receivedRequests
        #expect(requests[0].cseq?.number == requests[1].cseq?.number, "ретрансмиссия — это тот же запрос, а не новый")
        #expect(requests[0].topVia?.branch == requests[1].topVia?.branch, "branch у ретрансмиссии не меняется")
    }

    @Test("На TLS ретрансмиссий нет")
    func doesNotRetransmitOverReliableTransport() async throws {
        // Доставку гарантирует TCP. Повтор сервер воспримет как новый запрос.
        let server = ScriptedSIPServer(transport: .tls) { _, _ in nil }

        let agent = makeAgent(server: server)
        await agent.start()

        // Ждём дольше, чем несколько интервалов T1, но меньше таймера F.
        try await Task.sleep(.milliseconds(700))
        let count = server.receivedRequests.count
        await agent.stop()

        #expect(count == 1, "на надёжном транспорте запрос отправляется один раз, отправлено \(count)")
    }

    @Test("Молчание сервера заканчивается понятной ошибкой")
    func reportsTimeout() async throws {
        let server = ScriptedSIPServer { _, _ in nil }

        let agent = makeAgent(server: server)
        await agent.start()

        // Таймер F с быстрыми таймерами — 50 мс * 64 = 3.2 с.
        #expect(await waitUntil(.seconds(8)) {
            if case .failed(_, let retryAt) = await agent.registrationState { return retryAt != nil }
            return false
        })

        guard case .failed(let reason, _) = await agent.registrationState else {
            Issue.record("ожидалось состояние ошибки")
            return
        }
        await agent.stop()

        #expect(reason.contains("не ответил"), "получили: \(reason)")
    }

    @Test("Обрыв транспорта не оставляет регистрацию в подвешенном состоянии")
    func handlesTransportFailure() async throws {
        let server = ScriptedSIPServer { _, _ in nil }
        let agent = makeAgent(server: server)
        await agent.start()

        #expect(await waitUntil { server.receivedRequests.count >= 1 })
        server.fail(reason: "сеть недоступна")

        #expect(await waitUntil {
            if case .failed = await agent.registrationState { return true }
            return false
        })
        await agent.stop()
    }

    @Test("Снятие регистрации отправляет Expires: 0")
    func unregistersOnStop() async throws {
        let server = ScriptedSIPServer { request, index in
            index == 0
                ? ScriptedSIPServer.unauthorized(to: request)
                : ScriptedSIPServer.registrationAccepted(to: request)
        }

        let agent = makeAgent(server: server)
        await agent.start()
        #expect(await waitUntil { await agent.registrationState.isRegistered })
        await agent.stop()

        let last = try #require(server.receivedRequests.last)
        #expect(last.method == .register)
        #expect(last.expires == 0, "снятие регистрации — это REGISTER с нулевым сроком")
    }

    @Test("Интервал обновления заведомо раньше истечения")
    func refreshIntervalIsSafe() {
        // Обновляться в последнюю секунду нельзя: одна потерянная датаграмма
        // оставит клиента без регистрации, и входящие пропадут.
        #expect(SIPUserAgent.refreshInterval(forGrantedExpires: 300) == 270)
        #expect(SIPUserAgent.refreshInterval(forGrantedExpires: 60) == 30)
        #expect(SIPUserAgent.refreshInterval(forGrantedExpires: 40) == 20)
        #expect(SIPUserAgent.refreshInterval(forGrantedExpires: 20) == 15)
        #expect(SIPUserAgent.refreshInterval(forGrantedExpires: 10) == 5)
        #expect(SIPUserAgent.refreshInterval(forGrantedExpires: 0) == 30)

        for expires in 1...600 {
            let interval = SIPUserAgent.refreshInterval(forGrantedExpires: expires)
            #expect(interval > 0)
            #expect(interval < expires || expires <= 10, "срок \(expires) обновляется через \(interval)")
        }
    }

    @Test("Откат растёт и упирается в потолок")
    func backoffGrows() {
        #expect(SIPUserAgent.backoffDelay(forAttempt: 1) == 5)
        #expect(SIPUserAgent.backoffDelay(forAttempt: 2) == 10)
        #expect(SIPUserAgent.backoffDelay(forAttempt: 3) == 20)
        #expect(SIPUserAgent.backoffDelay(forAttempt: 4) == 40)
        #expect(SIPUserAgent.backoffDelay(forAttempt: 5) == 80)
        #expect(SIPUserAgent.backoffDelay(forAttempt: 6) == 160)
        #expect(SIPUserAgent.backoffDelay(forAttempt: 7) == 300)
        #expect(SIPUserAgent.backoffDelay(forAttempt: 100) == 300, "потолок нужен, чтобы не уйти в часы ожидания")
    }
}
