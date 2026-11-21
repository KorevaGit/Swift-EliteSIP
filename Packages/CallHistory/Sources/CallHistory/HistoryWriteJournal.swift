import Foundation

/// Одна операция записи истории в виде, переживающем перезапуск.
///
/// SQL и параметры, а не «что случилось со звонком»: воспроизводится ровно то,
/// что не удалось выполнить, тем же запросом и с теми же условиями. Условия в
/// запросах (`answered_at IS NULL`, `ended_at IS NULL`) делают повтор
/// безопасным: вторая попытка того же действия ничего не портит.
struct HistoryOperation: Codable, Equatable, Sendable {

    enum Parameter: Codable, Equatable, Sendable {
        case null
        case text(String)
        case integer(Int64)
        case real(Double)
    }

    /// Имя действия для журнала: «begin», «finish». Номеров и параметров в
    /// сообщениях об ошибке нет — только оно и код SQLite.
    let kind: String
    let sql: String
    let parameters: [Parameter]

    init(kind: String, sql: String, parameters: [SQLiteDatabase.Value]) {
        self.kind = kind
        self.sql = sql
        self.parameters = parameters.map {
            switch $0 {
            case .null: .null
            case .text(let value): .text(value)
            case .integer(let value): .integer(value)
            case .real(let value): .real(value)
            }
        }
    }

    var values: [SQLiteDatabase.Value] {
        parameters.map {
            switch $0 {
            case .null: .null
            case .text(let value): .text(value)
            case .integer(let value): .integer(value)
            case .real(let value): .real(value)
            }
        }
    }

    /// Тот же `INSERT`, но не затирающий уже записанное.
    ///
    /// Для аварийной копии начала звонка: к моменту её воспроизведения запись
    /// могла давно доехать до базы обычным путём и обрасти ответом и концом, и
    /// `OR REPLACE` вернул бы её в «идёт разговор».
    var preservingExisting: HistoryOperation {
        var copy = self
        copy.sqlOverride = sql.replacingOccurrences(of: "INSERT OR REPLACE", with: "INSERT OR IGNORE")
        return copy
    }

    private var sqlOverride: String?
    var effectiveSQL: String { sqlOverride ?? sql }

    private enum CodingKeys: String, CodingKey { case kind, sql, parameters, sqlOverride }
}

/// Файл операций, построчно в JSON, с подтверждением диском.
///
/// Рядом с базой и с теми же правами 0600: внутри номера лидов. Каждая запись
/// сбрасывается на диск до возврата — журнал, который теряет последнюю строку
/// при выключении из розетки, ровно эту строку и должен был сберечь.
final class HistoryWriteJournal: @unchecked Sendable {

    let url: URL
    private let lock = NSLock()

    init(url: URL) {
        self.url = url
    }

    func append(_ operation: HistoryOperation) throws {
        try append([operation])
    }

    func append(_ operations: [HistoryOperation]) throws {
        guard !operations.isEmpty else { return }
        var data = Data()
        let encoder = JSONEncoder()
        for operation in operations {
            data.append(try encoder.encode(operation))
            data.append(0x0A)
        }
        try lock.withLock {
            let manager = FileManager.default
            if !manager.fileExists(atPath: url.path) {
                guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
                else { throw CocoaError(.fileWriteUnknown) }
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        }
    }

    /// Всё, что лежит в файле. Нечитаемая строка — обрыв записи при
    /// выключении — пропускается, остальные читаются.
    func readAll() -> [HistoryOperation] {
        lock.withLock {
            guard let data = try? Data(contentsOf: url) else { return [] }
            let decoder = JSONDecoder()
            return data.split(separator: 0x0A).compactMap {
                try? decoder.decode(HistoryOperation.self, from: Data($0))
            }
        }
    }

    var isEmpty: Bool {
        lock.withLock {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            return size == 0
        }
    }

    /// Заменяет содержимое оставшимися операциями; пусто — файл удаляется.
    func replace(with remaining: [HistoryOperation]) throws {
        if remaining.isEmpty {
            lock.withLock { try? FileManager.default.removeItem(at: url) }
            return
        }
        let encoder = JSONEncoder()
        var data = Data()
        for operation in remaining {
            data.append(try encoder.encode(operation))
            data.append(0x0A)
        }
        try lock.withLock {
            let temporary = url.appendingPathExtension("tmp")
            try data.write(to: temporary, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        }
    }
}
