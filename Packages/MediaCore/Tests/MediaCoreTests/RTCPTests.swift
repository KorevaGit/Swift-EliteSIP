import Foundation
import Testing
@testable import MediaCore

@Suite("RTCP")
struct RTCPTests {

    private func block(
        lost: Int32 = 0,
        fraction: Double = 0,
        jitter: UInt32 = 0,
        highest: UInt32 = 1000
    ) -> RTCP.ReportBlock {
        RTCP.ReportBlock(
            sourceSSRC: 0xDEAD_BEEF,
            fractionLost: fraction,
            cumulativeLost: lost,
            highestSequenceNumber: highest,
            jitter: jitter,
            lastSenderReport: 0x1234_5678,
            delaySinceLastSenderReport: 65536
        )
    }

    @Test("Отчёт отправителя переживает сборку и разбор")
    func senderReportRoundTrip() throws {
        let original = RTCP.SenderReport(
            ssrc: 0x1111_2222,
            ntpTimestamp: 0xAABB_CCDD_EEFF_0011,
            rtpTimestamp: 160_000,
            packetCount: 1000,
            octetCount: 160_000,
            reports: [block(lost: 7, fraction: 0.25, jitter: 480)]
        )

        let packets = try RTCP.parse(RTCP.encode(original))
        guard case .senderReport(let decoded)? = packets.first else {
            Issue.record("разобрался не как отчёт отправителя: \(packets)")
            return
        }

        #expect(decoded.ssrc == original.ssrc)
        #expect(decoded.ntpTimestamp == original.ntpTimestamp)
        #expect(decoded.rtpTimestamp == original.rtpTimestamp)
        #expect(decoded.packetCount == original.packetCount)
        #expect(decoded.octetCount == original.octetCount)
        #expect(decoded.reports.count == 1)
        #expect(decoded.reports[0].cumulativeLost == 7)
        #expect(decoded.reports[0].jitter == 480)
        // Доля потерь — восьмибитная дробь, точность у неё 1/256.
        #expect(abs(decoded.reports[0].fractionLost - 0.25) < 0.005)
    }

    @Test("Отчёт приёмника переживает сборку и разбор")
    func receiverReportRoundTrip() throws {
        let original = RTCP.ReceiverReport(ssrc: 0x3333_4444, reports: [block(), block()])
        let packets = try RTCP.parse(RTCP.encode(original))

        guard case .receiverReport(let decoded)? = packets.first else {
            Issue.record("разобрался не как отчёт приёмника: \(packets)")
            return
        }
        #expect(decoded.ssrc == 0x3333_4444)
        #expect(decoded.reports.count == 2)
    }

    @Test("Отрицательные потери не превращаются в шестнадцать миллионов")
    func negativeLossSurvives() throws {
        // По RFC 3550 §6.4.1 накопленные потери — 24-битное число СО ЗНАКОМ:
        // дубликаты уводят его в минус, и это законно. Наивный разбор без
        // растяжения знака даёт около 16,7 миллиона потерянных пакетов, и
        // отчёт выглядит как полная потеря связи на исправном канале.
        let original = RTCP.ReceiverReport(ssrc: 1, reports: [block(lost: -5)])
        let packets = try RTCP.parse(RTCP.encode(original))

        guard case .receiverReport(let decoded)? = packets.first else {
            Issue.record("не разобралось")
            return
        }
        #expect(decoded.reports[0].cumulativeLost == -5)
    }

    @Test("Составной пакет разбирается целиком, а не по первому")
    func parsesCompoundPacket() throws {
        // RTCP почти никогда не приходит одним пакетом: по RFC 3550 §6.1 отчёт
        // обязан идти в связке с описанием источника. Разбирать только первый
        // значит терять всё, что приехало следом.
        let compound = RTCP.compound(
            report: RTCP.encode(RTCP.ReceiverReport(ssrc: 42, reports: [block()])),
            ssrc: 42,
            canonicalName: "elitesip@16384"
        )

        let packets = try RTCP.parse(compound)
        #expect(packets.count == 2, "отчёт и SDES: \(packets)")
        if case .receiverReport(let report) = packets[0] {
            #expect(report.ssrc == 42)
        } else {
            Issue.record("первым должен идти отчёт")
        }
        if case .other(let type) = packets[1] {
            #expect(type == RTCP.PacketType.sourceDescription.rawValue)
        } else {
            Issue.record("вторым должно идти описание источника")
        }
    }

    @Test("Длина в заголовке считается в словах без первого")
    func headerLengthFollowsRFC() throws {
        // Единица измерения здесь — 32-битные слова МИНУС одно. Ошибка на
        // единицу ломает разбор всего составного пакета, а не одного поля.
        let data = RTCP.encode(RTCP.ReceiverReport(ssrc: 1, reports: []))
        #expect(data.count == 8, "заголовок 4 байта плюс SSRC")

        let words = data.bigEndianUInt16(at: data.index(data.startIndex, offsetBy: 2))
        #expect(words == 1, "восемь байт — это два слова, в поле пишется одно")
        #expect(data[0] >> 6 == 2, "версия RTP всегда 2")
        #expect(data[0] & 0x1F == 0, "блоков отчёта нет")
        #expect(data[1] == 201)
    }

    @Test("Мусор не разбирается и не роняет разбор")
    func rejectsGarbage() throws {
        // На открытый UDP-порт прилетает что угодно, включая сканеры.
        #expect(throws: RTCP.ParsingError.unsupportedVersion(0)) {
            _ = try RTCP.parse(Data([0x00, 0xC9, 0x00, 0x01, 0, 0, 0, 1]))
        }
        // Заголовок обещает больше, чем приехало.
        #expect(throws: RTCP.ParsingError.tooShort) {
            _ = try RTCP.parse(Data([0x80, 0xC9, 0x00, 0xFF, 0, 0, 0, 1]))
        }
        // Обрывок короче заголовка просто заканчивает разбор.
        #expect(try RTCP.parse(Data([0x80, 0xC9])).isEmpty)

    }

    @Test("Прощание опознаётся")
    func parsesGoodbye() throws {
        var data = Data([0x81, 203])
        data.appendBigEndian(UInt16(1))
        data.appendBigEndian(UInt32(0xCAFE_BABE))

        guard case .goodbye(let ssrc)? = try RTCP.parse(data).first else {
            Issue.record("прощание не опознано")
            return
        }
        #expect(ssrc == 0xCAFE_BABE)
    }

    @Test("Метка NTP считается от 1900 года")
    func ntpEpoch() {
        // Эпоха NTP на 70 лет раньше Unix. Ошибка здесь не ломает разговор, но
        // делает бессмысленной задержку кругового обхода.
        let ntp = RTCP.ntpTimestamp(for: Date(timeIntervalSince1970: 0))
        #expect(ntp >> 32 == 2_208_988_800)

        let later = RTCP.ntpTimestamp(for: Date(timeIntervalSince1970: 1))
        #expect(later >> 32 == 2_208_988_801)
    }

    @Test("Задержка кругового обхода считается по средним битам метки")
    func roundTripCalculation() {
        // Формат 16.16 секунды: 65536 — это ровно секунда.
        let block = RTCP.ReportBlock(
            sourceSSRC: 1,
            fractionLost: 0,
            cumulativeLost: 0,
            highestSequenceNumber: 0,
            jitter: 0,
            lastSenderReport: 1000 * 65536,
            delaySinceLastSenderReport: 65536 / 2
        )

        // Сейчас 1002 секунды, отчёт был на 1000-й, у собеседника пролежал
        // полсекунды — значит на дорогу ушло полторы.
        let rtt = block.roundTripTime(now: 1002 * 65536)
        #expect(rtt != nil)
        #expect(abs((rtt ?? 0) - 1.5) < 0.01)

        // Пока собеседник ни одного нашего отчёта не видел, считать нечего.
        var fresh = block
        fresh.lastSenderReport = 0
        #expect(fresh.roundTripTime(now: 1002 * 65536) == nil)
    }
}
