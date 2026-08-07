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
        outcome_code, was_transferred, was_conference
        """

    /// Что показывает окно, кроме направления.
    ///
    /// Отдельным типом, а не двумя параметрами у каждого метода: условие выборки
    /// собирается в одном месте, и добавить третью грань (скажем, роль) можно,
    /// не переписывая четыре сигнатуры. Внутрь строки SQL отсюда не попадает
    /// ничего — и профиль, и границы дня уходят параметрами.
    public struct Scope: Sendable, Equatable {

        /// Профиль, чью историю показываем.
        ///
        /// **Не опциональный по смыслу, а опциональный технически.** Граница
        /// жёсткая: окно всегда показывает ровно один профиль, и nil здесь
        /// означает «профиля нет вовсе» — тогда не показывается ничего. Это не
        /// то же самое, что «все профили»: такого режима у истории нет.
        public var profileID: UUID?

        /// Начало выбранного дня. nil — все дни.
        public var day: Date?

        public init(profileID: UUID?, day: Date? = nil) {
            self.profileID = profileID
            self.day = day
        }
    }

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
                outcome_code INTEGER,
                was_transferred INTEGER NOT NULL DEFAULT 0,
                was_conference INTEGER NOT NULL DEFAULT 0
            );
            """)

        try migrate(database)

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
        // Профиль первым: с 6 августа 2026 история жёстко ограничена активным
        // профилем, то есть **каждая** выборка отбирает по нему, а порядок
        // внутри отбора всё равно по времени. Без этого индекса приёмка «десять
        // тысяч записей не замедляют открытие окна» перестала бы выполняться:
        // отбор по профилю пришёлся бы на индекс по времени и означал бы чтение
        // всей таблицы.
        try database.execute(
            "CREATE INDEX IF NOT EXISTS calls_profile_started_at ON calls(profile_id, started_at DESC);"
        )

        try closeInterrupted(database)
        try deleteExpired(database, now: Date())
    }

    /// Догоняет схему до текущей.
    ///
    /// Отдельным шагом, а не «пересоздать таблицу»: в ней лежат номера лидов за
    /// месяц, и терять их при обновлении приложения нельзя. `CREATE TABLE IF
    /// NOT EXISTS` выше на существующей базе не делает ничего — новую колонку
    /// добавляет только `ALTER TABLE`.
    ///
    /// Наличие колонки проверяется, а не глотается ошибка: `ALTER TABLE` на уже
    /// добавленной колонке — это ошибка, неотличимая от настоящей поломки, и
    /// молча пропускать её значило бы не заметить, что схема не сошлась.
    private func migrate(_ database: SQLiteDatabase) throws {
        let columns = try database.query("PRAGMA table_info(calls);") { $0.text(1) ?? "" }
        if !columns.contains("outcome_code") {
            try database.execute("ALTER TABLE calls ADD COLUMN outcome_code INTEGER;")
        }
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
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
                    Self.code(record.outcomeCode),
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
    /// по той же линии. Код исхода идёт тем же запросом и под тем же условием:
    /// слово и причина обязаны быть из одного события, иначе строка скажет
    /// «занято» под причиной «переведён».
    public func finish(
        _ id: UUID,
        at date: Date = Date(),
        reason: String,
        outcome: CallRecord.Outcome? = nil
    ) {
        update(
            """
            UPDATE calls SET ended_at = ?, end_reason = ?, outcome_code = ?
            WHERE id = ? AND ended_at IS NULL;
            """,
            [.date(date), .text(reason), Self.code(outcome), .text(id.uuidString)]
        )
    }

    private static func code(_ outcome: CallRecord.Outcome?) -> SQLiteDatabase.Value {
        outcome.map { .integer(Int64($0.rawValue)) } ?? .null
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

    /// Условие и параметры под фильтр и область.
    ///
    /// Единственное место, где собирается `WHERE`. Внутрь строки попадают
    /// только константы самого перечисления; профиль и границы дня уходят
    /// параметрами — их значения приходят снаружи.
    private static func selection(
        _ filter: Filter,
        _ scope: Scope
    ) -> (clause: String, parameters: [SQLiteDatabase.Value]) {
        var conditions: [String] = []
        var parameters: [SQLiteDatabase.Value] = []

        if let condition = filter.condition {
            conditions.append(condition)
        }

        // Профиль отбирается всегда, даже когда его нет: nil означает «профиля
        // нет», и показывать в этом случае надо ничего, а не всё. Записи с
        // пустым `profile_id` не видны никогда — граница строгая, и «ничей»
        // звонок не имеет права всплыть в чужой истории.
        conditions.append("profile_id = ?")
        parameters.append(.text(scope.profileID?.uuidString))

        if let day = scope.day {
            // Границы считает вызывающий своим календарём и своим часовым
            // поясом: SQLite про местное время знает только через модификатор
            // 'localtime', а он берёт пояс системы в момент запроса — то есть
            // после перелёта дал бы другой ответ на тот же вопрос.
            conditions.append("started_at >= ? AND started_at < ?")
            parameters.append(.date(day))
            parameters.append(.date(day.addingTimeInterval(24 * 60 * 60)))
        }

        return ("WHERE " + conditions.joined(separator: " AND "), parameters)
    }

    /// Записи, новые первыми.
    ///
    /// `offset` — не украшение: окно догружает следующие двести, когда оператор
    /// долистал до низа. Без этого всё, что старше первой страницы, было
    /// недостижимо ни одним действием.
    public func records(
        matching filter: Filter = .all,
        scope: Scope,
        limit: Int = 200,
        offset: Int = 0
    ) -> [CallRecord] {
        queue.sync {
            guard let database else { return [] }
            let selection = Self.selection(filter, scope)
            let rows = try? database.query(
                """
                SELECT \(Self.recordColumns) FROM calls \(selection.clause)
                ORDER BY started_at DESC LIMIT ? OFFSET ?;
                """,
                selection.parameters + [.integer(Int64(limit)), .integer(Int64(offset))],
                read: Self.record(from:)
            )
            return rows ?? []
        }
    }

    /// Сколько записей лежит на машине всего — по всем профилям.
    ///
    /// Единственное место, которое смотрит поверх границы профилей, и оно
    /// административное: в «Управлении» этим числом отвечают на вопрос
    /// «сколько персональных данных здесь накоплено», а он про машину, а не
    /// про того, кто сейчас за ней сидит. Записи при этом не показываются —
    /// только считаются.
    public func totalCount() -> Int {
        queue.sync {
            guard let database else { return 0 }
            return Int((try? database.integer("SELECT count(*) FROM calls;")) ?? 0)
        }
    }

    /// Номера, с которых на эту машину приходили вызовы, — под подсказки
    /// словаря очередей.
    ///
    /// Второе и последнее место, смотрящее поверх границы профилей, и по той же
    /// причине: словарь очередей общий для машины, а не для того, кто сейчас
    /// за ней сидит. Записи не показываются — только номер, дата последнего
    /// вызова и сколько их было.
    ///
    /// **`maximumDigits` — не украшение, а граница между очередью и лидом.**
    /// Номер очереди на FreePBX короткий, номер лида — полный телефонный.
    /// Без отсечки подсказка превратилась бы в список номеров клиентов,
    /// вывешенный в окне настроек, — ровно те персональные данные, которые
    /// этап 4 не выпускал даже в архив для поддержки. Вписать длинный номер
    /// руками по-прежнему можно: отсечка ограничивает подсказку, а не словарь.
    public func incomingNumbers(maximumDigits: Int, limit: Int = 20) -> [NumberSighting] {
        queue.sync { () -> [NumberSighting] in
            guard let database else { return [] }
            let rows = try? database.query(
                """
                SELECT number, max(started_at), count(*) FROM calls
                WHERE direction = 0 AND number <> ''
                GROUP BY number ORDER BY max(started_at) DESC LIMIT ?;
                """,
                [.integer(Int64(max(1, limit) * 4))],
                read: { row in
                    NumberSighting(
                        number: row.text(0) ?? "",
                        lastCall: row.date(1) ?? Date.distantPast,
                        count: Int(row.integer(2))
                    )
                }
            )
            // Отсечка по длине — уже здесь, а не в SQL: SQLite умеет считать
            // цифры только выражением на весь столбец, и оно не пользуется
            // индексом. Выборка и без того ограничена лимитом.
            return (rows ?? [])
                .filter { $0.digitCount <= maximumDigits }
                .prefix(max(1, limit))
                .map { $0 }
        }
    }

    public func count(matching filter: Filter = .all, scope: Scope) -> Int {
        queue.sync {
            guard let database else { return 0 }
            let selection = Self.selection(filter, scope)
            let value = try? database.integer(
                "SELECT count(*) FROM calls \(selection.clause);",
                selection.parameters
            )
            return Int(value ?? 0)
        }
    }

    /// Дни, в которые у профиля были звонки, — под точки в календаре.
    ///
    /// Возвращает начала местных суток. Группировка идёт в SQLite модификатором
    /// `'localtime'`, а не вычитанием часов: смещение пояса не постоянно —
    /// внутри срока хранения может лежать переход на летнее время, и звонок в
    /// ночь перевода иначе попал бы в соседний день.
    ///
    /// Фильтр направления сюда не передаётся намеренно. Точка отвечает на
    /// «работал ли я в этот день», а не «были ли в этот день пропущенные»:
    /// иначе календарь пустел бы при переключении фильтра, и день, который
    /// оператор точно помнит, оказывался бы неотмеченным.
    public func daysWithCalls(scope: Scope, now: Date = Date()) -> Set<Date> {
        queue.sync {
            guard let database else { return [] }
            let days = min(max(settings.maximumAgeInDays, 1), 3650)
            let horizon = now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
            let texts = try? database.query(
                """
                SELECT DISTINCT date(started_at, 'unixepoch', 'localtime') FROM calls
                WHERE profile_id = ? AND started_at >= ?;
                """,
                [.text(scope.profileID?.uuidString), .date(horizon)]
            ) { $0.text(0) }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return Set((texts ?? []).compactMap { $0.flatMap(formatter.date(from:)) })
        }
    }

    /// Удаляет историю профиля целиком. Возвращает, сколько удалила.
    ///
    /// Синхронно и с ответом, потому что вызывающему он нужен дважды: спросить
    /// человека до удаления («будут удалены 137 записей») и написать число в
    /// журнал после. Отменить это нельзя — поэтому спрашивают заранее, а не
    /// предлагают возврат потом.
    @discardableResult
    public func deleteHistory(ofProfile profileID: UUID) -> Int {
        queue.sync {
            guard let database else { return 0 }
            try? database.run(
                "DELETE FROM calls WHERE profile_id = ?;",
                [.text(profileID.uuidString)]
            )
            return database.changes
        }
    }

    /// Стирает историю целиком и возвращает, сколько записей было.
    ///
    /// Появилось в этапе 5 и отменяет прежнее «удаления руками нет ни у кого».
    /// Довод оставался верным для уборки по политике и переставал работать
    /// там, где машину передают другому сотруднику или выводят из
    /// эксплуатации.
    ///
    /// **Целиком, а не выборочно.** Выборочное удаление и есть заметание
    /// следов — стереть один неудобный звонок; отсутствие всей истории заметно
    /// само по себе. Число возвращается затем, чтобы вызывающий записал его в
    /// журнал: стереть можно, бесследно — нет.
    @discardableResult
    public func deleteAll() -> Int {
        queue.sync {
            guard let database else { return 0 }
            let before = Int((try? database.integer("SELECT count(*) FROM calls;")) ?? 0)
            try? database.execute("DELETE FROM calls;")
            // Место возвращается системе сразу: иначе файл базы остаётся
            // прежнего размера, и «стёр историю» выглядит как «ничего не
            // произошло» для того, кто смотрит на диск.
            try? database.execute("VACUUM;")
            return before
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
            // Ноль здесь — это и «пусто», и «такого кода нет»: значения
            // перечисления начинаются с единицы именно затем, чтобы одно
            // прочтение отвечало на оба вопроса.
            outcomeCode: CallRecord.Outcome(rawValue: Int(row.integer(14))),
            wasTransferred: row.flag(15),
            wasConference: row.flag(16)
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
