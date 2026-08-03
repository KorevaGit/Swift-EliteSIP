import Compat
import Foundation
import XCTest

@testable import SIPCore

/// Проверки стука по портам.
///
/// Сеть здесь не участвует ни в одном тесте: проверяется то, что можно испортить
/// правкой, — решение «стучать или нет», порядок и длины пакетов, правило
/// пропуска повторов и сборка самого ICMP. Живой шлюз это не заменяет и не
/// претендует: он либо откроет порт, либо нет, и узнать это можно только на нём.
final class PortKnockTests: XCTestCase {

    // MARK: - Кому стучать

    func testInternalServerNeedsNoKnocking() {
        // Офисный адрес из боевой настройки и всё остальное приватное.
        for host in [
            "192.168.1.2", "192.168.1.154", "10.0.0.1", "172.16.0.1", "172.31.255.254",
            "127.0.0.1", "localhost", "asterisk.local", "169.254.1.1", "::1",
        ] {
            XCTAssertTrue(PortKnockPolicy.isInternal(host: host), host)
            XCTAssertFalse(PortKnockPolicy.needsKnocking(serverHost: host), host)
        }
    }

    func testExternalServerNeedsKnocking() {
        for host in ["crm.elitesochi.com", "45.10.53.84", "8.8.8.8", "172.32.0.1", "11.0.0.1"] {
            XCTAssertFalse(PortKnockPolicy.isInternal(host: host), host)
            XCTAssertTrue(PortKnockPolicy.needsKnocking(serverHost: host), host)
        }
    }

    /// Пустой адрес — это ненастроенный профиль, а не внешний сервер. Стучать
    /// в никуда семь секунд перед заведомо провальной регистрацией незачем.
    func testEmptyHostIsTreatedAsInternal() {
        XCTAssertTrue(PortKnockPolicy.isInternal(host: ""))
        XCTAssertTrue(PortKnockPolicy.isInternal(host: "   "))
    }

    /// `172.16.0.0/12` — это `172.16`–`172.31`, а не весь `172.*`.
    func testPrivateRangeBoundaries() {
        XCTAssertTrue(PortKnockPolicy.isInternal(host: "172.16.0.0"))
        XCTAssertTrue(PortKnockPolicy.isInternal(host: "172.31.0.0"))
        XCTAssertFalse(PortKnockPolicy.isInternal(host: "172.15.0.0"))
        XCTAssertFalse(PortKnockPolicy.isInternal(host: "172.32.0.0"))
    }

    func testKnockerIsNotCreatedForInternalServer() {
        XCTAssertNil(PortKnocker.forServer("192.168.1.2") { _, _ in })
        XCTAssertNotNil(PortKnocker.forServer("crm.elitesochi.com") { _, _ in })
    }

    /// Пустая последовательность — это выключенный стук, а не повод собрать
    /// актор, который ничего не делает.
    func testEmptySequenceDisablesKnocking() {
        let disabled = PortKnockSequence(steps: [])
        XCTAssertTrue(disabled.isEmpty)
        XCTAssertNil(PortKnocker.forServer("crm.elitesochi.com", sequence: disabled) { _, _ in })
    }

    // MARK: - Что именно уходит

    /// Последовательность должна совпадать со скриптом побайтово и по порядку:
    /// правило на шлюзе не наше, проверить его мы не можем, и любое «улучшение»
    /// здесь означает, что рабочее место молча перестаёт подключаться.
    func testProductionSequenceMatchesTheShellScript() {
        let steps = PortKnockSequence.production.steps
        XCTAssertEqual(steps.count, 6)

        XCTAssertEqual(steps[0].host, "")
        XCTAssertEqual(steps[0].payloadBytes, 228)
        XCTAssertEqual(steps[0].count, 2)

        XCTAssertEqual(steps[1].host, "")
        XCTAssertEqual(steps[1].payloadBytes, 126)
        XCTAssertEqual(steps[1].count, 2)

        XCTAssertEqual(steps[2].host, "")
        XCTAssertEqual(steps[2].payloadBytes, 125)
        XCTAssertEqual(steps[2].count, 1)

        XCTAssertEqual(steps[3].host, "45.10.53.84")
        XCTAssertEqual(steps[3].payloadBytes, 228)
        XCTAssertEqual(steps[4].host, "45.10.53.86")
        XCTAssertEqual(steps[4].payloadBytes, 126)
        XCTAssertEqual(steps[5].host, "45.10.53.94")
        XCTAssertEqual(steps[5].payloadBytes, 125)

        XCTAssertEqual(PortKnockSequence.production.packetCount, 8)
    }

    /// Пустой хост шага — это «сервер из профиля», а не буквально пустой адрес.
    func testStepHostFallsBackToServer() {
        let step = PortKnockStep(payloadBytes: 228, count: 2)
        XCTAssertEqual(step.resolvedHost(server: "crm.elitesochi.com"), "crm.elitesochi.com")

        let literal = PortKnockStep(host: "45.10.53.84", payloadBytes: 228)
        XCTAssertEqual(literal.resolvedHost(server: "crm.elitesochi.com"), "45.10.53.84")
    }

    /// Задержка перед первым REGISTER должна быть известна заранее: её видно в
    /// журнале, и она же — то, чем удалённый запуск отличается от офисного.
    func testEstimatedDurationCountsGapsNotPackets() {
        XCTAssertEqual(PortKnockSequence.production.estimatedDuration, .seconds(7.0))

        let single = PortKnockSequence(steps: [PortKnockStep(payloadBytes: 100)])
        XCTAssertEqual(single.estimatedDuration, .zero)
    }

    // MARK: - Когда пропускать

    func testThrottleAllowsFirstKnock() {
        let throttle = PortKnockThrottle(minimumInterval: .seconds(600))
        XCTAssertTrue(throttle.shouldKnock(reason: .registration, now: Date()))
        XCTAssertTrue(throttle.shouldKnock(reason: .periodic, now: Date()))
    }

    func testThrottleSkipsUntilIntervalPasses() {
        var throttle = PortKnockThrottle(minimumInterval: .seconds(600))
        let start = Date()
        throttle.recordKnock(at: start)

        XCTAssertFalse(throttle.shouldKnock(reason: .periodic, now: start.addingTimeInterval(1)))
        XCTAssertFalse(throttle.shouldKnock(reason: .registration, now: start.addingTimeInterval(599)))
        XCTAssertTrue(throttle.shouldKnock(reason: .periodic, now: start.addingTimeInterval(600)))
    }

    /// Повтор после отказа не пропускается никогда. Это главное правило здесь:
    /// отказ регистрации и есть самый сильный признак, что адрес сменился и в
    /// списке шлюза нас больше нет.
    func testThrottleNeverSkipsRetry() {
        var throttle = PortKnockThrottle(minimumInterval: .seconds(600))
        let start = Date()
        throttle.recordKnock(at: start)
        XCTAssertTrue(throttle.shouldKnock(reason: .retry, now: start.addingTimeInterval(1)))
    }

    func testInvalidateForgetsPreviousKnock() {
        var throttle = PortKnockThrottle(minimumInterval: .seconds(600))
        let start = Date()
        throttle.recordKnock(at: start)
        XCTAssertFalse(throttle.shouldKnock(reason: .periodic, now: start))
        throttle.invalidate()
        XCTAssertTrue(throttle.shouldKnock(reason: .periodic, now: start))
    }

    // MARK: - Сам пакет

    /// `ping -s N` кладёт N байт данных после восьмибайтового заголовка. Длина
    /// и есть подпись стука, поэтому это не деталь реализации, а требование.
    func testPacketLengthMatchesPingSemantics() {
        for payload in [125, 126, 228] {
            let packet = ICMPEcho.makePacket(payloadBytes: payload, identifier: 1, sequenceNumber: 1)
            XCTAssertEqual(packet.count, payload + 8)
        }
    }

    func testPacketHeaderIsEchoRequest() {
        let packet = ICMPEcho.makePacket(payloadBytes: 16, identifier: 0xABCD, sequenceNumber: 0x0102)
        XCTAssertEqual(packet[0], 8)
        XCTAssertEqual(packet[1], 0)
        XCTAssertEqual(packet[4], 0xAB)
        XCTAssertEqual(packet[5], 0xCD)
        XCTAssertEqual(packet[6], 0x01)
        XCTAssertEqual(packet[7], 0x02)
    }

    /// Проверка суммы по её же определению: сумма 16-битных слов готового
    /// пакета в обратном коде равна 0xFFFF.
    func testChecksumIsValid() {
        for payload in [0, 1, 125, 126, 228] {
            let packet = ICMPEcho.makePacket(
                payloadBytes: payload, identifier: 0x1234, sequenceNumber: 7
            )
            XCTAssertEqual(~ICMPEcho.checksum(packet), 0xFFFF, "полезная нагрузка \(payload)")
        }
    }

    /// Нечётная длина — отдельный путь в сумме: последний байт дополняется
    /// нулём, а не отбрасывается.
    func testChecksumHandlesOddLength() {
        XCTAssertEqual(ICMPEcho.checksum([0x00, 0x01, 0xF2]), ICMPEcho.checksum([0x00, 0x01, 0xF2, 0x00]))
    }

    func testPayloadFollowsPingPattern() {
        let packet = ICMPEcho.makePacket(payloadBytes: 300, identifier: 1, sequenceNumber: 1)
        XCTAssertEqual(packet[8], 0)
        XCTAssertEqual(packet[8 + 255], 255)
        XCTAssertEqual(packet[8 + 256], 0)
    }

    // MARK: - Настройки

    /// Файл настроек без ключа `steps` должен давать боевую последовательность,
    /// а с пустым списком — выключенный стук. Иначе выключить его правкой файла
    /// было бы нельзя.
    func testSequenceDecodingDefaults() throws {
        let empty = try JSONDecoder().decode(PortKnockSequence.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.steps, PortKnockSequence.production.steps)
        XCTAssertEqual(empty.repeatIntervalSeconds, 600)

        let disabled = try JSONDecoder().decode(
            PortKnockSequence.self, from: Data(#"{"steps": []}"#.utf8)
        )
        XCTAssertTrue(disabled.isEmpty)
    }

    func testSequenceRoundTrip() throws {
        let encoded = try JSONEncoder().encode(PortKnockSequence.production)
        let decoded = try JSONDecoder().decode(PortKnockSequence.self, from: encoded)
        XCTAssertEqual(decoded, PortKnockSequence.production)
    }
}
