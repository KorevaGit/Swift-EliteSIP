import Compat
import Foundation
import Testing

@testable import SIPCore

/// Что бывает с каналом и кто об этом узнаёт.
///
/// Самая дорогая находка аудита бекенда жила ровно здесь: `NWConnection` в
/// состоянии `.failed` не поднимается никаким `start()`, поток его событий
/// кончается, и об этом никто не узнавал. Регистрация продолжала ходить по
/// кругу с backoff, каждая попытка падала мгновенно, и рабочее место молча
/// выпадало из раздачи лидов до перезапуска приложения — с обещанием «повтор
/// через N с» на экране.
@Suite("Жизненный цикл канала")
struct ChannelLifecycleTests {

    private func account(_ server: ScriptedSIPServer) -> SIPAccount {
        SIPAccount(
            username: "100",
            displayName: "Agent",
            domain: server.remote.host,
            serverPort: server.remote.port,
            transport: .udp,
            registrationExpires: 300
        )
    }

    private func agent(_ server: ScriptedSIPServer) -> SIPUserAgent {
        SIPUserAgent(
            account: account(server),
            credentials: .init(username: "100", password: "секрет"),
            channel: server
        )
    }

    // MARK: - Закрытие

    @Test("Закрытие канала доходит до транзакционного слоя")
    func closureReachesTransactionLayer() async throws {
        let server = ScriptedSIPServer { _, _ in nil }
        let layer = SIPTransactionLayer(channel: server)
        await layer.start()

        var closures = layer.channelClosures.makeAsyncIterator()
        server.close(reason: "сервер закрыл соединение")

        let reason = await closures.next()
        #expect(reason == "сервер закрыл соединение")
    }

    @Test("Закрытие канала доходит до приложения событием агента")
    func closureReachesTheApplication() async throws {
        let server = ScriptedSIPServer { _, _ in nil }
        let agent = agent(server)

        let events = agent.events
        await agent.start()

        // Ждём именно события закрытия: до него в потоке идут строки журнала и
        // смены состояния регистрации, и их количество к делу не относится.
        let closure = Task { () -> String? in
            for await event in events {
                if case .channelClosed(let reason) = event { return reason }
            }
            return nil
        }

        // Даём регистрации начаться: закрытие посреди живой работы — это тот
        // случай, который и надо поймать.
        try await Task.sleep(.milliseconds(50))
        server.close(reason: "нет маршрута до 127.0.0.1")

        let reason = await closure.value
        #expect(reason == "нет маршрута до 127.0.0.1")

        // И повторы регистрации на мёртвом канале прекращаются: обещать
        // «повтор через N с» там, где повтор ничего не даст, — врать человеку.
        let state = await agent.registrationState
        if case .failed(_, let retryAt) = state {
            #expect(retryAt == nil, "повтор не назначается: чинится это только пересборкой")
        } else {
            Issue.record("после закрытия канала состояние обязано быть «отказ», получено \(state)")
        }

        await agent.stop()
    }

    @Test("Закрытие роняет запросы в пути")
    func closureFailsInFlightRequests() async throws {
        let server = ScriptedSIPServer { _, _ in nil }
        let layer = SIPTransactionLayer(channel: server)
        await layer.start()
        _ = try await layer.waitUntilReady()

        let pending = Task { () -> Bool in
            do {
                _ = try await layer.send(Self.options())
                return false
            } catch {
                return true
            }
        }

        try await Task.sleep(.milliseconds(50))
        server.close(reason: "соединение отказало")

        #expect(await pending.value, "ждать ответа на мёртвом канале не за чем")
    }

    // MARK: - Отказ, после которого канал жив

    @Test("Временный отказ не роняет запрос в пути")
    func transientFailureKeepsRequestsAlive() async throws {
        let server = ScriptedSIPServer { _, _ in nil }
        let layer = SIPTransactionLayer(channel: server)
        await layer.start()
        _ = try await layer.waitUntilReady()

        let finished = UnfairLock(initialState: false)
        let pending = Task {
            _ = try? await layer.send(Self.options())
            finished.withLock { $0 = true }
        }
        defer { pending.cancel() }

        try await Task.sleep(.milliseconds(50))
        // Так выглядит подрагивание Wi-Fi: Network.framework сообщает об отказе
        // и повторяет попытку сам. Раньше каждый такой отказ обрывал REGISTER,
        // backoff рос, и после перехода между точками доступа регистрация
        // возвращалась не сразу, а следующим его шагом — до пяти минут без
        // входящих.
        server.fail(reason: "нет маршрута")
        try await Task.sleep(.milliseconds(150))

        #expect(!finished.withLock { $0 }, "у транзакции есть свой таймер, он для этого и заведён")
    }

    @Test("Поднявшийся канал переживает временный отказ")
    func transientFailureDoesNotDisableAReadyChannel() async throws {
        let server = ScriptedSIPServer { request, _ in
            ScriptedSIPServer.response(to: request, status: 200)
        }
        let layer = SIPTransactionLayer(channel: server)
        await layer.start()
        _ = try await layer.waitUntilReady()

        server.fail(reason: "нет маршрута")
        try await Task.sleep(.milliseconds(50))

        // Локальный адрес известен, и отдавать его надо по-прежнему. Отказывать
        // здесь значило бы запретить набор на время подрагивания Wi-Fi — а
        // Network.framework в это время как раз повторяет попытку.
        #expect(try await layer.waitUntilReady(timeout: .milliseconds(100)) == server.local)
        let response = try await layer.send(Self.options())
        #expect(response.statusCode == 200)
    }

    @Test("Отказ до готовности называет причину, а не молчит десять секунд")
    func failureBeforeReadinessIsReportedAtOnce() async throws {
        let server = ScriptedSIPServer.neverReady()
        let layer = SIPTransactionLayer(channel: server)
        await layer.start()

        server.fail(reason: "нет маршрута до 192.168.1.2")
        try await Task.sleep(.milliseconds(50))

        // Канал ни разу не поднимался, и ждать его молча целый таймаут незачем:
        // причина уже известна, и человеку нужна именно она.
        await #expect(
            throws: SIPTransactionLayer.TransactionError
                .transportFailed("нет маршрута до 192.168.1.2")
        ) {
            _ = try await layer.waitUntilReady(timeout: .seconds(10))
        }

        // А когда канал всё-таки поднимется, прошлый отказ забывается.
        server.becomeReady()
        try await Task.sleep(.milliseconds(50))
        #expect(try await layer.waitUntilReady(timeout: .milliseconds(100)) == server.local)
    }

    // MARK: - Ожидание готовности

    @Test("Таймаут одного ожидающего не роняет остальных")
    func readinessTimeoutsAreIndependent() async throws {
        let server = ScriptedSIPServer.neverReady()
        let layer = SIPTransactionLayer(channel: server)
        await layer.start()

        // Первый ждёт недолго, второй — долго. Общий таймер ронял обоих на
        // сроке первого: второй звонок получал чужой таймаут.
        let impatient = Task { () -> Error? in
            do {
                _ = try await layer.waitUntilReady(timeout: .milliseconds(150))
                return nil
            } catch {
                return error
            }
        }
        let patient = Task { () -> SIPEndpoint? in
            try? await layer.waitUntilReady(timeout: .seconds(5))
        }

        let failure = await impatient.value
        #expect(failure as? SIPTransactionLayer.TransactionError == .timeout)

        // Второй всё ещё ждёт — и дожидается.
        server.becomeReady()
        #expect(await patient.value == server.local)
    }

    // MARK: - Оснастка

    private static func options() -> SIPRequest {
        var request = SIPRequest(
            method: .options,
            uri: SIPURI(user: nil, host: "127.0.0.1")
        )
        var via = SIPVia(transport: .udp, host: "192.168.1.50", port: 5060)
        via.branch = SIPToken.branch()
        request.headers.append(SIPHeaderName.via, via.description)
        request.headers.append(SIPHeaderName.callID, SIPToken.callID())
        request.headers.append(SIPHeaderName.cseq, "1 OPTIONS")
        return request
    }
}

/// Кэш ответов на входящие запросы.
///
/// Он существует ради ретрансмиссий (RFC 3261 §17.2.2) и по природе своей
/// растёт от чужих запросов, а не от нашей работы. Раньше срок каждой записи
/// держала отдельная задача со сном на сорок секунд — по задаче на ответ, — и
/// ни словарь, ни число задач ограничить было нечем.
@Suite("Кэш ответов")
struct ResponseCacheTests {

    private func request(branch: String) -> SIPRequest {
        var request = SIPRequest(method: .options, uri: SIPURI(user: nil, host: "127.0.0.1"))
        var via = SIPVia(transport: .udp, host: "192.168.1.2", port: 5060)
        via.branch = branch
        request.headers.append(SIPHeaderName.via, via.description)
        request.headers.append(SIPHeaderName.callID, SIPToken.callID())
        request.headers.append(SIPHeaderName.cseq, "1 OPTIONS")
        return request
    }

    @Test("Поток чужих запросов не растит кэш без предела")
    func cacheStaysBounded() async throws {
        let server = ScriptedSIPServer { _, _ in nil }
        let layer = SIPTransactionLayer(channel: server)
        await layer.start()

        // Вчетверо больше потолка. Так выглядит не разговор, а поток мусора на
        // открытый порт — и переживать его надо без роста памяти.
        for index in 0..<(SIPTransactionLayer.maximumCachedResponses * 4) {
            let incoming = request(branch: "z9hG4bK-flood-\(index)")
            try await layer.respond(to: incoming, with: SIPResponse(statusCode: 200))
        }

        let count = await layer.cachedResponseCount
        #expect(count <= SIPTransactionLayer.maximumCachedResponses)
    }

    @Test("Просроченный ответ уходит сам, без задачи на каждую запись")
    func expiredResponsesArePruned() async throws {
        let server = ScriptedSIPServer { _, _ in nil }
        // Срок жизни записи — восемь T4. Укорачиваем, чтобы не ждать сорок
        // секунд: проверяется правило, а не боевое число.
        var timers = SIPTransactionLayer.Timers()
        timers.t4 = .milliseconds(10)
        let layer = SIPTransactionLayer(channel: server, timers: timers)
        await layer.start()

        try await layer.respond(to: request(branch: "z9hG4bK-old"), with: SIPResponse(statusCode: 200))
        #expect(await layer.cachedResponseCount == 1)

        try await Task.sleep(.milliseconds(200))

        // Следующая запись убирает просроченное — уборка едет на ней, а не на
        // своей задаче.
        try await layer.respond(to: request(branch: "z9hG4bK-new"), with: SIPResponse(statusCode: 200))
        #expect(await layer.cachedResponseCount == 1, "старая запись обязана была уйти")
    }
}
