import CryptoKit
import Foundation
import Testing
@testable import PanelLink

/// Файл предустановок, подписанный **настоящей панелью на Go**.
///
/// Тот же довод, что у пакета активации: подпись, собранная здесь же своим
/// кодом, проверяла бы только то, что мы согласны сами с собой. Ключ у образца
/// выведен из постоянного зерна, чтобы файл был воспроизводим.
///
/// Перевыпускается `go run ./cmd/fixtures` в `Spark`.
enum BundleFixture {
    static let publicKey = "A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg="
    static let signed = Data(base64Encoded: """
        eyJwYXlsb2FkIjoiZXlKbWIzSnRZWFFpT2pFc0ltZGxibVZ5WVhSbFpGOWhkQ0k2SWpJd01qWXRNRGd0TWpSVU1UVTZNekE2TURCYUlp\
        d2ljSEpsYzJWMGN5STZXM3NpYVdRaU9pSTJSREZHTlVFeU1DMHdNREF3TFRRd01EQXRPREF3TUMwd01EQXdNREF3TURBd01ERWlMQ0p1\
        WVcxbElqb2kwSnpRdGRDOTBMWFF0TkMyMExYUmdDSXNJbkpsZG1semFXOXVJam94TWl3aWMyTm9aVzFoWDNabGNuTnBiMjRpT2pJc0lt\
        WnBaV3hrY3lJNmV5SnphWFJsUVdSa2NtVnpjMlZ6SWpwN0ltOW1abWxqWlNJNklqRTVNaTR4TmpndU1TNHlJaXdpY21WdGIzUmxJam9p\
        WTNKdExtVnNhWFJsYzI5amFHa3VZMjl0SW4xOWZWMTkiLCJzaWduYXR1cmUiOiJ4STBLdjh0NDJBUUlURndBYm8wZ2VuL2RUdUU5c0Fl\
        VVk0SENEODBwSjhtS0JuNm5XejBMblB2WHVMMmRLWWJ4cG0wdGZFdmRSRk0wbEY2dC83U3JDZz09In0=
        """.replacingOccurrences(of: "\n", with: ""))!

    static func key() throws -> Curve25519.Signing.PublicKey {
        try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: publicKey)!)
    }
}

@Suite("Файл предустановок")
struct PresetBundleTests {

    @Test("файл от панели проходит проверку и разбирается")
    func verifiesPanelBundle() throws {
        let bundle = try PresetBundle.verified(BundleFixture.signed, publicKey: BundleFixture.key())

        #expect(bundle.format == 1)
        #expect(bundle.presets.count == 1)

        let entry = try #require(bundle.presets.first)
        #expect(entry.id == "6D1F5A20-0000-4000-8000-000000000001")
        #expect(entry.name == "Менеджер")
        #expect(entry.revision == 12)
        #expect(entry.schemaVersion == 2)
    }

    /// Ровно то, ради чего линия подписывается: подделанный байт обязан
    /// отвергаться, а не применяться на всех рабочих местах.
    @Test("подделанный байт ломает подпись")
    func tamperingBreaksSignature() throws {
        let original = BundleFixture.signed
        let envelope = try #require(try JSONSerialization.jsonObject(with: original) as? [String: Any])
        let payload = try #require(envelope["payload"] as? String)

        // Подменяем один знак в полезной нагрузке, оставляя подпись прежней.
        var bytes = Array(payload.utf8)
        bytes[40] = bytes[40] == UInt8(ascii: "A") ? UInt8(ascii: "B") : UInt8(ascii: "A")

        var tampered = envelope
        tampered["payload"] = String(decoding: bytes, as: UTF8.self)
        let data = try JSONSerialization.data(withJSONObject: tampered)

        #expect(throws: PanelLinkError.signatureDidNotMatch) {
            try PresetBundle.verified(data, publicKey: BundleFixture.key())
        }
    }

    /// Файл, подписанный не тем ключом, — это файл не от нашей панели.
    @Test("чужая подпись отвергается")
    func foreignKeyIsRejected() throws {
        let foreign = Curve25519.Signing.PrivateKey().publicKey
        #expect(throws: PanelLinkError.signatureDidNotMatch) {
            try PresetBundle.verified(BundleFixture.signed, publicKey: foreign)
        }
    }

    /// Машина ищет себя по `id`: имя переименовывают, и поиск по нему разорвал
    /// бы связь у всех машин разом.
    @Test("своя запись находится по id, а не по имени")
    func findsItselfByID() throws {
        let bundle = try PresetBundle.verified(BundleFixture.signed, publicKey: BundleFixture.key())

        #expect(bundle.entry(id: "6D1F5A20-0000-4000-8000-000000000001") != nil)
        #expect(bundle.entry(id: "6D1F5A20-0000-4000-8000-000000000002") == nil)
    }

    /// Управляемые поля доносятся неразобранными — их разбирает приложение.
    @Test("управляемые поля доезжают как есть")
    func carriesFields() throws {
        let bundle = try PresetBundle.verified(BundleFixture.signed, publicKey: BundleFixture.key())
        let entry = try #require(bundle.presets.first)

        let object = try JSONSerialization.jsonObject(with: entry.fields)
        let addresses = try #require((object as? [String: Any])?["siteAddresses"] as? [String: Any])
        #expect(addresses["office"] as? String == "192.168.1.2")
        #expect(addresses["remote"] as? String == "crm.elitesochi.com")
    }

    @Test("мусор вместо файла не роняет разбор")
    func garbageIsRejected() throws {
        let key = try BundleFixture.key()
        for garbage in [Data(), Data("не json".utf8), Data(#"{"payload":"!!!"}"#.utf8)] {
            #expect(throws: PanelLinkError.malformedBundle) {
                try PresetBundle.verified(garbage, publicKey: key)
            }
        }
    }
}

@Suite("Подписи раздач в файле предустановок")
struct PresetBundleQueuesTests {

    private func bundle(_ queues: String?) throws -> PresetBundle {
        let tail = queues.map { ",\"queues\":\($0)" } ?? ""
        let json = "{\"format\":1,\"generated_at\":\"2026-11-20T10:00:00Z\",\"presets\":[]\(tail)}"
        return try PresetBundle.decode(Data(json.utf8))
    }

    @Test("блок разбирается, пустые строки пропускаются")
    func parsesTitles() throws {
        let queues = try #require(try bundle("""
            {"revision":5,"titles":[{"match":"GORACHAYA","title":"Горячая раздача"},\
            {"match":" ","title":"пусто"},{"match":"line3","title":""},{"title":"без искомого"}]}
            """).queues)
        #expect(queues.revision == 5)
        #expect(queues.titles == [.init(match: "GORACHAYA", title: "Горячая раздача")])
    }

    @Test("без блока или без ревизии — блока нет, предустановки целы")
    func missingOrBrokenBlock() throws {
        #expect(try bundle(nil).queues == nil)
        #expect(try bundle("{\"titles\":[]}").queues == nil)
        #expect(try bundle("{\"revision\":true}").queues == nil)
        #expect(try bundle("[1,2]").queues == nil)
    }

    @Test("пустой список правил — блок с ревизией")
    func emptyTitles() throws {
        #expect(try bundle("{\"revision\":2,\"titles\":[]}").queues == .init(revision: 2, titles: []))
    }
}
