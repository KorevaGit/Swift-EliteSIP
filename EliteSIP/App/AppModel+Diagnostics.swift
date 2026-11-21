import CallHistory
import Diagnostics
import Foundation

// не переводится: всё в этом файле — технические сведения для поддержки.

/// Что, кроме журнала, едет в архив поддержки, и наблюдения за самим
/// приложением: сводки звука в разговоре и задержки главного потока.
///
/// Перенесено из Windows-клиента 1.0.2 (разбор инцидента 724): по одному
/// журналу нельзя было ни связать провал звука с жалобой, ни увидеть, что
/// интерфейс стоял, ни понять, что запись истории не легла.
extension AppModel {

    // MARK: - Архив

    /// Дополнительные файлы архива. Собираются на очереди архива: `ps` и
    /// чтение отчётов об авариях ждать на главном потоке незачем.
    nonisolated static func supportExtras(
        logFile: LogFile?,
        logFlushed: Bool,
        historyStatus: CallHistoryStore.WriteStatus?,
        historyFile: URL?
    ) -> [String: Data] {
        var extras: [String: Data] = [:]
        extras["log-status.txt"] = Data(describe(logFile: logFile, flushed: logFlushed).utf8)
        extras["history-status.txt"] = Data(describe(history: historyStatus, file: historyFile).utf8)
        if let processes = processList() { extras["processes.txt"] = processes }
        for (name, data) in recentCrashReports() { extras["crash-\(name)"] = data }
        return extras
    }

    private nonisolated static func describe(logFile: LogFile?, flushed: Bool) -> String {
        guard let logFile else { return "файл журнала выключен\n" }
        let status = logFile.status
        return [
            "последние строки подтверждены диском: \(flushed ? "да" : "НЕТ — сброс не уложился в 5 с")",
            "пропущено строк при переполнении очереди: \(status.droppedLines)",
            "ошибок записи: \(status.writeFailures)",
            "последняя ошибка: \(status.lastWriteError ?? "—")",
        ].joined(separator: "\n") + "\n"
    }

    private nonisolated static func describe(history: CallHistoryStore.WriteStatus?, file: URL?) -> String {
        guard let history else { return "история выключена или не открылась\n" }
        return [
            "база: \(file?.lastPathComponent ?? "—")",
            "ошибок записи: \(history.failureCount)",
            "последняя ошибка: \(history.lastFailure ?? "—")",
            "ждут воспроизведения: \(history.pendingCount)",
            "аварийных копий начала звонка: \(history.emergencyCount)",
            "не подтверждено ни одним путём: \(history.unconfirmedCount)",
        ].joined(separator: "\n") + "\n"
    }

    /// Список процессов: что ещё держало звук, сеть и процессор в момент жалобы.
    private nonisolated static func processList() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid,ppid,%cpu,%mem,etime,comm"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data.isEmpty ? nil : data
    }

    /// Отчёты системы об авариях EliteSIP за 30 суток — не больше десяти
    /// новейших и не больше двух мегабайт каждый.
    private nonisolated static func recentCrashReports() -> [(String, Data)] {
        let manager = FileManager.default
        let directories = [
            manager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports"),
            URL(fileURLWithPath: "/Library/Logs/DiagnosticReports"),
        ]
        let deadline = Date().addingTimeInterval(-30 * 86_400)
        var found: [(url: URL, date: Date)] = []
        for directory in directories {
            let files = (try? manager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
            )) ?? []
            for url in files where url.lastPathComponent.hasPrefix("EliteSIP") {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard let date = values?.contentModificationDate, date >= deadline,
                      (values?.fileSize ?? 0) <= 2 * 1024 * 1024
                else { continue }
                found.append((url, date))
            }
        }
        return found.sorted { $0.date > $1.date }.prefix(10).compactMap { item in
            (try? Data(contentsOf: item.url)).map { (item.url.lastPathComponent, $0) }
        }
    }

    // MARK: - Наблюдение

    /// Сводка звука каждые 30 секунд разговора, начиная с первой.
    ///
    /// Сводка в конце звонка не помогает разобрать жалобу «посреди разговора
    /// пропал звук»: к концу счётчики уже ничего не говорят о минуте провала.
    func startMediaSummaries() {
        guard mediaSummaryTask == nil else { return }
        mediaSummaryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(.seconds(30))
                guard !Task.isCancelled, let self else { return }
                let active = lines.filter { $0.media != nil }
                if active.isEmpty {
                    mediaSummaryTask = nil
                    return
                }
                for line in active {
                    guard let media = line.media else { continue }
                    let microphone = line.isMicrophoneMissing ? ", без микрофона" : ""
                    append(level: .info, message: "медиа \(line.id.prefix(8)): \(media.summary)\(microphone)")
                }
            }
        }
    }

    /// Следит, не стоит ли главный поток.
    ///
    /// Раз в секунду с фонового потока ставится пустая задача на главный и
    /// меряется, когда она выполнилась. Дольше полсекунды — строка в журнал:
    /// «кнопка не нажималась» иначе не отличить от «нажатие не дошло».
    func startMainThreadWatch() {
        guard mainThreadWatch == nil else { return }
        mainThreadWatch = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(.seconds(1))
                let started = Date()
                await MainActor.run {}
                let lag = Date().timeIntervalSince(started)
                guard lag >= 0.5 else { continue }
                await self?.append(
                    level: .warning,
                    message: "интерфейс не отвечал \(Int(lag * 1000)) мс"
                )
            }
        }
    }
}
