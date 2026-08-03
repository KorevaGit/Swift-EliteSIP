import Foundation

/// Журнал в файле: запись, ротация и уборка старого.
///
/// Пишет с отдельной очереди. Журнал наполняется из главного потока — там живёт
/// модель приложения, — и класть на него запись в файл нельзя: очередь событий
/// SIP на активном звонке идёт десятками строк в секунду, а `write` на полном
/// диске или на сетевом томе блокируется на неопределённое время.
///
/// Ротация по размеру и уборка по сроку и по числу файлов — не аккуратность, а
/// условие работоспособности: рабочее место живёт годами, и журнал без потолка
/// однажды займёт диск целиком. Ошибки записи глушатся намеренно: софтфон,
/// упавший из-за собственного журнала, — худший из возможных исходов
/// диагностики.
public final class LogFile: @unchecked Sendable {

    public struct Settings: Sendable, Equatable {

        /// Каталог журнала. Файлы внутри создаются и удаляются сами.
        public var directory: URL

        /// Потолок текущего файла. По достижении файл откладывается в архив, а
        /// запись продолжается в новый.
        public var maximumFileBytes: Int

        /// Сколько отложенных файлов держим, не считая текущего.
        public var keptFiles: Int

        /// Сколько дней храним отложенные файлы.
        public var maximumAgeInDays: Int

        public init(
            directory: URL,
            maximumFileBytes: Int = 4 * 1024 * 1024,
            keptFiles: Int = 5,
            maximumAgeInDays: Int = 14
        ) {
            self.directory = directory
            self.maximumFileBytes = maximumFileBytes
            self.keptFiles = keptFiles
            self.maximumAgeInDays = maximumAgeInDays
        }
    }

    public static let currentFileName = "elitesip.log"
    private static let rotatedPrefix = "elitesip-"
    private static let fileExtension = "log"

    private let settings: Settings
    private let queue = DispatchQueue(label: "com.elite.EliteSIP.log", qos: .utility)

    /// Открытый файл и его размер. Трогаются только на `queue`.
    ///
    /// Дескриптор POSIX, а не `FileHandle`, по одной причине: `FileHandle.write`
    /// и `seekToEndOfFile` на ошибке возбуждают `NSException`, которую Swift не
    /// ловит. Полный диск или отвалившийся сетевой том означали бы падение
    /// софтфона из-за собственного журнала — ровно тот исход, который здесь
    /// объявлен худшим. `write(2)` в этом случае возвращает −1, и его можно
    /// проглотить.
    ///
    /// Второе следствие: файл открыт с `O_APPEND`, то есть каждая запись
    /// садится в конец файла атомарно. Это важно в один короткий момент —
    /// когда настройки журнала сменились, новый `LogFile` уже открыл файл, а у
    /// старого ещё осталась запись в очереди: со своими смещениями два
    /// экземпляра затирали бы строки друг друга.
    private var descriptor: Int32 = -1
    private var writtenBytes = 0

    public init(settings: Settings) {
        self.settings = settings
        queue.async { [weak self] in
            self?.open()
            self?.prune()
        }
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    public var currentFileURL: URL {
        settings.directory.appendingPathComponent(Self.currentFileName)
    }

    /// Все файлы журнала, новые первыми. Текущий всегда первый.
    public func files() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: settings.directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []

        let rotated = contents
            .filter { $0.lastPathComponent.hasPrefix(Self.rotatedPrefix) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        let current = currentFileURL
        return (FileManager.default.fileExists(atPath: current.path) ? [current] : []) + rotated
    }

    /// Пишет одну строку. Возврат немедленный: файл трогается на своей очереди.
    public func write(_ message: String, level: String, date: Date = Date()) {
        // Маскирование делается здесь, а не на очереди, ровно по одной причине:
        // так его нельзя обойти, добавив второй путь записи.
        let line = Self.line(date: date, level: level, message: LogRedaction.redact(message))
        queue.async { [weak self] in
            self?.append(line)
        }
    }

    /// Дожидается, пока всё записанное окажется в файле.
    ///
    /// Нужен ровно двум вызывающим: сборке архива для поддержки и проверкам.
    /// В обычной работе ждать журнал незачем.
    public func flush() {
        queue.sync {
            if descriptor >= 0 { fsync(descriptor) }
        }
    }

    /// Стирает журнал целиком, включая отложенные файлы.
    public func removeAll() {
        queue.sync {
            closeDescriptor()
            writtenBytes = 0
            for url in files() {
                try? FileManager.default.removeItem(at: url)
            }
            open()
        }
    }

    // MARK: - Внутреннее, всё на очереди

    private func open() {
        let manager = FileManager.default
        try? manager.createDirectory(at: settings.directory, withIntermediateDirectories: true)

        let url = currentFileURL
        // `O_APPEND` — см. описание `descriptor`. Права 0644: журнал читает тот,
        // кто его прислал, а не весь компьютер.
        descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        // Дописываем, а не начинаем сначала: перезапуск приложения не повод
        // терять то, ради чего журнал и заводился.
        writtenBytes = descriptor >= 0 ? Int(lseek(descriptor, 0, SEEK_END)) : 0
    }

    private func closeDescriptor() {
        if descriptor >= 0 { close(descriptor) }
        descriptor = -1
    }

    private func append(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if descriptor < 0 { open() }
        guard descriptor >= 0 else { return }

        // Ошибка записи проглатывается намеренно и полным диском не считается
        // поводом упасть. Короткая запись дописывается: `write(2)` вправе
        // записать меньше запрошенного, и остаток в этом случае — не мусор, а
        // хвост строки.
        var written = 0
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while written < buffer.count {
                let count = Darwin.write(descriptor, base + written, buffer.count - written)
                guard count > 0 else { return }
                written += count
            }
        }
        writtenBytes += written

        if writtenBytes >= settings.maximumFileBytes {
            rotate()
        }
    }

    private func rotate() {
        closeDescriptor()

        let stamp = Self.stampFormatter.string(from: Date())
        let destination = settings.directory.appendingPathComponent(
            "\(Self.rotatedPrefix)\(stamp).\(Self.fileExtension)"
        )
        // Совпадение имени возможно только при двух ротациях в одну секунду —
        // то есть при потолке в несколько байт. Такой файл проще перезаписать,
        // чем городить счётчик.
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.moveItem(at: currentFileURL, to: destination)

        open()
        prune()
    }

    /// Убирает лишние файлы: сначала по сроку, потом по числу.
    private func prune() {
        let manager = FileManager.default
        var rotated = files().filter { $0.lastPathComponent != Self.currentFileName }

        if settings.maximumAgeInDays > 0 {
            let deadline = Date().addingTimeInterval(-Double(settings.maximumAgeInDays) * 86_400)
            rotated = rotated.filter { url in
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                guard let modified, modified < deadline else { return true }
                try? manager.removeItem(at: url)
                return false
            }
        }

        guard rotated.count > settings.keptFiles else { return }
        for url in rotated.dropFirst(max(settings.keptFiles, 0)) {
            try? manager.removeItem(at: url)
        }
    }

    // MARK: - Формат

    /// Одна запись — одна строка.
    ///
    /// Перевод строки внутри сообщения заменяется значком: журнал разбирают
    /// `grep` и глаза, и запись, размазанная по трём строкам, ломает обоих.
    static func line(date: Date, level: String, message: String) -> String {
        let flattened = message
            .replacingOccurrences(of: "\r\n", with: " ⏎ ")
            .replacingOccurrences(of: "\n", with: " ⏎ ")
            .replacingOccurrences(of: "\r", with: " ⏎ ")
        return "\(timeFormatter.string(from: date)) [\(level)] \(flattened)"
    }

    /// Локальное время с миллисекундами: журнал сверяют с рассказом оператора
    /// («около двух часов»), а не с UTC.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()
}
