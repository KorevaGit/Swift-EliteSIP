import Foundation
import Testing
@testable import CallHistory

/// История звонков: запись по ходу, выборка, срок хранения и порча файла.
///
/// Проверяется здесь то, что на разработке не всплывает никогда. Историю
/// открывают через полгода после установки, на машине, которую пару раз
/// выключили из розетки посреди разговора, — и именно тогда выясняется, что
/// записи не закрылись, база не читается, а открытие панели занимает секунды.
@Suite("История звонков", .serialized)
struct CallHistoryStoreTests {

    private func makeSettings(days: Int = 30) -> CallHistoryStore.Settings {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("elitesip-history-test-\(UUID().uuidString)", isDirectory: true)
        return CallHistoryStore.Settings(
            fileURL: directory.appendingPathComponent("call-history.sqlite"),
            maximumAgeInDays: days
        )
    }

    private func remove(_ settings: CallHistoryStore.Settings) {
        try? FileManager.default.removeItem(at: settings.fileURL.deletingLastPathComponent())
    }

    private func record(
        direction: CallRecord.Direction = .outgoing,
        number: String = "601",
        startedAt: Date = Date()
    ) -> CallRecord {
        CallRecord(
            callID: UUID().uuidString,
            direction: direction,
            number: number,
            sipLogin: "SIP/\(number)",
            profileID: UUID(),
            profileLabel: "Боевой",
            startedAt: startedAt
        )
    }

    // MARK: - Запись по ходу звонка

    @Test("Звонок пишется на первом гудке и дописывается ответом и концом")
    func writesAlongTheCall() {
        let settings = makeSettings()
        defer { remove(settings) }

        let store = CallHistoryStore(settings: settings)
        #expect(store.openOutcome == .ready)

        let call = record()
        store.begin(call)
        store.flush()

        // Открытая запись видна ещё до конца разговора — ради этого запись и
        // заводится в начале.
        #expect(store.records().first?.endedAt == nil)

        let answered = call.startedAt.addingTimeInterval(4)
        store.markAnswered(call.id, at: answered)
        store.finish(call.id, at: answered.addingTimeInterval(90), reason: "Завершён")
        store.flush()

        let stored = store.records().first
        #expect(stored?.id == call.id)
        #expect(stored?.number == "601")
        #expect(stored?.sipLogin == "SIP/601")
        #expect(stored?.profileLabel == "Боевой")
        #expect(stored?.isAnswered == true)
        #expect(stored?.duration == 90, "длительность считается от ответа, а не от гудков")
        #expect(stored?.endReason == "Завершён")
    }

    @Test("Причину завершения назначает первое событие, а не последнее")
    func keepsFirstEndReason() {
        let settings = makeSettings()
        defer { remove(settings) }

        let store = CallHistoryStore(settings: settings)
        let call = record()
        store.begin(call)
        // Успешный перевод завершает нашу ногу сразу, и обычное «Завершён»
        // приезжает следом по той же линии. Затирать им единственное
        // подтверждение оператору нельзя.
        store.finish(call.id, reason: "Переведён на 601")
        store.finish(call.id, reason: "Завершён")
        store.flush()

        #expect(store.records().first?.endReason == "Переведён на 601")
    }

    @Test("Время ответа не сдвигается повторным событием")
    func keepsFirstAnswer() {
        let settings = makeSettings()
        defer { remove(settings) }

        let store = CallHistoryStore(settings: settings)
        let call = record()
        let first = Date(timeIntervalSince1970: 1_000)
        store.begin(call)
        store.markAnswered(call.id, at: first)
        store.markAnswered(call.id, at: first.addingTimeInterval(60))
        store.flush()

        #expect(store.records().first?.answeredAt == first)
    }

    @Test("Перевод и конференция остаются в записи")
    func marksTransferAndConference() {
        let settings = makeSettings()
        defer { remove(settings) }

        let store = CallHistoryStore(settings: settings)
        let call = record()
        store.begin(call)
        store.markTransferred(call.id)
        store.markConference(call.id)
        store.flush()

        let stored = store.records().first
        #expect(stored?.wasTransferred == true)
        #expect(stored?.wasConference == true)
    }

    // MARK: - Приёмка: падение приложения

    @Test("История переживает принудительное завершение приложения")
    func survivesTermination() {
        let settings = makeSettings()
        defer { remove(settings) }

        let call: CallRecord
        do {
            // Ни `flush`, ни закрытия: так выглядит kill -9 посреди разговора.
            let store = CallHistoryStore(settings: settings)
            call = record()
            store.begin(call)
            store.markAnswered(call.id)
            store.flush()
        }

        let reopened = CallHistoryStore(settings: settings)
        let stored = reopened.records().first
        #expect(stored?.id == call.id, "запись обязана пережить завершение приложения")
        #expect(
            stored?.endReason == CallHistoryStore.interruptedReason,
            "открытая запись закрывается при следующем запуске, а не висит вечным разговором"
        )
        #expect(stored?.endedAt == stored?.startedAt, "придумывать время окончания нечестно")
    }

    // MARK: - Приёмка: срок хранения

    @Test("Удаление по сроку работает")
    func deletesExpired() {
        let settings = makeSettings(days: 30)
        defer { remove(settings) }

        let store = CallHistoryStore(settings: settings)
        let now = Date()
        store.begin(record(number: "601", startedAt: now.addingTimeInterval(-29 * 24 * 3600)))
        store.begin(record(number: "602", startedAt: now.addingTimeInterval(-31 * 24 * 3600)))
        store.flush()

        #expect(store.prune(now: now) == 1)
        let numbers = store.records().map(\.number)
        #expect(numbers == ["601"])
    }

    @Test("Срок применяется и при открытии базы, а не только по кнопке")
    func deletesExpiredOnOpen() {
        let settings = makeSettings(days: 1)
        defer { remove(settings) }

        do {
            let store = CallHistoryStore(settings: settings)
            store.begin(record(startedAt: Date().addingTimeInterval(-10 * 24 * 3600)))
            store.flush()
            #expect(store.records().count == 1)
        }

        let reopened = CallHistoryStore(settings: settings)
        #expect(reopened.records().isEmpty, "просроченное не должно дожидаться, пока кто-нибудь нажмёт кнопку")
    }

    @Test("Нулевой срок не означает «удалить всё»")
    func clampsRetention() {
        let settings = makeSettings(days: 0)
        defer { remove(settings) }

        let store = CallHistoryStore(settings: settings)
        store.begin(record(startedAt: Date().addingTimeInterval(-3600)))
        store.flush()
        store.prune()

        #expect(store.records().count == 1, "значение из файла настроек правит человек — границы ставим сами")
    }

    // MARK: - Выборка

    @Test("Фильтр по направлению отбирает то, что обещает")
    func filtersByDirection() {
        let settings = makeSettings()
        defer { remove(settings) }

        let store = CallHistoryStore(settings: settings)
        let now = Date()

        let answeredIncoming = record(direction: .incoming, number: "701", startedAt: now)
        store.begin(answeredIncoming)
        store.markAnswered(answeredIncoming.id)

        store.begin(record(direction: .incoming, number: "702", startedAt: now.addingTimeInterval(-1)))
        store.begin(record(direction: .outgoing, number: "601", startedAt: now.addingTimeInterval(-2)))
        store.flush()

        #expect(store.records(matching: .all).count == 3)
        #expect(store.records(matching: .incoming).map(\.number) == ["701", "702"])
        #expect(store.records(matching: .outgoing).map(\.number) == ["601"])
        #expect(store.records(matching: .missed).map(\.number) == ["702"])
        #expect(store.count(matching: .missed) == 1)
    }

    @Test("Неотвеченный исходящий пропущенным не считается")
    func outgoingIsNeverMissed() {
        let call = record(direction: .outgoing)
        #expect(call.isMissed == false)
        #expect(record(direction: .incoming).isMissed == true)
    }

    @Test("Записи возвращаются новыми первыми")
    func ordersNewestFirst() {
        let settings = makeSettings()
        defer { remove(settings) }

        let store = CallHistoryStore(settings: settings)
        let now = Date()
        store.begin(record(number: "старый", startedAt: now.addingTimeInterval(-600)))
        store.begin(record(number: "новый", startedAt: now))
        store.flush()

        #expect(store.records().map(\.number) == ["новый", "старый"])
    }

    // MARK: - Приёмка: десять тысяч записей

    @Test("Десять тысяч записей не замедляют открытие панели")
    func opensQuicklyAtScale() {
        let settings = makeSettings(days: 3650)
        defer { remove(settings) }

        let store = CallHistoryStore(settings: settings)
        let now = Date()
        for index in 0..<10_000 {
            store.begin(record(
                direction: index.isMultiple(of: 2) ? .incoming : .outgoing,
                number: "\(600 + index % 40)",
                startedAt: now.addingTimeInterval(-Double(index))
            ))
        }
        store.flush()
        #expect(store.count() == 10_000)

        // Панель открывается одной выборкой первой страницы. Порог намеренно
        // щедрый: цель проверки — поймать чтение всей таблицы, а не измерить
        // машину сборки. Полный проход по десяти тысячам с разбором строк не
        // уложился бы и в секунду.
        let started = Date()
        let page = store.records(matching: .missed, limit: 200)
        let elapsed = Date().timeIntervalSince(started)

        #expect(page.count == 200)
        #expect(elapsed < 0.2, "выборка обязана идти по индексу, а не читать таблицу целиком")
    }

    @Test("Страницы не пересекаются и продолжают друг друга")
    func paginates() {
        let settings = makeSettings()
        defer { remove(settings) }

        let store = CallHistoryStore(settings: settings)
        let now = Date()
        for index in 0..<10 {
            store.begin(record(number: "\(index)", startedAt: now.addingTimeInterval(-Double(index))))
        }
        store.flush()

        #expect(store.records(limit: 4).map(\.number) == ["0", "1", "2", "3"])
        #expect(store.records(limit: 4, offset: 4).map(\.number) == ["4", "5", "6", "7"])
    }

    // MARK: - Порча файла

    @Test("Испорченная база отставляется в сторону, а работа продолжается")
    func survivesCorruption() throws {
        let settings = makeSettings()
        defer { remove(settings) }

        do {
            let store = CallHistoryStore(settings: settings)
            store.begin(record())
            store.flush()
        }

        // Затираем заголовок файла — так выглядит порча, которую SQLite
        // замечает сразу и на которой обычный клиент падает при первом запросе.
        let handle = try FileHandle(forWritingTo: settings.fileURL)
        try handle.seek(toOffset: 0)
        handle.write(Data(repeating: 0x41, count: 512))
        try handle.close()

        let reopened = CallHistoryStore(settings: settings)
        guard case .replacedDamaged(let damaged) = reopened.openOutcome else {
            Issue.record("порча базы обязана быть замечена и названа: \(reopened.openOutcome)")
            return
        }
        #expect(
            FileManager.default.fileExists(atPath: damaged.path),
            "файл с номерами лидов не стирают походя — его отставляют в сторону"
        )

        // И самое главное: история продолжает работать.
        let call = record(number: "603")
        reopened.begin(call)
        reopened.flush()
        #expect(reopened.records().map(\.number) == ["603"])
    }

    // MARK: - Задел под EliteDash

    @Test("Псевдоним переопределяется, не затирая номер и логин")
    func overridesDisplayNameWithoutLosingSource() {
        let settings = makeSettings()
        defer { remove(settings) }

        let store = CallHistoryStore(settings: settings)
        store.begin(record(number: "79001234567"))
        store.flush()

        store.overrideDisplayName("Иванов, ООО «Ромашка»", forNumber: "79001234567")
        store.flush()

        let stored = store.records().first
        #expect(stored?.displayName == "Иванов, ООО «Ромашка»")
        #expect(stored?.number == "79001234567", "исходный номер обязан остаться: список имён у EliteDash меняется")
        #expect(stored?.sipLogin == "SIP/79001234567")
        #expect(stored?.title == "Иванов, ООО «Ромашка»")
    }

    @Test("Идентификатор со стороны сервера дописывается в готовую запись")
    func attachesServerCallID() {
        let settings = makeSettings()
        defer { remove(settings) }

        let store = CallHistoryStore(settings: settings)
        let call = record()
        store.begin(call)
        store.attachServerCallID("1754212800.42", to: call.id)
        store.flush()

        #expect(store.records().first?.serverCallID == "1754212800.42")
    }
}
