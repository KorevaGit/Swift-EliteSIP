import Testing
@testable import SIPCore

@Suite("Автоподъём по заголовку")
struct AutoAnswerHeaderTests {

    private func asks(_ pairs: [(String, String)]) -> Bool {
        var headers = SIPHeaders()
        for (name, value) in pairs { headers.append(name, value) }
        return SIPUserAgent.asksForAutoAnswer(headers)
    }

    @Test("Просьбы, которые понимает MicroSIP и не только")
    func recognized() {
        #expect(asks([("X-Autoanswer", "TRUE")]))
        #expect(asks([("X-Auto-Answer", "yes")]))
        #expect(asks([("Call-Info", "<sip:pbx>;answer-after=0")]))
        #expect(asks([("Alert-Info", "Auto Answer")]))
        #expect(asks([("Alert-Info", "<http://127.0.0.1>;info=alert-autoanswer")]))
        #expect(asks([("Alert-Info", "<http://x>;info=intercom")]))
        #expect(asks([("Answer-Mode", "Auto;require")]))
    }

    @Test("Без просьбы и с отказом — не поднимать")
    func ignored() {
        #expect(!asks([]))
        #expect(!asks([("X-Autoanswer", "FALSE")]))
        #expect(!asks([("Alert-Info", "<http://x>;info=ring2")]))
        #expect(!asks([("Answer-Mode", "Manual")]))
    }
}
