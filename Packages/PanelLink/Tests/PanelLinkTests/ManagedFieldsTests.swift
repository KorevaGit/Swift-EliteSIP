import Foundation
import Testing
@testable import PanelLink

@Suite("Управляемые поля")
struct ManagedFieldsTests {

    private func parse(_ json: String) -> ManagedFields {
        ManagedFields.parse(Data(json.utf8))
    }

    /// Главное правило всей линии, и цена его нарушения названа в M8:
    /// предустановка, написанная ради макросов, молча стёрла бы политику защиты
    /// на всех рабочих местах разом.
    @Test("отсутствующий блок остаётся nil, а не пустотой")
    func missingBlockStaysNil() {
        let fields = parse(#"{"dtmf":{"toneMilliseconds":90}}"#)

        #expect(fields.dtmf != nil)
        #expect(fields.incomingCall == nil)
        #expect(fields.conference == nil)
        #expect(fields.portKnock == nil)
        #expect(fields.siteAddresses == nil)
        #expect(fields.acceptsAnyTLSCertificate == nil)
        #expect(fields.transport == nil)
    }

    /// Протокол приезжает строкой и разбирается строкой: опознаёт её тот, кто
    /// накладывает поля, — там же, где живёт правило «незнакомое не применяется».
    @Test("протокол связи с АТС читается как есть")
    func transportIsReadVerbatim() {
        #expect(parse(#"{"transport":"udp"}"#).transport == "udp")
        #expect(parse(#"{"transport":"tls"}"#).transport == "tls")

        // Незнакомое сюда доходит нетронутым — отсеивает его наложение, а не
        // разбор: разбор не знает, что умеет линия.
        #expect(parse(#"{"transport":"ws"}"#).transport == "ws")

        // Не строка — это не «умолчание», а «поля нет»: машина сохранит своё.
        #expect(parse(#"{"transport":5060}"#).transport == nil)
    }

    /// То же правило на уровне поля: «панель прислала ноль» и «панель ничего не
    /// присылала» — разные вещи, и различить их обязан тип, а не соглашение.
    @Test("отсутствующее поле внутри блока остаётся nil")
    func missingFieldStaysNil() {
        let fields = parse(#"{"dtmf":{"toneMilliseconds":90}}"#)
        let dtmf = fields.dtmf

        #expect(dtmf?.toneMilliseconds == 90)
        #expect(dtmf?.gapMilliseconds == nil)
        #expect(dtmf?.macros == nil)
        #expect(dtmf?.macroColumns == nil)
    }

    /// Ноль — это значение, и спутать его с отсутствием нельзя: выключенная
    /// пауза и неуправляемая пауза — разные состояния машины.
    @Test("ноль и пустая строка — это значения, а не отсутствие")
    func zeroIsAValue() {
        let fields = parse(#"{"dtmf":{"pauseMilliseconds":0},"conference":{"featureCode":""}}"#)

        #expect(fields.dtmf?.pauseMilliseconds == 0)
        #expect(fields.conference?.featureCode == "")
        #expect(fields.conference?.roomExtension == nil)
    }

    /// Отказ от файла целиком недопустим: тогда до старой сборки не доедет и
    /// смена адреса АТС, без которой она не звонит.
    @Test("незнакомое поле не мешает разобрать остальное")
    func unknownFieldIsIgnored() {
        let fields = parse("""
            {"dtmf":{"toneMilliseconds":90,"чегоТоНовое":42},
             "совсемНовыйБлок":{"a":1},
             "siteAddresses":{"office":"10.0.0.1","remote":"crm.example.com"}}
            """)

        #expect(fields.dtmf?.toneMilliseconds == 90)
        #expect(fields.siteAddresses?.office == "10.0.0.1")
        #expect(fields.siteAddresses?.remote == "crm.example.com")
    }

    /// Испорченный блок теряется в одиночку. Это и есть то, ради чего блоки
    /// разбираются порознь: сломанный dtmf не должен уносить адрес АТС.
    @Test("сломанный блок не уносит соседние")
    func brokenBlockDoesNotTakeNeighbours() {
        let fields = parse("""
            {"dtmf":{"toneMilliseconds":"это не число"},
             "siteAddresses":{"office":"10.0.0.1","remote":"crm.example.com"},
             "acceptsAnyTLSCertificate":false}
            """)

        #expect(fields.dtmf == nil, "сломанный блок должен потеряться")
        #expect(fields.siteAddresses?.office == "10.0.0.1", "соседний блок обязан уцелеть")
        #expect(fields.acceptsAnyTLSCertificate == false)
    }

    @Test("мусор вместо файла даёт пустые поля, а не отказ")
    func garbageGivesEmptyFields() {
        for garbage in ["", "не json", "[1,2,3]", "null", "42"] {
            let fields = ManagedFields.parse(Data(garbage.utf8))
            #expect(fields == ManagedFields(), "мусор \(garbage) дал не пустое")
        }
    }

    /// `isServerManaged` приложение выводит из режима машины, а приехавшее
    /// полем оно означало бы два источника одного факта.
    @Test("isServerManaged из файла не берётся")
    func serverManagedIsNotAccepted() {
        let fields = parse(#"{"incomingCall":{"isEnabled":true,"isServerManaged":true}}"#)

        #expect(fields.incomingCall?.isEnabled == true)
        // Поля просто нет в типе: взять его неоткуда, даже если панель пришлёт.
        #expect(Mirror(reflecting: fields.incomingCall!).children
            .contains { $0.label == "isServerManaged" } == false)
    }

    @Test("клавиши разбираются списком")
    func listsAreParsed() {
        let fields = parse("""
            {"dtmf":{"macros":[
               {"id":"a","title":"ЮРИСТ","sequence":"*02,101","transfersCall":true},
               {"id":"b","title":"СКЛАД","sequence":"*02,110"}]}}
            """)

        let macros = fields.dtmf?.macros
        #expect(macros?.count == 2)
        #expect(macros?[0].title == "ЮРИСТ")
        #expect(macros?[0].transfersCall == true)
        // У второй клавиши пометки нет — и это «администратор не сказал», а не
        // «перевода тут нет».
        #expect(macros?[1].transfersCall == nil)
    }

    /// Панель прежних ревизий шлёт словарь очередей — клиент его больше не
    /// знает. Незнакомый ключ обязан быть пропущен молча, а не уронить разбор:
    /// иначе машина, не успевшая получить новую ревизию, осталась бы вообще без
    /// управляемых полей.
    @Test("словарь очередей от старой панели пропускается молча")
    func retiredQueueDictionaryIsIgnored() {
        let fields = parse("""
            {"queues":{"queues":[{"id":"q","number":"1000","title":"Раздача"}]},
             "conference":{"featureCode":"*3"}}
            """)

        #expect(fields.conference?.featureCode == "*3")
    }

    @Test("стук разбирается вместе с шагами")
    func knockIsParsed() {
        let fields = parse("""
            {"portKnock":{"steps":[{"payloadBytes":228,"count":2},
                                   {"host":"45.10.53.84","payloadBytes":126,"count":1}],
                          "spacingSeconds":1.5,"repeatIntervalSeconds":600}}
            """)

        let knock = fields.portKnock
        #expect(knock?.steps?.count == 2)
        // Пустой адрес означает «основной адрес АТС», и отсутствие ключа здесь
        // значит то же самое.
        #expect(knock?.steps?[0].host == nil)
        #expect(knock?.steps?[1].host == "45.10.53.84")
        #expect(knock?.spacingSeconds == 1.5)
    }

    /// Проверка на том же файле, что приезжает с боевой панели: разбор обязан
    /// сходиться не с придуманным JSON, а с настоящим.
    @Test("поля из настоящего файла предустановок разбираются")
    func parsesFieldsFromRealBundle() throws {
        let bundle = try PresetBundle.verified(BundleFixture.signed, publicKey: BundleFixture.key())
        let entry = try #require(bundle.presets.first)

        let fields = ManagedFields.parse(entry.fields)
        #expect(fields.siteAddresses?.office == "192.168.1.2")
        #expect(fields.siteAddresses?.remote == "crm.elitesochi.com")
        // Всем остальным панель в этом файле не управляет.
        #expect(fields.dtmf == nil)
        #expect(fields.incomingCall == nil)
    }
}
