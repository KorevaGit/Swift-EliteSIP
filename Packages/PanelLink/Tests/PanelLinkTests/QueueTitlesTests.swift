import Testing
@testable import PanelLink

/// Подпись раздачи по имени из `From`. Те же примеры проверяют Spark
/// (`frontend/test/queue-titles.test.js`) и Linux-версия: правило одно.
@Suite("Подписи раздач")
struct QueueTitlesTests {

    static let rules = QueueTitles.rules([
        .init(match: "GORACHAYA", title: "🔥Горячая раздача🔥"),
        .init(match: "call center", title: "Колл-центр"),
        .init(match: " ", title: "пустое правило не срабатывает"),
        .init(match: "line3", title: ""),
    ])

    @Test("имя причёсывается, но не переводится", arguments: [
        ("GORACHAYA RAZDACHACall Center", "GORACHAYA RAZDACHA Call Center"),
        ("line3dep", "Line 3 dep"),
        ("Call_Center", "Call Center"),
        ("MTS TestIT_Peleshko", "MTS Test IT Peleshko"),
        ("AutoDialer", "Auto Dialer"),
        ("  Semenov_Artyom ", "Semenov Artyom"),
        ("ЛинияМТС2", "Линия МТС 2"),
        ("", ""),
    ])
    func tidy(name: String, shown: String) {
        #expect(QueueTitles.tidy(name) == shown)
    }

    @Test("ключ не зависит от регистра, пробелов и подчёркиваний")
    func key() {
        #expect(QueueTitles.key("GORACHAYA RAZDACHA") == "gorachayarazdacha")
        #expect(QueueTitles.key(" Call_Center ") == "callcenter")
        #expect(QueueTitles.key(nil) == "")
    }

    @Test("первое подходящее правило, иначе причёсанное имя", arguments: [
        ("GORACHAYA RAZDACHACall Center", "🔥Горячая раздача🔥"),
        ("Call_Center", "Колл-центр"),
        ("line3dep", "Line 3 dep"),
    ])
    func headline(name: String, title: String) {
        #expect(QueueTitles.headline(name, rules: Self.rules) == title)
    }

    @Test("имя без букв именем не считается",
          arguments: [nil, "", "  ", "79615362688", "+7 (961) 536-26-88"] as [String?])
    func noLetters(name: String?) {
        #expect(QueueTitles.headline(name, rules: Self.rules) == nil)
    }

    @Test("пустые правила отброшены")
    func rulesDropEmpty() {
        #expect(Self.rules.count == 2)
    }
}
