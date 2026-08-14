import Foundation

// не переводится: отказ архиватора — журнал.

/// Архив для поддержки: журнал плюс сведения о машине, одним файлом.
///
/// Существует затем, чтобы инструкция оператору состояла из одного шага.
/// «Найдите папку журналов, выделите нужные файлы, заархивируйте и пришлите» —
/// это четыре шага, на каждом из которых теряется половина обращений, а
/// присылают в итоге снимок экрана с одной строкой.
public enum SupportArchive {

    public enum ArchiveError: Error, CustomStringConvertible {
        case archiverFailed(status: Int32)

        public var description: String {
            switch self {
            case .archiverFailed(let status): "архиватор вернул \(status)"
            }
        }
    }

    /// Собирает архив из файлов журнала и текстовой справки.
    ///
    /// Справка идёт вместе с журналом, потому что первый вопрос поддержки — это
    /// всегда «какая версия и какая система», и без неё разбор начинается с
    /// переписки, а не с журнала.
    ///
    /// - Parameters:
    ///   - logs: файлы журнала, обычно `LogFile.files()`.
    ///   - summary: содержимое `summary.txt`. Секреты сюда класть нельзя —
    ///     маскирование журнала на эту строку не распространяется.
    ///   - destination: куда положить готовый `.zip`.
    @discardableResult
    public static func make(
        logs: [URL],
        summary: String,
        destination: URL
    ) throws -> URL {
        let manager = FileManager.default
        let staging = manager.temporaryDirectory
            .appendingPathComponent("EliteSIP-support-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }

        try Data(summary.utf8).write(to: staging.appendingPathComponent("summary.txt"))
        for url in logs {
            let copy = staging.appendingPathComponent(url.lastPathComponent)
            try? manager.copyItem(at: url, to: copy)
        }

        try? manager.removeItem(at: destination)

        // `ditto` вместо своей упаковки: он есть в системе с незапамятных
        // времён, умеет zip и не тянет зависимостей в проект, который до сих
        // пор обходится без единой.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", staging.path, destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ArchiveError.archiverFailed(status: process.terminationStatus)
        }
        return destination
    }

    /// Имя архива с отметкой времени: два обращения подряд не должны
    /// перезаписывать друг друга.
    public static func suggestedName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "EliteSIP-logs-\(formatter.string(from: now)).zip"
    }
}
