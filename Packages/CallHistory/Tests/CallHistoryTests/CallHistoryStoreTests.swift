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

    /// Профиль, которому принадлежат записи почти всех проверок.
    ///
    /// Один на набор, потому что с 6 августа 2026 выборка **всегда** отбирает
    /// по профилю: история жёстко ограничена активным. Свой у каждого набора —
    /// `@Suite` создаёт экземпляр под каждую проверку, и пересечься они не
    /// могут даже теоретически.
    private let profile = UUID()

    private var scope: CallHistoryStore.Scope { CallHistoryStore.Scope(profileID: profile) }

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
            profileID: profile,
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
        #expect(store.records(scope: scope).first?.endedAt == nil)

        let answered = call.startedAt.addingTimeInterval(4)
        store.markAnswered(call.id, at: answered)
        store.finish(call.id, at: answered.addingTimeInterval(90), reason: "Завершён")
        store.flush()

        let stored = store.records(scope: scope).first
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

        #expect(store.records(scope: scope).first?.endReason == "Переведён на 601")
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

        #expect(store.records(scope: scope).first?.answeredAt == first)
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

        let stored = store.records(scope: scope).first
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
        let stored = reopened.records(scope: scope).first
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
        let numbers = store.records(scope: scope).map(\.number)
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
            #expect(store.records(scope: scope).count == 1)
        }

        let reopened = CallHistoryStore(settings: settings)
        #expect(reopened.records(scope: scope).isEmpty, "просроченное не должно дожидаться, пока кто-нибудь нажмёт кнопку")
    }

    @Test("Нулевой срок не означает «удалить всё»")
    func clampsRetention() {
        let settings = makeSettings(days: 0)
        defer { remove(settings) }

        let store = CallHistoryStore(settings: settings)
        store.begin(record(startedAt: Date().addingTimeInterval(-3600)))
        store.flush()
        store.prune()

        #expect(store.records(scope: scope).count == 1, "значение из файла настроек правит человек — границы ставим сами")
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

        #expect(store.records(matching: .all, scope: scope).count == 3)
        #expect(store.records(matching: .incoming, scope: scope).map(\.number) == ["701", "702"])
        #expect(store.records(matching: .outgoing, scope: scope).map(\.number) == ["601"])
        #expect(store.records(matching: .missed, scope: scope).map(\.number) == ["702"])
        #expect(store.count(matching: .missed, scope: scope) == 1)
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

        #expect(store.records(scope: scope).map(\.number) == ["новый", "старый"])
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
        #expect(store.totalCount() == 10_000)

        // Панель открывается одной выборкой первой страницы. Порог намеренно
        // щедрый: цель проверки — поймать чтение всей таблицы, а не измерить
        // машину сборки. Полный проход по десяти тысячам с разбором строк не
        // уложился бы и в секунду.
        let started = Date()
        let page = store.records(matching: .missed, scope: scope, limit: 200)
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

        #expect(store.records(scope: scope, limit: 4).map(\.number) == ["0", "1", "2", "3"])
        #expect(store.records(scope: scope, limit: 4, offset: 4).map(\.number) == ["4", "5", "6", "7"])
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
        #expect(reopened.records(scope: scope).map(\.number) == ["603"])
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

        let stored = store.records(scope: scope).first
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

        #expect(store.records(scope: scope).first?.serverCallID == "1754212800.42")
    }

    // MARK: - Граница профиля

    @Test("Чужой профиль не виден ни в выборке, ни в счёте")
    func scopesToProfile() {
        let settings = makeSettings()
        defer { remove(settings) }

        let store = CallHistoryStore(settings: settings)
        let other = UUID()
        store.begin(record(number: "601"))
        store.begin(CallRecord(
            callID: UUID().uuidString, direction: .outgoing, number: "чужой",
            profileID: other, profileLabel: "Лаба"
        ))
        store.flush()

        #expect(store.records(scope: scope).map(\.number) == ["601"])
        #expect(store.count(scope: scope) == 1)
        // Обе записи на диске есть — граница проходит по выборке, а не по
        // записи: администратор считает всё, что накоплено на машине.
        #expect(store.totalCount() == 2)
    }

    @Test("Запись без профиля не видна никому")
    func hidesRecordsWithoutProfile() {
        let settings = makeSettings()
        defer { remove(settings) }

        let store = CallHistoryStore(settings: settings)
        store.begin(CallRecord(
            callID: UUID().uuidString, direction: .outgoing, number: "ничей", profileID: nil
        ))
        store.flush()

        #expect(store.records(scope: scope).isEmpty)
        #expect(
            store.records(scope: CallHistoryStore.Scope(profileID: nil)).isEmpty,
            "nil в области означает «профиля нет», а не «показать бесхозные»"
        )
        #expect(store.totalCount() == 1, "запись на диске остаётся, невидима только выборке")
    }

    @Test("Удаление профиля уносит его историю и не трогает чужую")
    func deletesHistoryOfProfile() {
        let settings = makeSettings()
        defer { remove(settings) }

        let store = CallHistoryStore(settings: settings)
        let other = UUID()
        store.begin(record(number: "601"))
        store.begin(record(number: "602"))
        store.begin(CallRecord(
            callID: UUID().uuidString, direction: .outgoing, number: "чужой", profileID: other
        ))
        store.flush()

        #expect(store.deleteHistory(ofProfile: profile) == 2)
        #expect(store.records(scope: scope).isEmpty)
        #expect(store.count(scope: CallHistoryStore.Scope(profileID: other)) == 1)
    }

    // MARK: - Отбор по дню

    @Test("Отбор по дню берёт местные сутки целиком и не залезает в соседние")
    func scopesToDay() {
        let settings = makeSettings(days: 3650)
        defer { remove(settings) }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        let store = CallHistoryStore(settings: settings)
        // Первая и последняя минуты суток: границы должны попадать внутрь, а
        // не срезаться — звонок в 00:03 принадлежит своему дню, а не прошлому.
        store.begin(record(number: "начало", startedAt: today.addingTimeInterval(60)))
        store.begin(record(number: "конец", startedAt: today.addingTimeInterval(24 * 3600 - 60)))
        store.begin(record(number: "вчера", startedAt: yesterday.addingTimeInterval(12 * 3600)))
        store.flush()

        let day = CallHistoryStore.Scope(profileID: profile, day: today)
        #expect(Set(store.records(scope: day).map(\.number)) == ["начало", "конец"])
        #expect(store.count(scope: day) == 2)
        #expect(store.count(scope: CallHistoryStore.Scope(profileID: profile, day: yesterday)) == 1)
    }

    @Test("Дни со звонками перечисляются началами местных суток")
    func listsDaysWithCalls() {
        let settings = makeSettings(days: 3650)
        defer { remove(settings) }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let older = calendar.date(byAdding: .day, value: -5, to: today)!

        let store = CallHistoryStore(settings: settings)
        store.begin(record(startedAt: today.addingTimeInterval(9 * 3600)))
        store.begin(record(startedAt: today.addingTimeInterval(18 * 3600)))
        store.begin(record(startedAt: older.addingTimeInterval(11 * 3600)))
        store.flush()

        // Два звонка одного дня дают одну точку, а не две.
        #expect(store.daysWithCalls(scope: scope) == [today, older])
    }

    @Test("Дни чужого профиля в календарь не попадают")
    func listsDaysOfOwnProfileOnly() {
        let settings = makeSettings(days: 3650)
        defer { remove(settings) }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        let store = CallHistoryStore(settings: settings)
        store.begin(CallRecord(
            callID: UUID().uuidString, direction: .outgoing, number: "чужой",
            profileID: UUID(), startedAt: today.addingTimeInterval(9 * 3600)
        ))
        store.flush()

        #expect(store.daysWithCalls(scope: scope).isEmpty)
    }

    @Test("Дни за сроком хранения в календарь не попадают")
    func skipsDaysBeyondRetention() {
        let settings = makeSettings(days: 7)
        defer { remove(settings) }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        // Запись старше срока могла бы дожить до открытия календаря: уборка
        // идёт при открытии базы и раз в сутки, а не в момент запроса.
        let ancient = calendar.date(byAdding: .day, value: -30, to: today)!

        let store = CallHistoryStore(settings: settings)
        store.begin(record(startedAt: ancient.addingTimeInterval(9 * 3600)))
        store.begin(record(startedAt: today.addingTimeInterval(9 * 3600)))
        store.flush()

        #expect(store.daysWithCalls(scope: scope) == [today])
    }

    // MARK: - Исход

    @Test("Код исхода записывается вместе с причиной и переживает перечитывание")
    func storesOutcomeCode() {
        let settings = makeSettings()
        defer { remove(settings) }

        let store = CallHistoryStore(settings: settings)
        let call = record()
        store.begin(call)
        store.finish(call.id, reason: "занято", outcome: .busy)
        store.flush()

        let stored = store.records(scope: scope).first
        #expect(stored?.outcomeCode == .busy)
        #expect(stored?.outcome == .busy)
        #expect(stored?.outcome.title == "занято")
    }

    @Test("Состоявшийся разговор и пропущенный не спрашивают у кода")
    func derivesOutcomeWithoutCode() {
        let settings = makeSettings()
        defer { remove(settings) }

        let store = CallHistoryStore(settings: settings)

        // Разговор состоялся: даже если код по недосмотру сказал бы другое,
        // ответ даёт время ответа — иначе история разошлась бы сама с собой.
        let talked = record(number: "601")
        store.begin(talked)
        store.markAnswered(talked.id)
        store.finish(talked.id, reason: "Завершён", outcome: .failed)

        // Входящий без ответа — пропущенный, и это то же самое условие, по
        // которому отбирает фильтр «Пропущенные».
        let missed = record(direction: .incoming, number: "701")
        store.begin(missed)
        store.finish(missed.id, reason: "отклонён", outcome: .declined)

        // Исходящий без ответа и без кода — «не ответил», а не пустота.
        let old = record(number: "602")
        store.begin(old)
        store.finish(old.id, reason: "Завершён")
        store.flush()

        let stored = Dictionary(
            uniqueKeysWithValues: store.records(scope: scope).map { ($0.number, $0.outcome) }
        )
        #expect(stored["601"] == .completed)
        #expect(stored["701"] == .missed)
        #expect(stored["602"] == .noAnswer)
    }

    @Test("Все шесть слов исхода различны, а у состоявшегося слова нет")
    func outcomeVocabularyIsDistinct() {
        let titles = CallRecord.Outcome.allCases.compactMap(\.title)
        #expect(CallRecord.Outcome.completed.title == nil, "вместо слова у него длительность")
        #expect(titles.count == 6)
        #expect(Set(titles).count == 6, "два исхода с одним словом различать нечем")
    }

    @Test("Коды ответа SIP переводятся в слова")
    func mapsSIPStatusToOutcome() {
        #expect(CallRecord.Outcome.forFailure(status: 486) == .busy)
        #expect(CallRecord.Outcome.forFailure(status: 600) == .busy)
        #expect(CallRecord.Outcome.forFailure(status: 404) == .unknownNumber)
        #expect(CallRecord.Outcome.forFailure(status: 603) == .declined)
        #expect(CallRecord.Outcome.forFailure(status: 403) == .declined)
        #expect(CallRecord.Outcome.forFailure(status: 408) == .noAnswer)
        #expect(CallRecord.Outcome.forFailure(status: 480) == .noAnswer)
        #expect(CallRecord.Outcome.forFailure(status: 487) == .noAnswer)
        #expect(CallRecord.Outcome.forFailure(status: 503) == .failed)
    }

    // MARK: - Миграция

    @Test("База без колонки исхода открывается, а не заводится заново")
    func migratesOldDatabase() throws {
        let settings = makeSettings()
        defer { remove(settings) }

        // Схема до 6 августа 2026: та же таблица без `outcome_code`.
        try FileManager.default.createDirectory(
            at: settings.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let old = try SQLiteDatabase(url: settings.fileURL)
        try old.execute("""
            CREATE TABLE calls (
                id TEXT PRIMARY KEY NOT NULL, call_id TEXT NOT NULL, server_call_id TEXT,
                direction INTEGER NOT NULL, role INTEGER NOT NULL, number TEXT NOT NULL,
                sip_login TEXT, display_name TEXT, profile_id TEXT, profile_label TEXT,
                started_at REAL NOT NULL, answered_at REAL, ended_at REAL, end_reason TEXT,
                was_transferred INTEGER NOT NULL DEFAULT 0,
                was_conference INTEGER NOT NULL DEFAULT 0
            );
            """)
        try old.run(
            """
            INSERT INTO calls (id, call_id, direction, role, number, profile_id, started_at, \
            answered_at, ended_at, end_reason, was_transferred, was_conference)
            VALUES (?, ?, 1, 0, ?, ?, ?, NULL, ?, ?, 0, 0);
            """,
            [
                .text(UUID().uuidString), .text("старый"), .text("601"),
                .text(profile.uuidString), .date(Date()), .date(Date()), .text("занято"),
            ]
        )

        let store = CallHistoryStore(settings: settings)
        #expect(store.openOutcome == .ready, "старая база — не повреждённая, отставлять её нельзя")

        let stored = store.records(scope: scope).first
        #expect(stored?.number == "601", "записи месячной давности обязаны пережить обновление")
        #expect(stored?.outcomeCode == nil)
        #expect(stored?.outcome == .noAnswer, "кода нет — исход выводится, а не теряется")

        // И новая запись в мигрированную базу пишется уже с кодом.
        let fresh = record(number: "602")
        store.begin(fresh)
        store.finish(fresh.id, reason: "нет номера", outcome: .unknownNumber)
        store.flush()
        #expect(
            store.records(scope: scope).first(where: { $0.number == "602" })?.outcomeCode
                == .unknownNumber
        )
    }
}
