import Compat
import Foundation
import Testing
@testable import SIPCore

@Suite("Таймер сессии", .timeLimit(.minutes(1)))
struct SessionTimerTests {

    // MARK: - Разбор заголовка

    @Test("Разбирается срок с ролью обновляющего")
    func parsesExpiresWithRefresher() throws {
        let parsed = try #require(SIPSessionTimer.parse("1800;refresher=uas"))
        #expect(parsed.expires == 1800)
        #expect(parsed.refresher == .uas)
    }

    @Test("Разбирается срок без роли")
    func parsesExpiresWithoutRefresher() throws {
        let parsed = try #require(SIPSessionTimer.parse("1800"))
        #expect(parsed.expires == 1800)
        // Именно nil, а не подставленная роль: сторона о ролях не высказалась,
        // и додумывать за неё нельзя — обновлять стали бы либо оба, либо никто.
        #expect(parsed.refresher == nil)
    }

    @Test("Регистр и пробелы разбору не мешают")
    func parseIsCaseInsensitive() throws {
        let parsed = try #require(SIPSessionTimer.parse(" 900 ;REFRESHER=UAC"))
        #expect(parsed.expires == 900)
        #expect(parsed.refresher == .uac)
    }

    @Test("Негодное значение не разбирается")
    func rejectsGarbage() {
        #expect(SIPSessionTimer.parse("") == nil)
        #expect(SIPSessionTimer.parse("не число") == nil)
        // Ноль и отрицательное — не «сессия без срока», а испорченный заголовок.
        #expect(SIPSessionTimer.parse("0") == nil)
        #expect(SIPSessionTimer.parse("-5") == nil)
    }

    @Test("Заголовок собирается обратно в разбираемый вид")
    func headerValueRoundTrips() throws {
        let timer = SIPSessionTimer(expires: 1800, refresher: .uas)
        #expect(timer.headerValue == "1800;refresher=uas")
        let parsed = try #require(SIPSessionTimer.parse(timer.headerValue))
        #expect(parsed.expires == timer.expires)
        #expect(parsed.refresher == timer.refresher)
    }

    // MARK: - Моменты срабатывания

    @Test("Обновляем на середине срока, а следим до конца")
    func timingFollowsRFC() {
        let timer = SIPSessionTimer(expires: 1800, refresher: .uas)
        // Половина, чтобы одно потерянное обновление не обрывало разговор:
        // второй заход успевает пройти до истечения.
        #expect(timer.refreshAfter == .seconds(900))
        #expect(timer.expireAfter == .seconds(1800))
    }

    @Test("Крошечный срок не превращается в нулевые интервалы")
    func timingNeverCollapsesToZero() {
        // Нулевой интервал в цикле обновления означал бы занятое ожидание,
        // а нулевой в слежении — трубку, положенную мгновенно.
        let timer = SIPSessionTimer(expires: 1, refresher: .uas)
        #expect(timer.refreshAfter > .zero)
        #expect(timer.expireAfter > .zero)
    }

    // MARK: - Договорённость по ответу сервера

    @Test("Молчание сервера означает отсутствие таймера")
    func silenceMeansNoTimer() {
        // Ключевая гарантия: без подтверждения сервера таймер не заводится.
        // Иначе мы следили бы за сроком, о котором вторая сторона не знает, и
        // положили бы трубку посреди работающего разговора.
        let policy = SIPSessionTimerPolicy()
        #expect(policy.negotiated(fromResponse: SIPHeaders()) == nil)
    }

    @Test("Ответ без роли читается как «обновляет сервер»")
    func responseWithoutRefresherDefaultsToUAS() throws {
        var headers = SIPHeaders()
        headers.append(SIPSessionTimerHeader.sessionExpires, "1800")

        let timer = try #require(SIPSessionTimerPolicy().negotiated(fromResponse: headers))
        #expect(timer.expires == 1800)
        #expect(timer.refresher == .uas)
    }

    @Test("Сервер вправе назначить обновляющим нас")
    func responseMayMakeUsRefresher() throws {
        var headers = SIPHeaders()
        headers.append(SIPSessionTimerHeader.sessionExpires, "600;refresher=uac")

        let timer = try #require(SIPSessionTimerPolicy().negotiated(fromResponse: headers))
        #expect(timer.expires == 600)
        #expect(timer.refresher == .uac)
    }

    @Test("Выключенная политика не заводит таймер даже на согласие сервера")
    func disabledPolicyIgnoresServer() {
        var headers = SIPHeaders()
        headers.append(SIPSessionTimerHeader.sessionExpires, "1800;refresher=uas")

        let policy = SIPSessionTimerPolicy(isEnabled: false)
        #expect(policy.negotiated(fromResponse: headers) == nil)
    }

    // MARK: - Договорённость по входящему

    @Test("Звонящему, не просившему таймер, его не навязываем")
    func incomingWithoutOfferGetsNoTimer() {
        #expect(SIPSessionTimerPolicy().negotiated(forIncoming: SIPHeaders()) == nil)
    }

    @Test("На входящем обновляющим назначается звонящий")
    func incomingMakesCallerRefresh() throws {
        var headers = SIPHeaders()
        headers.append(SIPSessionTimerHeader.sessionExpires, "1800")

        let timer = try #require(SIPSessionTimerPolicy().negotiated(forIncoming: headers))
        #expect(timer.refresher == .uac)
        #expect(timer.expires == 1800)
    }

    @Test("Слишком короткий срок входящего поднимается до нашего порога")
    func incomingTooShortIsRaised() throws {
        var headers = SIPHeaders()
        headers.append(SIPSessionTimerHeader.sessionExpires, "30")

        let policy = SIPSessionTimerPolicy(minimumExpires: 90)
        let timer = try #require(policy.negotiated(forIncoming: headers))
        #expect(timer.expires == 90)
    }

    // MARK: - Обмен с сервером

    @Test("В INVITE уходит предложение таймера и объявляется поддержка")
    func inviteOffersTimer() async throws {
        let server = ScriptedSIPServer { request, _ in
            request.method == .register
                ? ScriptedSIPServer.registrationAccepted(to: request, expires: 300)
                : nil
        }

        let agent = SIPUserAgent(
            account: testAccount(transport: server.transport),
            credentials: testCredentials,
            channel: server,
            timers: fastTimers()
        )
        await agent.start()
        _ = await agent.placeCall(to: "600", offer: Data("v=0".utf8))

        #expect(await waitUntil { server.receivedRequests.contains { $0.method == .invite } })
        await agent.stop()

        let invite = try #require(server.receivedRequests.first { $0.method == .invite })

        let offered = try #require(invite.headers[SIPSessionTimerHeader.sessionExpires])
        let parsed = try #require(SIPSessionTimer.parse(offered))
        #expect(parsed.expires == 1800)
        // Обновлять просим сервер: цена нашей ошибки — брошенный живой
        // разговор, цена его — разговор, который и правда мёртв.
        #expect(parsed.refresher == .uas)

        #expect(invite.headers.integer(SIPSessionTimerHeader.minSE) == 90)

        let supported = try #require(invite.headers[SIPHeaderName.supported])
        #expect(supported.contains(SIPSessionTimerHeader.optionTag))

        // UPDATE в Allow быть не должно: chan_sip шлёт обновление повторным
        // INVITE ровно потому, что мы не объявили UPDATE, а обработать UPDATE
        // нам нечем.
        let allow = try #require(invite.headers[SIPHeaderName.allow])
        #expect(!allow.contains("UPDATE"))
    }

    @Test("Отказ 422 повторяется с порогом сервера")
    func retriesAfter422() async throws {
        let server = ScriptedSIPServer { request, _ in
            guard request.method == .invite else {
                return ScriptedSIPServer.registrationAccepted(to: request, expires: 300)
            }
            let offered = request.headers[SIPSessionTimerHeader.sessionExpires]
                .flatMap { SIPSessionTimer.parse($0) }?.expires ?? 0
            // Порог намеренно выше того, что клиент предлагает по умолчанию.
            guard offered >= 3600 else {
                return ScriptedSIPServer.response(
                    to: request,
                    status: 422,
                    extraHeaders: [(SIPSessionTimerHeader.minSE, "3600")]
                )
            }
            return nil
        }

        let agent = SIPUserAgent(
            account: testAccount(transport: server.transport),
            credentials: testCredentials,
            channel: server,
            timers: fastTimers()
        )
        await agent.start()
        _ = await agent.placeCall(to: "600", offer: Data("v=0".utf8))

        #expect(await waitUntil {
            server.receivedRequests.filter { $0.method == .invite }.count >= 2
        })
        await agent.stop()

        let invites = server.receivedRequests.filter { $0.method == .invite }
        let second = try #require(invites.dropFirst().first)
        let retried = try #require(second.headers[SIPSessionTimerHeader.sessionExpires])

        // Повтор обязан нести срок не ниже названного сервером, иначе получился
        // бы вечный круг одинаковых запросов и одинаковых отказов.
        #expect(try #require(SIPSessionTimer.parse(retried)).expires >= 3600)
        #expect(second.headers.integer(SIPSessionTimerHeader.minSE) == 3600)
    }

    @Test("Сервер промолчал про срок — таймер не заводится")
    func noTimerWhenServerStaysSilent() async throws {
        // Тот же сценарий, что в жизни у сервера без RFC 4028: звонок проходит,
        // трубку никто не кладёт.
        let server = ScriptedSIPServer { request, _ in
            switch request.method {
            case .register:
                return ScriptedSIPServer.registrationAccepted(to: request, expires: 300)
            case .invite:
                return ScriptedSIPServer.response(
                    to: request,
                    status: 200,
                    extraHeaders: [(SIPHeaderName.contact, "<sip:600@127.0.0.1>")]
                )
            default:
                return ScriptedSIPServer.response(to: request, status: 200)
            }
        }

        let agent = SIPUserAgent(
            account: testAccount(transport: server.transport),
            credentials: testCredentials,
            channel: server,
            timers: fastTimers(),
            // Срок, на котором таймер сработал бы почти сразу, если бы завёлся.
            sessionTimerPolicy: SIPSessionTimerPolicy(expires: 2, minimumExpires: 1)
        )
        await agent.start()
        let call = await agent.placeCall(to: "600", offer: Data("v=0".utf8))

        var answered = false
        for await event in call.events {
            if case .state(.answered) = event { answered = true; break }
        }
        #expect(answered)

        // Ждём заведомо дольше срока: BYE не должен появиться.
        try await Task.sleep(.milliseconds(300))
        #expect(!server.receivedRequests.contains { $0.method == .bye })

        await agent.stop()
    }

    // MARK: - Поведение таймера в разговоре

    /// Сервер отвечает на INVITE согласием на таймер с указанной ролью.
    private func answeringServer(
        sessionExpires: String,
        onReinvite: (@Sendable () -> Void)? = nil
    ) -> ScriptedSIPServer {
        ScriptedSIPServer { request, _ in
            switch request.method {
            case .register:
                return ScriptedSIPServer.registrationAccepted(to: request, expires: 300)
            case .invite:
                // Повторный INVITE отличается от первого наличием тега To:
                // диалог к этому моменту уже собран.
                if request.to?.tag != nil {
                    onReinvite?()
                    return ScriptedSIPServer.response(
                        to: request,
                        status: 200,
                        extraHeaders: [(SIPHeaderName.contact, "<sip:600@127.0.0.1>")]
                    )
                }
                return ScriptedSIPServer.response(
                    to: request,
                    status: 200,
                    extraHeaders: [
                        (SIPHeaderName.contact, "<sip:600@127.0.0.1>"),
                        (SIPSessionTimerHeader.sessionExpires, sessionExpires),
                    ]
                )
            default:
                return ScriptedSIPServer.response(to: request, status: 200)
            }
        }
    }

    private func answeredAgent(server: ScriptedSIPServer) async -> SIPUserAgent {
        let agent = SIPUserAgent(
            account: testAccount(transport: server.transport),
            credentials: testCredentials,
            channel: server,
            timers: fastTimers()
        )
        await agent.start()
        let call = await agent.placeCall(to: "600", offer: Data("v=0".utf8))
        for await event in call.events {
            if case .state(.answered) = event { break }
        }
        return agent
    }

    @Test("Собеседник не обновил сессию — кладём трубку")
    func hangsUpWhenPeerStopsRefreshing() async throws {
        // Ради чего всё и затевалось: собеседник исчез, не прислав BYE — упало
        // питание, оборвался VPN, — и линия иначе висела бы вечно.
        let server = answeringServer(sessionExpires: "1;refresher=uas")
        let agent = await answeredAgent(server: server)

        #expect(await waitUntil(.seconds(6)) {
            server.receivedRequests.contains { $0.method == .bye }
        })

        await agent.stop()
    }

    @Test("Обновление от собеседника отменяет трубку")
    func peerRefreshPreventsHangUp() async throws {
        // Обратная сторона предыдущей проверки, и она важнее: механизм, который
        // кладёт трубку, обязан замолкать при живом собеседнике. Иначе он
        // обрывал бы каждый разговор длиннее срока сессии.
        let server = answeringServer(sessionExpires: "1;refresher=uas")
        let agent = await answeredAgent(server: server)

        // Срок сессии здесь — 2 секунды (`expireAfter` не опускается ниже), и
        // обновление уходит заведомо раньше.
        try await Task.sleep(.milliseconds(1200))
        let refresh = SIPRequest(
            method: .invite,
            uri: SIPURI(user: "100", host: "127.0.0.1"),
            headers: inDialogHeaders(from: server, method: .invite)
        )
        server.inject(request: refresh)

        // Обновление принято: без ответа 200 повторный INVITE не состоялся бы,
        // и проверка ниже оказалась бы про несработавший таймер, а не про
        // перезаведённый.
        #expect(await waitUntil { server.sentResponses.contains { $0.statusCode == 200 } })

        // Дальше ждём дольше исходного срока: не перезаведись отсчёт, трубка
        // легла бы на второй секунде разговора.
        try await Task.sleep(.milliseconds(1400))
        #expect(!server.receivedRequests.contains { $0.method == .bye })

        await agent.stop()
    }

    @Test("Роль обновляющего у нас — уходит повторный INVITE")
    func refreshesWhenWeAreRefresher() async throws {
        let server = answeringServer(sessionExpires: "2;refresher=uac")
        let agent = await answeredAgent(server: server)

        // Обновление уходит на середине срока, то есть примерно через секунду.
        #expect(await waitUntil(.seconds(6)) {
            server.receivedRequests.filter { $0.method == .invite }.count >= 2
        })

        let refresh = try #require(
            server.receivedRequests.filter { $0.method == .invite }.dropFirst().first
        )
        // Обновляющий запрос обязан нести срок: без него собеседник читает его
        // как отказ от договорённости и снимает свой таймер.
        let carried = try #require(refresh.headers[SIPSessionTimerHeader.sessionExpires])
        #expect(try #require(SIPSessionTimer.parse(carried)).refresher == .uac)

        await agent.stop()
    }

    /// Заголовки запроса внутри уже установленного диалога.
    ///
    /// Собираются из того, что клиент прислал сам: сервер в этих проверках
    /// поддельный, и другого источника тегов и Call-ID у него нет.
    private func inDialogHeaders(from server: ScriptedSIPServer, method: SIPMethod) -> SIPHeaders {
        let invite = server.receivedRequests.first { $0.method == .invite }
        var headers = SIPHeaders()
        var via = SIPVia(transport: .udp, host: "127.0.0.1", port: 5060)
        via.branch = SIPToken.branch()
        headers.append(SIPHeaderName.via, via.description)
        headers.append(SIPHeaderName.maxForwards, "70")

        // From и To меняются местами: запрос идёт в обратную сторону.
        var from = NameAddress(uri: SIPURI(user: "600", host: "127.0.0.1"))
        from.tag = "as1a2b3c"
        headers.append(SIPHeaderName.from, from.description)

        var to = NameAddress(uri: SIPURI(user: "100", host: "127.0.0.1"))
        to.tag = invite?.from?.tag
        headers.append(SIPHeaderName.to, to.description)

        headers.append(SIPHeaderName.callID, invite?.callID ?? "")
        headers.append(SIPHeaderName.cseq, "9 \(method.rawValue)")
        headers.append(SIPHeaderName.contact, "<sip:600@127.0.0.1>")
        return headers
    }
}
