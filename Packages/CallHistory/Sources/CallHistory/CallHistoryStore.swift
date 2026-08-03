import Foundation

/// Локальная история звонков: запись по событию, выборка и уборка по сроку.
///
/// **Пишется по ходу звонка, а не в конце.** Строка заводится на первом гудке
/// и дописывается ответом, переводом и завершением. Приложение может упасть
/// посреди разговора, и запись «в конце» теряла бы ровно те звонки, после
/// которых оно упало, — то есть те, ради которых историю и открывают.
///
/// **База отдельно от журнала и от настроек.** Журнал — это то, что человек по
/// инструкции отправляет в поддержку, и номера лидов в нём уже есть по
/// отдельному решению. История же живёт своим сроком и своей политикой
/// удаления, и в архив для поддержки не попадает вовсе.
///
/// Работа с диском — на своей последовательной очереди, как у файлового
/// журнала. Запись асинхронна: `INSERT` на полном диске или на сетевом томе
/// блокируется на неопределённое время, а происходит он в момент, когда
/// оператор нажал «Позвонить». Чтение синхронно — его ждёт список, и ждать там
/// нечего: выборка идёт по индексу и с потолком в двести строк.
public final class CallHistoryStore: @unchecked Sendable {

    public struct Settings: Sendable, Equatable {

        /// Файл базы. Каталог создаётся сам.
        public var fileURL: URL

        /// Сколько дней держим записи.
        ///
        /// Это решение про персональные данные, а не про диск: в записях лежат
        /// номера лидов. Поэтому срок задаёт администратор, а не сборка.
        public var maximumAgeInDays: Int

        public init(fileURL: URL, maximumAgeInDays: Int = 30) {
            self.fileURL = fileURL
            self.maximumAgeInDays = maximumAgeInDays
        }
    }

    /// Что показывать в списке.
    public enum Filter: String, Sendable, Hashable, CaseIterable {
        case all
        case incoming
        case outgoing
        case missed

        public var title: String {
            switch self {
            case .all: return "Все"
            case .incoming: return "Входящие"
            case .outgoing: return "Исходящие"
            case .missed: return "Пропущенные"
            }
        }

        /// Условие для `WHERE`. Без параметров: подставляются только константы
        /// самого перечисления, снаружи сюда ничего не попадает.
        fileprivate var condition: String? {
            switch self {
            case .all: return nil
            case .incoming: return "direction = 0"
            case .outgoing: return "direction = 1"
            case .missed: return "direction = 0 AND answered_at IS NULL"
            }
        }
    }

    /// Чем закончилось открытие базы. Нужно приложению, чтобы написать об этом
    /// в журнал: молча работающая история, которая ничего не помнит, — худший
    /// исход из возможных.
    public enum OpenOutcome: Sendable, Equatable {

        /// База открыта, всё в порядке.
        case ready

        /// База была испорчена и отставлена в сторону под этим именем; работа
        /// продолжается с чистой.
        case replacedDamaged(URL)

        /// Базу открыть не удалось вовсе. История в этом запуске не пишется.
        case unavailable(String)
    }

    /// Строка приложения, которой закрываются записи, оставшиеся открытыми.
    ///
    /// Отдельной константой, потому что она попадает в глаза оператору и её
    /// нельзя менять по частям в двух местах.
    public static let interruptedReason = "приложение завершилось"

    private static let recordColumns = """
        id, call_id, server_call_id, direction, role, number, sip_login, display_name, \
        profile_id, profile_label, started_at, answered_at, ended_at, end_reason, \
        was_transferred, was_conference
        """

    private let settings: Settings
    private let queue = DispatchQueue(label: "com.elite.EliteSIP.history", qos: .utility)

    /// Трогается только на `queue`. nil — база недоступна, и тогда весь
    /// остальной код превращается в набор пустых действий: софтфон, упавший
    /// из-за собственной истории, — исход хуже, чем софтфон без истории.
    private var database: SQLiteDatabase?

    private var outcome: OpenOutcome = .unavailable("база ещё не открывалась")

    public init(settings: Settings) {
        self.settings = settings
        // Синхронно, а не в фоне: приложение сразу после создания спрашивает
        // исход, чтобы написать о нём в журнал, а незакрытые записи прошлого
        // запуска обязаны закрыться до того, как заведётся первая новая.
        queue.sync { open() }
    }

    /// Чем закончилось открытие.
    public var openOutcome: OpenOutcome {
        queue.sync { outcome }
    }

    public var fileURL: URL { settings.fileURL }

    // MARK: - Открытие

    private func open() {
        do {
            try FileManager.default.createDirectory(
                at: settings.fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            var database = try SQLiteDatabase(url: settings.fileURL)

            // Порча файла не гипотетическая: рабочее место выключают из
            // розетки, а базу кладут в домашний каталог, который на части
            // машин синхронизируется в облако. Работать с битой базой хуже,
            // чем начать заново: выборка из неё возвращает случайные строки, и
            // по ним потом разбирают жалобу.
            if !database.isIntact() {
                let damaged = try quarantine()
                database = try SQLiteDatabase(url: settings.fileURL)
                try prepare(database)
                self.database = database
                outcome = .replacedDamaged(damaged)
                return
            }

            try prepare(database)
            self.database = database
            outcome = .ready
        } catch {
            database = nil
            outcome = .unavailable("\(error)")
        }
    }

    private func prepare(_ database: SQLiteDatabase) throws {
        // FULL, а не NORMAL: событий здесь единицы на звонок, экономить нечего,
        // а обещание «история переживает падение» не должно зависеть от того,
        // успела ли система сбросить кэш.
        try database.execute("PRAGMA journal_mode = WAL;")
        try database.execute("PRAGMA synchronous = FULL;")

        try database.execute("""
            CREATE TABLE IF NOT EXISTS calls (
                id TEXT PRIMARY KEY NOT NULL,
                call_id TEXT NOT NULL,
                server_call_id TEXT,
                direction INTEGER NOT NULL,
                role INTEGER NOT NULL,
                number TEXT NOT NULL,
                sip_login TEXT,
                display_name TEXT,
                profile_id TEXT,
                profile_label TEXT,
                started_at REAL NOT NULL,
                answered_at REAL,
                ended_at REAL,
                end_reason TEXT,
                was_transferred INTEGER NOT NULL DEFAULT 0,
                was_conference INTEGER NOT NULL DEFAULT 0
            );
            """)

        // Индекс по времени — то, ради чего выбран SQLite. Список открывается
        // выборкой «последние двести по убыванию времени», и без индекса она
        // на десяти тысячах записей означает сортировку всей таблицы при
        // каждом открытии окна.
        try database.execute("CREATE INDEX IF NOT EXISTS calls_started_at ON calls(started_at DESC);")
        // Направление стоит первым: фильтр «пропущенные» отбирает по нему, а
        // порядок внутри отбора всё равно по времени.
        try database.execute(
            "CREATE INDEX IF NOT EXISTS calls_direction_started_at ON calls(direction, started_at DESC);"
        )
        // Переопределение имени из EliteDash (M9) ищет по номеру.
        try database.execute("CREATE INDEX IF NOT EXISTS calls_number ON calls(number);")

        try closeInterrupted(database)
        try deleteExpired(database, now: Date())
    }

    /// Отставляет испорченную базу в сторону и возвращает её новое имя.
    ///
    /// Именно отставляет, а не удаляет. Файл с номерами лидов — это то, что
    /// нельзя стирать походя, и это же единственный шанс достать из него
    /// что-нибудь руками, если жалоба важнее аккуратности.
    private func quarantine() throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let damaged = settings.fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(settings.fileURL.deletingPathExtension().lastPathComponent)-повреждена-\(stamp).sqlite")

        try? FileManager.default.removeItem(at: damaged)
        try FileManager.default.moveItem(at: settings.fileURL, to: damaged)
        // Спутники WAL относятся к отставленной базе и с новой несовместимы.
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: settings.fileURL.path + suffix)
            )
        }
        return damaged
    }

    /// Закрывает записи, оставшиеся открытыми с прошлого запуска.
    ///
    /// Открытая запись означает ровно одно: приложение завершилось посреди
    /// звонка. Оставить её открытой навсегда нельзя — она выглядела бы как
    /// вечно идущий разговор, — а придумывать ей время окончания нечестно.
    /// Поэтому концом становится время начала, а причиной — прямая строка о
    /// том, что произошло.
    private func closeInterrupted(_ database: SQLiteDatabase) throws {
        try database.run(
            "UPDATE calls SET ended_at = started_at, end_reason = ? WHERE ended_at IS NULL;",
            [.text(Self.interruptedReason)]
        )
    }

    // MARK: - Запись

    /// Заводит запись о начавшемся звонке.
    public func begin(_ record: CallRecord) {
        queue.async { [weak self] in
            guard let self, let database else { return }
            try? database.run(
                """
                INSERT OR REPLACE INTO calls (\(Self.recordColumns))
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                [
                    .text(record.id.uuidString),
                    .text(record.callID),
                    .text(record.serverCallID),
                    .integer(Int64(record.direction.rawValue)),
                    .integer(Int64(record.role.rawValue)),
                    .text(record.number),
                    .text(record.sipLogin),
                    .text(record.displayName),
                    .text(record.profileID?.uuidString),
                    .text(record.profileLabel),
                    .date(record.startedAt),
                    .date(record.answeredAt),
                    .date(record.endedAt),
                    .text(record.endReason),
                    .flag(record.wasTransferred),
                    .flag(record.wasConference),
                ]
            )
        }
    }

    /// Отмечает ответ. Повторный вызов ничего не меняет: время ответа — первое,
    /// а не последнее, и повторное согласование медиа не должно его сдвигать.
    public func markAnswered(_ id: UUID, at date: Date = Date()) {
        update("UPDATE calls SET answered_at = ? WHERE id = ? AND answered_at IS NULL;", [
            .date(date), .text(id.uuidString),
        ])
    }

    /// Отмечает, что по звонку был перевод.
    public func markTransferred(_ id: UUID) {
        update("UPDATE calls SET was_transferred = 1 WHERE id = ?;", [.text(id.uuidString)])
    }

    /// Отмечает, что звонок стал конференцией.
    public func markConference(_ id: UUID) {
        update("UPDATE calls SET was_conference = 1 WHERE id = ?;", [.text(id.uuidString)])
    }

    /// Закрывает запись.
    ///
    /// Условие `ended_at IS NULL` защищает от второго закрытия: причину звонку
    /// назначает первое событие, которое его завершило, а не последнее. Иначе
    /// «переведён на 601» затиралось бы обычным «завершён», приезжающим следом
    /// по той же линии.
    public func finish(_ id: UUID, at date: Date = Date(), reason: String) {
        update("UPDATE calls SET ended_at = ?, end_reason = ? WHERE id = ? AND ended_at IS NULL;", [
            .date(date), .text(reason), .text(id.uuidString),
        ])
    }

    /// Привязывает идентификатор звонка со стороны сервера. Задел под M9.
    public func attachServerCallID(_ serverCallID: String, to id: UUID) {
        update("UPDATE calls SET server_call_id = ? WHERE id = ?;", [
            .text(serverCallID), .text(id.uuidString),
        ])
    }

    /// Переопределяет отображаемое имя для всех записей с этим номером.
    ///
    /// Задел под синхронизацию с EliteDash (M9). Трогает только `display_name`:
    /// номер и SIP-логин остаются такими, какими пришли, — иначе пересчитать
    /// имя заново после смены списка у EliteDash будет не из чего.
    public func overrideDisplayName(_ displayName: String?, forNumber number: String) {
        update("UPDATE calls SET display_name = ? WHERE number = ?;", [
            .text(displayName), .text(number),
        ])
    }

    private func update(_ sql: String, _ parameters: [SQLiteDatabase.Value]) {
        queue.async { [weak self] in
            try? self?.database?.run(sql, parameters)
        }
    }

    /// Дожидается, пока всё записанное окажется в базе.
    ///
    /// Нужен проверкам и списку, который открывают сразу после звонка.
    public func flush() {
        queue.sync {}
    }

    // MARK: - Чтение

    /// Записи, новые первыми.
    public func records(
        matching filter: Filter = .all,
        limit: Int = 200,
        offset: Int = 0
    ) -> [CallRecord] {
        queue.sync {
            guard let database else { return [] }
            let condition = filter.condition.map { "WHERE \($0)" } ?? ""
            let rows = try? database.query(
                """
                SELECT \(Self.recordColumns) FROM calls \(condition)
                ORDER BY started_at DESC LIMIT ? OFFSET ?;
                """,
                [.integer(Int64(limit)), .integer(Int64(offset))],
                read: Self.record(from:)
            )
            return rows ?? []
        }
    }

    public func count(matching filter: Filter = .all) -> Int {
        queue.sync {
            guard let database else { return 0 }
            let condition = filter.condition.map { "WHERE \($0)" } ?? ""
            return Int((try? database.integer("SELECT count(*) FROM calls \(condition);")) ?? 0)
        }
    }

    private static func record(from row: SQLiteDatabase.Row) -> CallRecord {
        CallRecord(
            id: row.uuid(0) ?? UUID(),
            callID: row.text(1) ?? "",
            serverCallID: row.text(2),
            direction: CallRecord.Direction(rawValue: Int(row.integer(3))) ?? .incoming,
            role: CallRecord.Role(rawValue: Int(row.integer(4))) ?? .primary,
            number: row.text(5) ?? "",
            sipLogin: row.text(6),
            displayName: row.text(7),
            profileID: row.uuid(8),
            profileLabel: row.text(9),
            startedAt: row.date(10) ?? Date(timeIntervalSince1970: 0),
            answeredAt: row.date(11),
            endedAt: row.date(12),
            endReason: row.text(13),
            wasTransferred: row.flag(14),
            wasConference: row.flag(15)
        )
    }

    // MARK: - Срок хранения

    /// Удаляет записи старше срока. Возвращает, сколько удалила.
    ///
    /// Синхронно, потому что вызывающему нужен ответ для журнала: удаление
    /// персональных данных — это то, о чём в журнале должна остаться строка.
    @discardableResult
    public func prune(now: Date = Date()) -> Int {
        queue.sync {
            guard let database else { return 0 }
            return (try? deleteExpired(database, now: now)) ?? 0
        }
    }

    @discardableResult
    private func deleteExpired(_ database: SQLiteDatabase, now: Date) throws -> Int {
        // Ноль и меньше означало бы «удалять всё, что старше сейчас», то есть
        // историю длиной в один звонок. Значение приезжает из файла настроек,
        // который правит человек, поэтому границы ставятся здесь, а не только
        // в интерфейсе.
        let days = min(max(settings.maximumAgeInDays, 1), 3650)
        let horizon = now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
        try database.run("DELETE FROM calls WHERE started_at < ?;", [.date(horizon)])
        return database.changes
    }
}
