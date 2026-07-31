import Compat
import Foundation
import Testing
@testable import SIPCore

@Suite("Удержание привязки NAT", .timeLimit(.minutes(1)))
struct KeepAliveTests {

    private func makeAgent(
        server: ScriptedSIPServer,
        keepAliveInterval: Interval = .milliseconds(30)
    ) -> SIPUserAgent {
        SIPUserAgent(
            account: testAccount(transport: server.transport),
            credentials: testCredentials,
            channel: server,
            timers: fastTimers(),
            keepAliveInterval: keepAliveInterval
        )
    }

    @Test("Между обновлениями регистрации уходят пакеты удержания")
    func sendsKeepAlivePackets() async throws {
        // Срок регистрации намеренно длинный: именно в этой паузе NAT и
        // закрывает привязку, и проверять надо, что клиент в ней не молчит.
        let server = ScriptedSIPServer { request, index in
            index == 0
                ? ScriptedSIPServer.unauthorized(to: request)
                : ScriptedSIPServer.registrationAccepted(to: request, expires: 3600)
        }

        let agent = makeAgent(server: server)
        await agent.start()

        #expect(await waitUntil { await agent.registrationState.isRegistered })
        #expect(await waitUntil { server.keepAliveCount >= 3 })

        await agent.stop()

        // Регистрация за это время не обновлялась: 3600 секунд ещё не прошли.
        // Значит пакеты — не побочный эффект перерегистрации.
        #expect(server.receivedRequests.filter { $0.method == .register }.count <= 3)
    }

    @Test("Пакет удержания — ровно CRLFCRLF и ничего больше")
    func keepAliveIsEmptyPacket() {
        #expect(SIPTransactionLayer.keepAlivePing == Data([0x0D, 0x0A, 0x0D, 0x0A]))
    }

    @Test("Привязка удерживается и когда регистрация не удалась")
    func keepsAliveWhileRegistrationFails() async throws {
        // Сервер молчит на всё. Регистрация уходит в повтор с нарастающей
        // задержкой, и без отдельного цикла клиент замолчал бы на минуты — то
        // есть ровно тогда, когда открытая дорога нужнее всего: по ней должен
        // прийти ответ на следующую попытку.
        let server = ScriptedSIPServer { _, _ in nil }

        let agent = makeAgent(server: server)
        await agent.start()

        #expect(await waitUntil { server.keepAliveCount >= 3 })
        #expect(await agent.registrationState.isRegistered == false)

        await agent.stop()
    }

    @Test("После остановки агента пакеты прекращаются")
    func stopsAfterAgentStops() async throws {
        let server = ScriptedSIPServer { request, index in
            index == 0
                ? ScriptedSIPServer.unauthorized(to: request)
                : ScriptedSIPServer.registrationAccepted(to: request, expires: 3600)
        }

        let agent = makeAgent(server: server)
        await agent.start()
        #expect(await waitUntil { server.keepAliveCount >= 2 })
        await agent.stop()

        let afterStop = server.keepAliveCount
        // Несколько интервалов подряд: остановка обязана снимать задачу, а не
        // просто пропускать один тик.
        try await Task.sleep(.milliseconds(150))
        #expect(server.keepAliveCount == afterStop)
    }

    @Test("Интервал по умолчанию зависит от транспорта")
    func defaultIntervalDependsOnTransport() {
        // UDP — под самый короткий распространённый таймаут NAT в 30 секунд.
        #expect(SIPUserAgent.defaultKeepAliveInterval(for: .udp) == .seconds(25))
        // Потоковым транспортам столь частый пакет не нужен: там привязка живёт
        // кратно дольше, и RFC 5626 §4.4.1 называет как раз этот порядок.
        #expect(SIPUserAgent.defaultKeepAliveInterval(for: .tcp) == .seconds(120))
        #expect(SIPUserAgent.defaultKeepAliveInterval(for: .tls) == .seconds(120))
    }

    @Test("Разброс держится в пределах ±10 % и не вырождается в ноль")
    func jitterStaysWithinBounds() {
        let base = Interval.seconds(25)
        for _ in 0..<200 {
            let value = SIPUserAgent.jittered(base)
            #expect(value >= .seconds(22.5))
            #expect(value <= .seconds(27.5))
        }
    }

    @Test("Нулевой интервал разброс не ломает")
    func jitterHandlesZero() {
        // `Int64.random(in: 0...0)` законен, а вот пустой диапазон — ловушка:
        // на интервале меньше 10 нс spread обнуляется, и без явной проверки
        // получился бы crash в randomness вместо тика таймера.
        #expect(SIPUserAgent.jittered(.zero) == .zero)
        #expect(SIPUserAgent.jittered(.nanoseconds(5)) == .nanoseconds(5))
    }
}
