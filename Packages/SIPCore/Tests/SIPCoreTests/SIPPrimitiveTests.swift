import Testing
@testable import SIPCore

@Suite("Примитивы SIP")
struct SIPPrimitiveTests {

    @Test("Метод разбирается без учёта регистра")
    func methodParsing() {
        #expect(SIPMethod(name: "invite") == .invite)
        #expect(SIPMethod(name: "ReFeR") == .refer)
        #expect(SIPMethod(name: "PUBLISH") == nil, "неподдерживаемый метод не должен молча проходить")
    }

    @Test("Диалог создаёт только INVITE")
    func dialogCreation() {
        #expect(SIPMethod.invite.createsDialog)
        for method in SIPMethod.allCases where method != .invite {
            #expect(!method.createsDialog, "\(method.rawValue) не должен создавать диалог")
        }
    }

    @Test("Порты и свойства транспорта")
    func transportProperties() {
        #expect(SIPTransport.udp.defaultPort == 5060)
        #expect(SIPTransport.tcp.defaultPort == 5060)
        #expect(SIPTransport.tls.defaultPort == 5061)

        #expect(SIPTransport.tls.isSecure)
        #expect(!SIPTransport.udp.isSecure)

        // От этого зависит, запускать ли retransmit-таймеры транзакции.
        #expect(!SIPTransport.udp.isReliable)
        #expect(SIPTransport.tcp.isReliable)
        #expect(SIPTransport.tls.isReliable)

        #expect(SIPTransport.udp.protocolName == "UDP")
        #expect(SIPTransport(name: "TLS") == .tls)
    }

    @Test("branch начинается с обязательного магического префикса")
    func branchHasMagicCookie() {
        let branch = SIPToken.branch()
        #expect(branch.hasPrefix(SIPToken.branchMagicCookie))
        #expect(branch.count > SIPToken.branchMagicCookie.count, "после префикса должна быть случайная часть")
    }

    @Test("Токены не повторяются")
    func tokensAreUnique() {
        // Совпадение call-id между звонками ломает маршрутизацию диалогов,
        // поэтому проверяем именно уникальность, а не просто ненулевую длину.
        let count = 2000
        #expect(Set((0..<count).map { _ in SIPToken.branch() }).count == count)
        #expect(Set((0..<count).map { _ in SIPToken.callID() }).count == count)
        #expect(Set((0..<count).map { _ in SIPToken.tag() }).count == count)
    }

    @Test("Токены состоят только из безопасных символов")
    func tokensAreSafe() {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        for _ in 0..<200 {
            #expect(SIPToken.tag().allSatisfy { allowed.contains($0) })
        }
    }

    @Test("Call-ID с хостом и без")
    func callIDForms() {
        #expect(!SIPToken.callID().contains("@"))
        #expect(SIPToken.callID(host: "mac.local").hasSuffix("@mac.local"))
        #expect(!SIPToken.callID(host: "").contains("@"), "пустой хост не должен давать висячую собаку")
    }

    /// По согласованному плану номер аккаунта служит и user-part, и
    /// отображаемым именем: пустое поле означает «имя равно номеру», а не
    /// «имени нет».
    @Test("Отображаемое имя по умолчанию равно номеру")
    func displayNameFallsBackToNumber() {
        let bare = SIPAccount(username: "711", domain: "pbx.example")
        #expect(bare.effectiveDisplayName == "711")

        var named = bare
        named.displayName = "Call_Center"
        #expect(named.effectiveDisplayName == "Call_Center")
    }

    /// Логин для аутентификации падает на номер по тому же правилу — проверяем
    /// рядом, чтобы две подстановки не разъехались.
    @Test("Логин аутентификации по умолчанию равен номеру")
    func authUsernameFallsBackToNumber() {
        let bare = SIPAccount(username: "711", domain: "pbx.example")
        #expect(bare.effectiveAuthUsername == "711")

        var separate = bare
        separate.authUsername = "711-auth"
        #expect(separate.effectiveAuthUsername == "711-auth")

        separate.authUsername = ""
        #expect(separate.effectiveAuthUsername == "711", "пустая строка — это не логин")
    }
}
