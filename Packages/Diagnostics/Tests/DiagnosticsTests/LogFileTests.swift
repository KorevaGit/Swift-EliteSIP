import Foundation
import Testing
@testable import Diagnostics

/// Файл журнала: запись, ротация, уборка.
///
/// Проверяется то, что на разработке не всплывает никогда: рабочее место живёт
/// годами, и журнал без потолка однажды займёт диск целиком, а сломанная
/// дозапись потеряет ровно те строки, ради которых журнал заводили.
@Suite("Файл журнала", .serialized)
struct LogFileTests {

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("elitesip-log-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    @Test("Строка доезжает до файла и остаётся замаскированной")
    func writesRedactedLine() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = LogFile(settings: .init(directory: directory))
        log.write("REGISTER response=\"deadbeef\"", level: "debug")
        log.flush()

        let text = read(log.currentFileURL)
        #expect(text.contains("[debug]"))
        #expect(!text.contains("deadbeef"), "маскирование обязано работать на пути в файл, а не рядом с ним")
        #expect(text.contains("скрыто"))
    }

    @Test("Перезапуск дописывает, а не начинает сначала")
    func appendsAcrossSessions() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = LogFile(settings: .init(directory: directory))
        first.write("первая сессия", level: "info")
        first.flush()

        let second = LogFile(settings: .init(directory: directory))
        second.write("вторая сессия", level: "info")
        second.flush()

        let text = read(second.currentFileURL)
        #expect(text.contains("первая сессия"), "перезапуск не повод терять журнал")
        #expect(text.contains("вторая сессия"))
    }

    /// Смена настроек журнала пересоздаёт `LogFile`, и короткое время два
    /// экземпляра держат один файл: у старого может остаться строка в очереди.
    /// Со своими смещениями они затирали бы записи друг друга — отсюда
    /// `O_APPEND`. Проверяется буквально это: ни одна строка не пропала.
    @Test("Два экземпляра на одном файле не затирают друг друга")
    func concurrentInstancesKeepEveryLine() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let old = LogFile(settings: .init(directory: directory))
        let new = LogFile(settings: .init(directory: directory))
        for index in 0..<50 {
            old.write("старый \(index)", level: "info")
            new.write("новый \(index)", level: "info")
        }
        old.flush()
        new.flush()

        let lines = read(new.currentFileURL).split(separator: "\n")
        #expect(lines.count == 100)
        #expect(lines.filter { $0.contains("старый ") }.count == 50)
        #expect(lines.filter { $0.contains("новый ") }.count == 50)
    }

    @Test("Файл не растёт бесконечно")
    func rotatesBySize() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = LogFile(settings: .init(directory: directory, maximumFileBytes: 2_000, keptFiles: 5))
        for index in 0..<200 {
            log.write(String(repeating: "строка \(index) ", count: 4), level: "info")
        }
        log.flush()

        let current = try #require(try? FileManager.default.attributesOfItem(
            atPath: log.currentFileURL.path
        )[.size] as? Int)
        #expect(current < 2_000 * 2, "текущий файл обязан оставаться в пределах потолка")

        let files = log.files()
        #expect(files.count > 1, "отложенных файлов не появилось — ротации не было")
        #expect(files.first == log.currentFileURL, "текущий файл отдаётся первым")
    }

    @Test("Отложенных файлов не больше, чем разрешено")
    func prunesByCount() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let kept = 2
        let log = LogFile(settings: .init(directory: directory, maximumFileBytes: 500, keptFiles: kept))
        for index in 0..<400 {
            log.write("наполнение \(index) \(String(repeating: "x", count: 40))", level: "info")
        }
        log.flush()

        let rotated = log.files().filter { $0.lastPathComponent != LogFile.currentFileName }
        #expect(rotated.count <= kept, "осталось \(rotated.count) файлов при потолке \(kept)")
    }

    @Test("Старое убирается по сроку")
    func prunesByAge() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Файл, который «пролежал» месяц. Дата правится руками: ждать сутки в
        // тесте нельзя, а срок хранения проверить надо.
        let stale = directory.appendingPathComponent("elitesip-2020-01-01-000000.log")
        try Data("старое".utf8).write(to: stale)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-30 * 86_400)],
            ofItemAtPath: stale.path
        )

        let log = LogFile(settings: .init(directory: directory, maximumAgeInDays: 14))
        log.write("свежая строка", level: "info")
        log.flush()

        #expect(!FileManager.default.fileExists(atPath: stale.path), "файл старше срока обязан исчезнуть")
        #expect(read(log.currentFileURL).contains("свежая строка"))
    }

    @Test("Перевод строки не разрывает запись")
    func multilineMessageStaysOneLine() {
        let line = LogFile.line(
            date: Date(timeIntervalSince1970: 0),
            level: "info",
            message: "первая\r\nвторая\nтретья"
        )
        #expect(!line.contains("\n"))
        #expect(line.contains("первая ⏎ вторая ⏎ третья"))
    }

    @Test("Архив для поддержки собирается и несёт справку")
    func buildsSupportArchive() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = LogFile(settings: .init(directory: directory))
        log.write("строка для архива", level: "info")
        log.flush()

        let destination = directory.appendingPathComponent(SupportArchive.suggestedName())
        try SupportArchive.make(
            logs: log.files(),
            summary: "EliteSIP 0.1.0\nmacOS 26.5",
            destination: destination
        )

        let size = try #require(try? FileManager.default.attributesOfItem(
            atPath: destination.path
        )[.size] as? Int)
        #expect(size > 0)
        #expect(destination.lastPathComponent.hasSuffix(".zip"))
    }

    /// Настройки уезжают внутри архива, а не отдельной кнопкой.
    ///
    /// Кнопок было две, и вторую надо было знать: половина обращений в
    /// поддержку приезжала без настроек. Проверка распаковывает архив тем же
    /// `ditto`, каким он собран, — читать содержимое zip своими силами здесь
    /// незачем.
    @Test("Архив несёт то, что положили рядом с журналом")
    func supportArchiveCarriesExtras() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = LogFile(settings: .init(directory: directory))
        log.write("строка для архива", level: "info")
        log.flush()

        let destination = directory.appendingPathComponent(SupportArchive.suggestedName())
        try SupportArchive.make(
            logs: log.files(),
            summary: "EliteSIP 0.1.0",
            extras: ["settings.json": Data(#"{"здесь":"настройки"}"#.utf8)],
            destination: destination
        )

        let unpacked = directory.appendingPathComponent("unpacked", isDirectory: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", destination.path, unpacked.path]
        try ditto.run()
        ditto.waitUntilExit()
        #expect(ditto.terminationStatus == 0)

        let found = FileManager.default
            .enumerator(at: unpacked, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.lastPathComponent } ?? []
        #expect(found.contains("settings.json"))
        #expect(found.contains("summary.txt"))
    }
}
