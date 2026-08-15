import Network
import Testing
@testable import SIPCore

/// Диагностика отказа подключения.
///
/// Тесты на текст сообщения — не педантизм. Настоящий случай: боевой Asterisk
/// слушает незашифрованный SIP на 5060, в настройках выбрали TLS и тот же порт
/// 5060, а приложение написало «ожидание сети: The operation couldn’t be
/// completed. (Network.NWError error -9816 — server closed session with no
/// notification)». Человек полчаса проверял сеть, хотя чинилась одна строка в
/// настройках.
@Suite("Диагностика транспорта")
struct TransportDiagnosticsTests {

    private func transport(_ kind: SIPTransport, port: UInt16) -> NetworkSIPTransport {
        NetworkSIPTransport(
            remote: SIPEndpoint(host: "192.168.1.2", port: port),
            transport: kind
        )
    }

    /// errSSLClosedNoNotify. Именно этот код приходит, когда TLS-рукопожатие
    /// уходит на порт с обычным SIP.
    private let tlsClosedNoNotify = NWError.tls(-9816)

    @Test("Отказ TLS на порту обычного SIP называет причину и нужный порт")
    func tlsOnPlainPortSuggestsPort() {
        let reason = transport(.tls, port: 5060).explain(tlsClosedNoNotify)

        #expect(reason.contains("TLS"))
        #expect(reason.contains("5060"), "человек должен увидеть порт, который выбрал")
        #expect(reason.contains("5061"), "и порт, который нужен")
        #expect(!reason.contains("ожидание сети"), "сеть здесь ни при чём, и уводить в неё нельзя")
    }

    /// На штатном порту TLS тот же код означает уже другое: порт верный, а вот
    /// TLS на сервере может быть выключен или сертификат не подходит. Подсказка
    /// про порт здесь была бы враньём.
    @Test("Отказ TLS на порту 5061 не советует менять порт")
    func tlsOnProperPortBlamesServer() {
        let reason = transport(.tls, port: 5061).explain(tlsClosedNoNotify)

        #expect(reason.contains("TLS"))
        #expect(reason.contains(
            PackageText.localized("проверьте, включён ли TLS на сервере и подходит ли сертификат")
        ))
        #expect(!reason.contains("нужен 5061"))
    }

    @Test("Закрытый порт назван закрытым, а не «ожиданием сети»")
    func refusedPortIsNamed() {
        let reason = transport(.udp, port: 5070).explain(.posix(.ECONNREFUSED))

        #expect(reason.contains("5070"))
        #expect(reason == String(
            format: PackageText.localized("порт %lld закрыт: на нём никто не слушает"),
            5070
        ))
    }

    @Test("Недоступный адрес и неразрешимое имя различаются")
    func unreachableAndDNSDiffer() {
        let unreachable = transport(.udp, port: 5060).explain(.posix(.EHOSTUNREACH))
        let dns = transport(.udp, port: 5060).explain(.dns(-65554))

        #expect(unreachable == String(
            format: PackageText.localized("нет маршрута до %@"),
            "192.168.1.2"
        ))
        #expect(dns == String(
            format: PackageText.localized("имя %@ не разрешается"),
            "192.168.1.2"
        ))
        #expect(unreachable != dns)
    }

    /// Незнакомый код не должен ни падать, ни превращаться в пустую строку:
    /// хоть что-то в журнале лучше, чем ничего.
    @Test("Незнакомая ошибка всё равно даёт непустой текст")
    func unknownErrorStillDescribed() {
        let reason = transport(.udp, port: 5060).explain(.posix(.EIO))
        #expect(!reason.isEmpty)
    }
}
