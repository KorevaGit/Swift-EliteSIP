import Foundation
import Testing
@testable import MediaCore

/// Отдельный набор про переход счётчика пакетов через ноль.
///
/// Это место в SRTP ломается чаще всего и ломается позже всего: номер
/// шестнадцатибитный, и при 20 мс на пакет переход случается примерно через
/// двадцать две минуты разговора. Ошибка здесь выглядит не как отказ, а как
/// внезапная тишина на длинном звонке — из тех, что не воспроизводятся на
/// стенде и списываются на сеть.
///
/// Основной набор проверяет ровный переход. Здесь — то, что бывает в жизни:
/// потери и перестановки ровно на границе, когда отправитель и получатель
/// по-разному представляют, какой сейчас оборот.
@Suite("SRTP: переход счётчика")
struct SRTPRolloverTests {

    private func makeKey() -> SRTPMasterKey {
        try! SRTPMasterKey(bytes: Data(repeating: 0x5A, count: SRTPMasterKey.byteCount))
    }

    private func packet(_ sequence: UInt16, payload byte: UInt8 = 0x7F) -> RTPPacket {
        RTPPacket(
            payloadType: 0,
            sequenceNumber: sequence,
            timestamp: UInt32(sequence) &* 160,
            ssrc: 0x0BAD_F00D,
            payload: Data(repeating: byte, count: 160)
        )
    }

    @Test("Потеря пакета ровно на границе оборота не сбивает счётчик")
    func survivesLossAtRollover() throws {
        let key = makeKey()
        let sender = try SRTPContext(masterKey: key)
        let receiver = try SRTPContext(masterKey: key)

        // Отправитель нумерует подряд, а до получателя 65535 не доезжает —
        // именно тот пакет, на котором происходит переход.
        var onTheWire: [(UInt16, Data)] = []
        for sequence in [UInt16(65_533), 65_534, 65_535, 0, 1, 2] {
            onTheWire.append((sequence, try sender.protect(packet(sequence))))
        }

        for (sequence, data) in onTheWire where sequence != 65_535 {
            let decoded = try receiver.unprotect(data)
            #expect(decoded.sequenceNumber == sequence)
            #expect(decoded.payload == Data(repeating: 0x7F, count: 160))
        }
    }

    @Test("Опоздавший пакет из прошлого оборота расшифровывается верно")
    func decodesLatePacketFromPreviousCycle() throws {
        let key = makeKey()
        let sender = try SRTPContext(masterKey: key)
        let receiver = try SRTPContext(masterKey: key)

        let before = try sender.protect(packet(65_534, payload: 0x11))
        let atEdge = try sender.protect(packet(65_535, payload: 0x22))
        let after = try sender.protect(packet(0, payload: 0x33))
        let next = try sender.protect(packet(1, payload: 0x44))

        // Порядок доставки: край проехал, потом пришло уже из нового оборота,
        // и только затем доковылял опоздавший из старого.
        #expect(try receiver.unprotect(before).payload.first == 0x11)
        #expect(try receiver.unprotect(after).payload.first == 0x33)
        #expect(try receiver.unprotect(next).payload.first == 0x44)

        // Ключевая проверка: получатель уже перешёл на новый оборот, и наивная
        // оценка индекса дала бы для 65535 неверный счётчик. Расшифровать его
        // с неверным индексом — значит получить шум вместо звука, причём
        // пакет пройдёт проверку подлинности только если индекс угадан верно.
        let late = try receiver.unprotect(atEdge)
        #expect(late.sequenceNumber == 65_535)
        #expect(late.payload == Data(repeating: 0x22, count: 160))
    }

    @Test("Разговор длиннее оборота идёт без потерь смысла")
    func survivesFullCycle() throws {
        let key = makeKey()
        let sender = try SRTPContext(masterKey: key)
        let receiver = try SRTPContext(masterKey: key)

        // Начинаем незадолго до границы и проходим её насквозь. Двести пакетов
        // — это четыре секунды разговора, но важен именно переход.
        var sequence = UInt16(65_400)
        for step in 0..<200 {
            let byte = UInt8(truncatingIfNeeded: step)
            let decoded = try receiver.unprotect(sender.protect(packet(sequence, payload: byte)))
            #expect(decoded.payload == Data(repeating: byte, count: 160), "шаг \(step), номер \(sequence)")
            sequence &+= 1
        }
    }

    @Test("Повтор из прошлого оборота отбрасывается, а не расшифровывается заново")
    func rejectsReplayAcrossRollover() throws {
        let key = makeKey()
        let sender = try SRTPContext(masterKey: key)
        let receiver = try SRTPContext(masterKey: key)

        let edge = try sender.protect(packet(65_535))
        _ = try sender.protect(packet(0))

        #expect(try receiver.unprotect(edge).sequenceNumber == 65_535)
        #expect(throws: SRTPError.replayedPacket) {
            _ = try receiver.unprotect(edge)
        }
    }

    @Test("Окно защиты от повторов держит перестановку в пределах глубины")
    func replayWindowAllowsReordering() throws {
        let key = makeKey()
        let sender = try SRTPContext(masterKey: key)
        let receiver = try SRTPContext(masterKey: key)

        var wire: [Data] = []
        for sequence in UInt16(1000)...UInt16(1039) {
            wire.append(try sender.protect(packet(sequence)))
        }

        // Сначала самый свежий, потом всё остальное задом наперёд: перестановка
        // на сорок пакетов — это восемьсот миллисекунд, больше любого разумного
        // джиттера, и окно обязано её пережить.
        #expect(try receiver.unprotect(wire[39]).sequenceNumber == 1039)
        for index in stride(from: 38, through: 0, by: -1) {
            let decoded = try receiver.unprotect(wire[index])
            #expect(decoded.sequenceNumber == UInt16(1000 + index))
        }

        // А вот теперь любой из них — уже повтор.
        #expect(throws: SRTPError.replayedPacket) {
            _ = try receiver.unprotect(wire[20])
        }
    }

    @Test("Слишком старый пакет отбрасывается по глубине окна")
    func rejectsPacketsOlderThanWindow() throws {
        let key = makeKey()
        let sender = try SRTPContext(masterKey: key)
        let receiver = try SRTPContext(masterKey: key)

        let ancient = try sender.protect(packet(1))
        for sequence in UInt16(2)...UInt16(200) {
            _ = try receiver.unprotect(sender.protect(packet(sequence)))
        }

        // Окно шестьдесят четыре пакета; всё, что старше, считается повтором
        // без разбора. Это требование RFC 3711 §3.3.2, а не наша экономия:
        // помнить всю историю разговора нельзя, а принимать что попало из
        // далёкого прошлого — значит открыть дорогу повторной отправке.
        #expect(throws: SRTPError.replayedPacket) {
            _ = try receiver.unprotect(ancient)
        }
    }

    @Test("Чужой ключ не расшифровывает, а именно отвергает")
    func wrongKeyFailsAuthentication() throws {
        let sender = try SRTPContext(masterKey: makeKey())
        let stranger = try SRTPContext(
            masterKey: SRTPMasterKey(bytes: Data(repeating: 0xA5, count: SRTPMasterKey.byteCount))
        )

        // Важно, что это именно отказ проверки подлинности, а не мусор на
        // выходе: пакет с чужим ключом не должен доехать до аудиотракта ни в
        // каком виде.
        #expect(throws: SRTPError.authenticationFailed) {
            _ = try stranger.unprotect(sender.protect(packet(500)))
        }
    }
}
