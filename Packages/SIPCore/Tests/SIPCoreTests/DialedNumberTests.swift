import Testing
@testable import SIPCore

@Suite("Набранный номер")
struct DialedNumberTests {

    @Test("Номер из CRM теряет оформление, но не цифры")
    func stripsHumanFormatting() {
        #expect(DialedNumber.normalized("+7 (918) 000-11-22") == "79180001122")
    }

    @Test("Неразрывный пробел и узкий пробел вырезаются наравне с обычным")
    func stripsExoticSpaces() {
        // Их подкладывают веб-страницы, из которых номер копируют, и на глаз
        // они неотличимы от обычного пробела — а ломают разбор так же.
        #expect(DialedNumber.normalized("8\u{00A0}918\u{202F}0001122") == "79180001122")
    }

    @Test("Звёздочка и решётка остаются: это коды сервисов АТС")
    func keepsServiceCodes() {
        #expect(DialedNumber.normalized("*97") == "*97")
        #expect(DialedNumber.normalized("#1") == "#1")
    }

    @Test("Плюс сохраняется только в начале")
    func keepsLeadingPlusOnly() {
        #expect(DialedNumber.normalized("+79180001122") == "79180001122")
        // `8+123` — не международный номер, а опечатка; сохранять в ней плюс
        // значит сохранять опечатку.
        #expect(DialedNumber.normalized("8+123") == "8123")
        #expect(DialedNumber.normalized("++7912") == "+7912")
    }

    @Test("Буквы и знаки препинания не проходят")
    func dropsLetters() {
        #expect(DialedNumber.normalized("доб. 172") == "172")
        #expect(DialedNumber.normalized("tel:172;ext=5") == "1725")
    }

    @Test("Пустой и один плюс звонком не считаются")
    func rejectsEmpty() {
        #expect(!DialedNumber.isDialable(""))
        #expect(!DialedNumber.isDialable("   "))
        #expect(!DialedNumber.isDialable("+"))
        #expect(!DialedNumber.isDialable("(   ) --"))
        #expect(DialedNumber.isDialable("172"))
    }

    @Test("Российский номер приводится к записи маршрута: 7 и десять цифр")
    func canonicalisesRussianNumbers() {
        // Три записи одного номера — один результат. Ровно это оператор и
        // получает из CRM, от клиента и из собственной привычки.
        #expect(DialedNumber.normalized("+79180001122") == "79180001122")
        #expect(DialedNumber.normalized("89180001122") == "79180001122")
        #expect(DialedNumber.normalized("79180001122") == "79180001122")
        #expect(DialedNumber.normalized("8 (918) 000-11-22") == "79180001122")
    }

    @Test("Всё, что не российский номер, правило не трогает")
    func leavesEverythingElseAlone() {
        // Добавочный: три цифры, и восьмёрка в начале ничего не значит.
        #expect(DialedNumber.normalized("172") == "172")
        #expect(DialedNumber.normalized("807") == "807")
        // Международный не российский: плюс обязан остаться, иначе номер
        // уедет на межгород как местный.
        #expect(DialedNumber.normalized("+12125550123") == "+12125550123")
        // Сервисный код АТС.
        #expect(DialedNumber.normalized("*97") == "*97")
        // Одиннадцать цифр, но код страны не наш — не наше дело.
        #expect(DialedNumber.normalized("+49180001122") == "+49180001122")
        // `+8…` — опечатка, а не междугородная восьмёрка: подменять в ней код
        // страны значит звонить наугад.
        #expect(DialedNumber.normalized("+89180001122") == "+89180001122")
    }

    @Test("Нормализация идемпотентна")
    func isIdempotent() {
        // Поле нормализует на каждый ввод символа, то есть применяет правило к
        // уже нормализованному значению снова и снова. Второй проход обязан
        // ничего не менять, иначе номер «уезжает» по мере набора.
        for raw in ["+7 (918) 000-11-22", "8 918 000 11 22", "172", "*97", "+12125550123"] {
            let once = DialedNumber.normalized(raw)
            #expect(DialedNumber.normalized(once) == once)
        }
    }
}
