import Foundation
import SQLite3

/// Тонкая обёртка над системным SQLite.
///
/// Ровно столько, сколько нужно истории: открыть, выполнить, подготовить
/// запрос, связать параметры, прочитать колонки. Ни ORM, ни миграций общего
/// вида — обе вещи здесь были бы кодом, который никто не читает и который
/// нечем проверить.
///
/// Отдельным типом, а не вперемешку с логикой истории, по одной причине:
/// работа с C API — это место, где легко забыть `sqlite3_finalize` или связать
/// строку без `SQLITE_TRANSIENT` и получить чтение освобождённой памяти раз в
/// неделю на чужой машине. Собранное в одном файле, это проверяется глазами
/// один раз.
final class SQLiteDatabase {

    /// Причина, по которой база не открылась или запрос не выполнился.
    ///
    /// Несёт текст от SQLite: «database disk image is malformed» и «attempt to
    /// write a readonly database» — разные беды с разным лечением, и сводить
    /// их к одному «не удалось» значит лишить разбор единственной зацепки.
    struct Failure: Error, CustomStringConvertible {
        let code: Int32
        let message: String
        var description: String { "SQLite \(code): \(message)" }
    }

    /// SQLite требует, чтобы связанные строки либо жили до `sqlite3_step`,
    /// либо копировались. Swift такой гарантии про свои `String` не даёт —
    /// временный буфер `withCString` умирает на выходе из вызова, — поэтому
    /// копируем всегда.
    private static let transient = unsafeBitCast(
        -1,
        to: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self
    )

    private var handle: OpaquePointer?

    init(url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard code == SQLITE_OK, let handle else {
            // не переводится: сообщение SQLite и так английское, а рядом с
            // ним стоит наше — оба читаются в журнале.
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "не удалось открыть файл"
            sqlite3_close_v2(handle)
            throw Failure(code: code, message: message)
        }
        self.handle = handle
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    private var lastError: Failure {
        Failure(
            code: sqlite3_errcode(handle),
            message: String(cString: sqlite3_errmsg(handle))
        )
    }

    /// Выполняет запрос без результата: DDL, PRAGMA, транзакции.
    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw lastError }
    }

    /// Значения, которые умеет связывать этот слой. Всё, что нужно истории:
    /// текст, число, время и пустота.
    enum Value {
        case null
        case text(String)
        case integer(Int64)
        case real(Double)

        static func text(_ value: String?) -> Value {
            value.map { .text($0) } ?? .null
        }

        static func date(_ value: Date?) -> Value {
            value.map { .real($0.timeIntervalSince1970) } ?? .null
        }

        static func flag(_ value: Bool) -> Value {
            .integer(value ? 1 : 0)
        }
    }

    /// Подготовленный запрос. Живёт только внутри `query`/`run`: держать его
    /// между вызовами незачем — история пишется единицами строк на звонок, и
    /// экономить здесь подготовку не на чем.
    struct Row {

        fileprivate let statement: OpaquePointer

        func text(_ index: Int32) -> String? {
            guard sqlite3_column_type(statement, index) != SQLITE_NULL,
                let bytes = sqlite3_column_text(statement, index)
            else { return nil }
            return String(cString: bytes)
        }

        func integer(_ index: Int32) -> Int64 {
            sqlite3_column_int64(statement, index)
        }

        func flag(_ index: Int32) -> Bool {
            sqlite3_column_int64(statement, index) != 0
        }

        func date(_ index: Int32) -> Date? {
            guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
            return Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
        }

        func uuid(_ index: Int32) -> UUID? {
            text(index).flatMap(UUID.init(uuidString:))
        }
    }

    /// Выполняет запрос и разбирает строки. Возврат — то, что собрал `read`.
    @discardableResult
    func query<T>(_ sql: String, _ parameters: [Value] = [], read: (Row) -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let error = lastError
            sqlite3_finalize(statement)
            throw error
        }
        defer { sqlite3_finalize(statement) }

        for (offset, parameter) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch parameter {
            case .null: code = sqlite3_bind_null(statement, index)
            case .text(let value): code = sqlite3_bind_text(statement, index, value, -1, Self.transient)
            case .integer(let value): code = sqlite3_bind_int64(statement, index, value)
            case .real(let value): code = sqlite3_bind_double(statement, index, value)
            }
            guard code == SQLITE_OK else { throw lastError }
        }

        var rows: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: rows.append(read(Row(statement: statement)))
            case SQLITE_DONE: return rows
            default: throw lastError
            }
        }
    }

    /// Выполняет запрос, у которого нет результата.
    func run(_ sql: String, _ parameters: [Value] = []) throws {
        try query(sql, parameters) { _ in () }
    }

    /// Целое из запроса вида `SELECT count(*)`. Ноль, если строк нет.
    func integer(_ sql: String, _ parameters: [Value] = []) throws -> Int64 {
        try query(sql, parameters) { $0.integer(0) }.first ?? 0
    }

    /// Сколько строк тронул последний `INSERT`/`UPDATE`/`DELETE`.
    var changes: Int { Int(sqlite3_changes(handle)) }

    /// Проверка целостности файла. Возвращает `true`, только если SQLite
    /// ответил ровно `ok`.
    ///
    /// `quick_check`, а не полный `integrity_check`: полный на большой базе
    /// читает её целиком, а проверка стоит на пути запуска приложения. Быструю
    /// проверку проходит всё, что можно читать без риска, и этого достаточно —
    /// цель здесь не аудит файла, а «не работать молча с битой базой».
    func isIntact() -> Bool {
        let answer = try? query("PRAGMA quick_check(1)") { $0.text(0) }
        return answer?.first.flatMap { $0 } == "ok"
    }
}
