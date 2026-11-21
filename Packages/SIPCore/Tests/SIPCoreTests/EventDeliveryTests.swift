import Compat
import Foundation
import Testing
@testable import SIPCore

@Suite("Доставка событий", .timeLimit(.minutes(1)))
struct EventDeliveryTests {

    private enum Item: Sendable, Equatable {
        case control(Int)
        case log(Int)
        case dropped(Int)
    }

    private func makeQueue(capacity: Int = 4) -> SIPEventQueue<Item> {
        SIPEventQueue(regularCapacity: capacity) { .dropped($0) }
    }

    private func drain(_ queue: SIPEventQueue<Item>) async -> [Item] {
        queue.finish()
        var items: [Item] = []
        for await item in queue { items.append(item) }
        return items
    }

    @Test("Поток журнала не вытесняет управление")
    func logFloodKeepsControl() async {
        let queue = makeQueue()
        queue.yield(.control(1), lane: .priority)
        for index in 0..<1000 { queue.yield(.log(index), lane: .regular) }
        queue.yield(.control(2), lane: .priority)

        let items = await drain(queue)
        #expect(items.prefix(2) == [.control(1), .control(2)])
        #expect(queue.droppedCount == 996)
        // Принятое раньше переполнения не пропадает: первые четыре строки на месте.
        #expect(items.dropFirst(2) == [.dropped(996), .log(0), .log(1), .log(2), .log(3)])
    }

    @Test("Приоритетное отдаётся раньше, порядок внутри полосы сохраняется")
    func priorityOrder() async {
        let queue = makeQueue(capacity: 16)
        queue.yield(.log(1), lane: .regular)
        queue.yield(.control(1), lane: .priority)
        queue.yield(.log(2), lane: .regular)
        queue.yield(.control(2), lane: .priority)
        #expect(await drain(queue) == [.control(1), .control(2), .log(1), .log(2)])
    }

    @Test("Ожидающий читатель просыпается на новом элементе")
    func wakesWaiter() async {
        let queue = makeQueue()
        let reader = Task { () -> Item? in
            var iterator = queue.makeAsyncIterator()
            return await iterator.next()
        }
        try? await Task.sleep(.milliseconds(20))
        queue.yield(.control(7), lane: .priority)
        #expect(await reader.value == .control(7))
    }

    @Test("Отмена читающей задачи завершает чтение")
    func cancellationEndsReading() async {
        let queue = makeQueue()
        let reader = Task { () -> Int in
            var count = 0
            for await _ in queue { count += 1 }
            return count
        }
        try? await Task.sleep(.milliseconds(20))
        reader.cancel()
        #expect(await reader.value == 0)
        #expect(queue.yield(.control(1), lane: .priority) == .finished)
    }

    @Test("Закрытая очередь дочитывается и не принимает новое")
    func finishDrains() async {
        let queue = makeQueue()
        queue.yield(.control(1), lane: .priority)
        queue.finish()
        #expect(queue.yield(.control(2), lane: .priority) == .finished)
        var items: [Item] = []
        for await item in queue { items.append(item) }
        #expect(items == [.control(1)])
    }

    @Test("Параллельные писатели: ни одно управляющее событие не теряется")
    func concurrentWriters() async {
        let queue = makeQueue(capacity: 8)
        let reader = Task { () -> [Item] in
            var items: [Item] = []
            for await item in queue { items.append(item) }
            return items
        }
        await withTaskGroup(of: Void.self) { group in
            for writer in 0..<8 {
                group.addTask {
                    for index in 0..<200 {
                        queue.yield(.control(writer * 1000 + index), lane: .priority)
                        queue.yield(.log(index), lane: .regular)
                    }
                }
            }
        }
        queue.finish()
        let items = await reader.value
        let controls = items.compactMap { if case .control(let v) = $0 { v } else { nil } }
        #expect(controls.count == 1600)
        for writer in 0..<8 {
            let own = controls.filter { $0 / 1000 == writer }
            #expect(own == own.sorted(), "порядок одного писателя сохраняется")
        }
    }

    @Test("Приоритетная полоса с пределом отклоняет лишнее")
    func priorityCapacity() {
        let queue = SIPEventQueue<Item>(regularCapacity: 1, priorityCapacity: 2)
        #expect(queue.yield(.control(1), lane: .priority) == .enqueued)
        #expect(queue.yield(.control(2), lane: .priority) == .enqueued)
        #expect(queue.yield(.control(3), lane: .priority) == .rejected)
    }

    // MARK: - Слой транзакций

    private func makeRequest(_ method: SIPMethod, index: Int) -> SIPRequest {
        var request = SIPRequest(method: method, uri: SIPURI(user: "100", host: "192.168.1.50"))
        request.headers.append(SIPHeaderName.via, "SIP/2.0/UDP 172.17.0.2:5060;branch=z9hG4bKflood\(index)")
        request.headers.append(SIPHeaderName.from, "<sip:asterisk@172.17.0.2>;tag=as\(index)")
        request.headers.append(SIPHeaderName.to, "<sip:100@192.168.1.50>")
        request.headers.append(SIPHeaderName.callID, "flood-\(index)")
        request.headers.append(SIPHeaderName.cseq, "1 \(method.rawValue)")
        return request
    }

    @Test("Переполненная очередь входящих отвечает 503 новым и сохраняет принятые")
    func inboundOverloadAnswers503() async throws {
        let server = ScriptedSIPServer { _, _ in nil }
        let layer = SIPTransactionLayer(channel: server, timers: fastTimers())
        await layer.start()

        let capacity = SIPTransactionLayer.inboundCapacity
        for index in 0..<(capacity + 5) { server.inject(request: makeRequest(.options, index: index)) }
        server.inject(request: makeRequest(.bye, index: 999))

        #expect(await waitUntil { server.sentResponses.count == 5 })
        let rejected = server.sentResponses
        #expect(rejected.allSatisfy { $0.statusCode == 503 })
        #expect(rejected.allSatisfy { $0.headers[SIPHeaderName.retryAfter] == "5" })
        #expect(rejected.map(\.callID) == (capacity..<(capacity + 5)).map { "flood-\($0)" })
        #expect(await layer.overloadRejections == 5)

        // BYE прошёл приоритетной полосой и стоит первым; принятые OPTIONS целы.
        await layer.stop()
        var received: [SIPRequest] = []
        for await request in layer.inboundRequests { received.append(request) }
        #expect(received.first?.method == .bye)
        #expect(received.dropFirst().map(\.callID) == (0..<capacity).map { "flood-\($0)" })
    }

    @Test("Поток 1xx не вытесняет финальный ответ INVITE")
    func provisionalFloodKeepsFinal() async throws {
        let server = ScriptedSIPServer { _, _ in nil }
        let layer = SIPTransactionLayer(channel: server, timers: fastTimers())
        await layer.start()
        _ = try await layer.waitUntilReady()

        let invite = makeRequest(.invite, index: 1)
        let events = await layer.sendInvite(invite)
        #expect(await waitUntil { !server.receivedRequests.isEmpty })

        for _ in 0..<500 {
            server.inject(response: ScriptedSIPServer.response(to: invite, status: 180))
        }
        server.inject(response: ScriptedSIPServer.response(to: invite, status: 486))

        var provisionals = 0
        var final: SIPInviteEvent?
        for await event in events {
            switch event {
            case .provisional: provisionals += 1
            default: final = event
            }
            if final != nil { break }
        }
        #expect(provisionals == SIPTransactionLayer.maximumDeliveredProvisionals)
        if case .failure(let response) = final { #expect(response.statusCode == 486) } else {
            Issue.record("финальный ответ потерян: \(String(describing: final))")
        }
        await layer.stop()
    }

    @Test("Отмена запроса снимает транзакцию сразу, без таймера F")
    func cancellationEndsTransaction() async throws {
        let server = ScriptedSIPServer { _, _ in nil }
        let layer = SIPTransactionLayer(channel: server)
        await layer.start()
        _ = try await layer.waitUntilReady()

        let request = makeRequest(.register, index: 7)
        let started = MonotonicClock.now
        let task = Task { try await layer.send(request) }
        #expect(await waitUntil { !server.receivedRequests.isEmpty })
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("отменённый запрос вернул ответ")
        } catch {
            #expect(error as? SIPTransactionLayer.TransactionError == .cancelled)
        }
        #expect(MonotonicClock.now - started < .seconds(2))
        let sentBefore = server.receivedRequests.count
        try await Task.sleep(.milliseconds(700))
        #expect(server.receivedRequests.count == sentBefore, "ретрансмиссии после отмены не идут")
        await layer.stop()
    }
}
