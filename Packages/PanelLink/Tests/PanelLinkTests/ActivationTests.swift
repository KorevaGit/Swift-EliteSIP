import Foundation
import Testing
@testable import PanelLink

/// Пакет, собранный **настоящей панелью на Go**, а не подделанный здесь же.
///
/// Это главная проверка пакета целиком. Всё остальное — вывод адреса, вывод
/// соли, число итераций, порядок nonce и метки, заголовок в дополнительных
/// данных — проверяется тем, что этот пакет открывается. Собранный своими
/// руками образец проверял бы только то, что мы согласны сами с собой.
///
/// Перевыпускается `go run ./cmd/fixtures` в `elitesip-site`. Разойдутся
/// стороны — разойдётся здесь, а не на живой машине сотрудника.
enum Fixture {
    static let key = "K7M2-9XQP-4TFB"
    static let objectName = "255a2e7e8e0e6e8260ab4e21f7f179bd"
    static let sealed = Data(base64Encoded: """
        RVNJUEEydM0lPUtwahluFO2Z0Kj47Ubp6+h9a3KdaWBk9KiEkfk/fIwkcx3P4t87puESuB8xoqkNTw26FvrAcchFXZAj3urQUM3eadOMItiUgCcLoh3I8dmA\
        b6zG0mGpeCBAQMZItu6PhWGq7CFkPxeoPIdiRy7Ou0CrSas2lmYhgZyqeuVRU2JT3zJYXdg6aaD0jfTui+IiaQErzfEo7/X49eR5tx/EWnXBnuu5xpxWuPKT\
        JcOTJVAvez4dHSRrvslTlsdTA/M3lmFdyWSpJBUPFNqnkWAqsGEUcu/9VnAcW079Lh3AkSQDuLSeWtoYZsi/IVNUNJZWoyJrSMIOAgCYddsIQldmFn6bxKoE\
        qQdRMIPluG63CM5qM5m481uVze4J8BRsos1qphvWbNrpKnUCTWFvPzO9Ks95bSawGzWjc3acad4eTHrHTrDGux5F4DSlmABJOIDsFflDZlWDi5S7n4WnI/98\
        pXK9RcDn2Q8J/JADWqgjsLa+ph5JstKryvN28gET2DYMNe8SE/ZM6T6f8dZGBr4kEceKGaouj7rW5CDnDkIaVx0x06AK42vme7tssZ02wunPH9JJseBv0a7K\
        j2Es2nJ+sHVQ41SkU/asZimy6SYBSfa+FWM7aaD8+BfEBKSANpi5YGA2hBpReyLuutzP78yIZ91EfDFXuTsSorH95xbGf70r
        """.replacingOccurrences(of: "\n", with: ""))!
}

@Suite("Ключ активации")
struct ActivationKeyTests {

    /// Ключ диктуют по телефону и вставляют из мессенджера вместе с пробелами.
    @Test("разбор терпим к тому, как ключ ввели")
    func tolerantInput() throws {
        let canonical = try ActivationKey(input: "K7M29XQP4TFB").canonical

        // Список нарочно включает CR LF: в Swift это один Character, и первый
        // заход на нём споткнулся — ключ из мессенджера на Windows отвергался.
        for written in ["K7M2-9XQP-4TFB", "k7m2 9xqp 4tfb", " K7M2\n9XQP\t4TFB ",
                        "K7M2-9XQP-4TFB\r\n", "k7m2.9xqp,4tfb",
                        "K7M2\u{00A0}9XQP\u{2014}4TFB", "«K7M2-9XQP-4TFB»"] {
            #expect(try ActivationKey(input: written).canonical == canonical,
                    "не разобрался вариант \(written)")
        }
    }

    /// Этих букв в алфавите нет вовсе, и прочитавший ноль как «о» иначе получал
    /// бы отказ, не понимая почему.
    @Test("O читается нулём, I и L — единицей")
    func confusableLetters() throws {
        #expect(try ActivationKey(input: "O7M29XQP4TFB").canonical == "07M29XQP4TFB")
        #expect(try ActivationKey(input: "I7M29XQP4TFB").canonical == "17M29XQP4TFB")
        #expect(try ActivationKey(input: "L7M29XQP4TFB").canonical == "17M29XQP4TFB")
    }

    @Test("не ключ отвергается по составу и по длине")
    func rejectsNonsense() {
        #expect(throws: PanelLinkError.malformedKey) { try ActivationKey(input: "K7M29XQP4TF") }
        #expect(throws: PanelLinkError.malformedKey) { try ActivationKey(input: "K7M29XQP4TFBX") }
        #expect(throws: PanelLinkError.malformedKey) { try ActivationKey(input: "K7M29XQP4TF!") }
        #expect(throws: PanelLinkError.malformedKey) { try ActivationKey(input: "") }
    }

    /// Адрес считают обе стороны, и совпасть они обязаны до знака: иначе машина
    /// пойдёт за пакетом не туда.
    @Test("адрес пакета совпадает с тем, что посчитала панель")
    func objectNameMatchesPanel() throws {
        let bound = try BoundActivationKey(key: ActivationKey(input: Fixture.key))
        #expect(bound.objectName == Fixture.objectName)
    }

    /// Привязка входит в соль, а значит и в адрес: ключ перепрошивки, введённый
    /// не на той машине, уходит по другому адресу и пакета там не находит —
    /// вместо того чтобы скачать его и сжечь на проверке внутри.
    @Test("привязка к машине меняет адрес")
    func bindingChangesAddress() throws {
        let key = try ActivationKey(input: Fixture.key)

        let free = try BoundActivationKey(key: key)
        let mine = try BoundActivationKey(key: key, installationID: "8f2c0000")
        let yours = try BoundActivationKey(key: key, installationID: "8f2c0001")

        #expect(mine.objectName != free.objectName)
        #expect(mine.objectName != yours.objectName)
        #expect(try BoundActivationKey(key: key, installationID: "8f2c0000").objectName == mine.objectName)
    }

    @Test("показывается группами, как в панели")
    func grouped() throws {
        #expect(try ActivationKey(input: "K7M29XQP4TFB").grouped == "K7M2-9XQP-4TFB")
    }
}

@Suite("Пакет активации")
struct ActivationPackageTests {

    /// Полный круг с настоящей панелью: то, что она положила, здесь достаётся.
    @Test("пакет от панели распечатывается")
    func opensPanelPackage() throws {
        let key = try BoundActivationKey(key: ActivationKey(input: Fixture.key))
        let package = try ActivationPackage.open(sealed: Fixture.sealed, with: key)

        #expect(package.format == 2)
        #expect(package.installationID == "8f2c4a1b9d3e5f60")
        #expect(package.employee == "Пётр Смирнов")
        #expect(package.number == "172")
        #expect(package.sipPassword == "s3cret-172")
        // Административного пароля в пакете нет вовсе: он приезжает
        // помашинным объектом MachineAccess, чтобы у него не было двух
        // источников, расходящихся при первой же смене.
        #expect(package.channelKey.count == 64)
        #expect(package.preset.id == "6D1F5A20-0000-4000-8000-000000000001")
        #expect(package.preset.name == "Менеджер")
        #expect(package.preset.revision == 7)
        #expect(package.preset.schemaVersion == 2)
    }

    /// Управляемые поля доносятся в целости и неразобранными: разбирает их та
    /// же дорога, что и файл предустановок.
    @Test("управляемые поля доезжают как есть")
    func carriesSettingsVerbatim() throws {
        let key = try BoundActivationKey(key: ActivationKey(input: Fixture.key))
        let package = try ActivationPackage.open(sealed: Fixture.sealed, with: key)

        let object = try JSONSerialization.jsonObject(with: package.preset.settings)
        let dtmf = try #require((object as? [String: Any])?["dtmf"] as? [String: Any])
        #expect(dtmf["toneMilliseconds"] as? Int == 120)

        let macros = try #require(dtmf["macros"] as? [[String: Any]])
        #expect(macros.count == 1)
        #expect(macros[0]["title"] as? String == "ЮРИСТ")
        #expect(macros[0]["sequence"] as? String == "*02,101")
        #expect(macros[0]["transfersCall"] as? Bool == true)
    }

    /// Подбирающему незачем знать, ошибся он ключом или наткнулся на битый
    /// файл: ответ обязан быть один и тот же.
    @Test("чужой ключ и испорченный пакет неотличимы по ответу")
    func wrongKeyAndBrokenPackageLookAlike() throws {
        let wrongKey = try BoundActivationKey(key: ActivationKey(input: "K7M29XQP4TFC"))
        #expect(throws: PanelLinkError.keyDidNotOpen) {
            try ActivationPackage.open(sealed: Fixture.sealed, with: wrongKey)
        }

        var broken = Fixture.sealed
        broken[broken.count - 1] ^= 0x01
        let rightKey = try BoundActivationKey(key: ActivationKey(input: Fixture.key))
        #expect(throws: PanelLinkError.keyDidNotOpen) {
            try ActivationPackage.open(sealed: broken, with: rightKey)
        }
    }

    /// Подменённый заголовок обязан ломать проверку: он идёт в дополнительные
    /// данные AES-GCM именно за этим.
    @Test("подмена заголовка ломает распечатывание")
    func headerIsAuthenticated() throws {
        var tampered = Fixture.sealed
        tampered[5] = UInt8(ascii: "2")
        #expect(tampered.prefix(6) == Data("ESIPA2".utf8))

        tampered[4] = UInt8(ascii: "X")
        let key = try BoundActivationKey(key: ActivationKey(input: Fixture.key))
        #expect(throws: PanelLinkError.keyDidNotOpen) {
            try ActivationPackage.open(sealed: tampered, with: key)
        }
    }

    /// Иначе разбор уйдёт не туда: человек будет искать опечатку в ключе,
    /// которого не набирал, вместо того чтобы обновить приложение.
    @Test("пакет более новой версии отвечает отдельно")
    func newerFormatSaysSo() throws {
        var newer = Fixture.sealed
        newer[5] = UInt8(ascii: "9")

        let key = try BoundActivationKey(key: ActivationKey(input: Fixture.key))
        #expect(throws: PanelLinkError.packageTooNew) {
            try ActivationPackage.open(sealed: newer, with: key)
        }
    }

    /// Привязка входит в соль, значит и в ключ шифрования: даже добравшись до
    /// пакета, чужая машина его не откроет.
    @Test("пакет без привязки не открывается привязанным ключом")
    func bindingIsPartOfTheCipherKey() throws {
        let bound = try BoundActivationKey(key: ActivationKey(input: Fixture.key),
                                           installationID: "8f2c4a1b9d3e5f60")
        #expect(throws: PanelLinkError.keyDidNotOpen) {
            try ActivationPackage.open(sealed: Fixture.sealed, with: bound)
        }
    }

    @Test("обрубок не роняет разбор")
    func truncatedIsRejected() throws {
        let key = try BoundActivationKey(key: ActivationKey(input: Fixture.key))
        for length in [0, 3, 6, 10, 20] {
            #expect(throws: PanelLinkError.self) {
                try ActivationPackage.open(sealed: Fixture.sealed.prefix(length), with: key)
            }
        }
    }
}
