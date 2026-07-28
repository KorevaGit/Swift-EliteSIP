import Foundation
import Testing
@testable import MediaCore

@Suite("SDES и SRTP")
struct SRTPTests {

    @Test("SDES round-trip сохраняет tag, suite и 30 байт ключа")
    func sdesRoundTrip() throws {
        let bytes = Data(0..<UInt8(SRTPMasterKey.byteCount))
        let key = try SRTPMasterKey(bytes: bytes)
        let original = SDESCryptoAttribute(tag: 7, key: key)
        let parsed = try #require(SDESCryptoAttribute(original.value))

        #expect(parsed == original)
        #expect(original.value.hasPrefix("7 AES_CM_128_HMAC_SHA1_80 inline:"))
    }

    @Test("SDES отвергает ослабляющие и неподдерживаемые параметры")
    func rejectsUnsupportedSDESParameters() throws {
        let key = try SRTPMasterKey(bytes: Data(repeating: 1, count: SRTPMasterKey.byteCount))
        let base = SDESCryptoAttribute(key: key).value

        #expect(SDESCryptoAttribute(base + " UNENCRYPTED_SRTP") == nil)
        #expect(SDESCryptoAttribute(base + "|2^20") == nil)
        #expect(SDESCryptoAttribute("0 AES_CM_128_HMAC_SHA1_80 inline:\(key.bytes.base64EncodedString())") == nil)
    }

    @Test("KDF совпадает с приложением B.3 RFC 3711")
    func rfc3711KeyDerivation() throws {
        let master = try SRTPMasterKey(bytes: Data(hex:
            "E1F97A0D3E018BE0D64FA32C06DE4139" +
            "0EC675AD498AFEEBB6960B3AABE6"
        ))
        let keys = try SRTPContext(masterKey: master).derivedSessionKeys

        #expect(keys.encryption == Data(hex: "C61E7A93744F39EE10734AFE3FF7A087"))
        #expect(keys.authentication == Data(hex: "CEBE321F6FF7716B6FD4AB49AF256A156D38BAA4"))
        #expect(keys.salt == Data(hex: "30CBBC08863D8C85D49DB34A9AE1"))
    }

    @Test("Защищённый пакет читается только контекстом встречного направления")
    func protectsAndUnprotects() throws {
        let key = try SRTPMasterKey(bytes: Data(0..<UInt8(SRTPMasterKey.byteCount)))
        let sender = try SRTPContext(masterKey: key)
        let receiver = try SRTPContext(masterKey: key)
        let packet = RTPPacket(
            payloadType: 0,
            sequenceNumber: 65_530,
            timestamp: 0xDECAFBAD,
            ssrc: 0xCAFEBABE,
            marker: true,
            payload: Data(repeating: 0xAB, count: 160)
        )

        let protected = try sender.protect(packet)
        #expect(protected.count == packet.encoded().count + 10)
        #expect(protected.prefix(RTPPacket.headerByteCount) == packet.encoded().prefix(RTPPacket.headerByteCount))
        #expect(protected.dropFirst(RTPPacket.headerByteCount).prefix(packet.payload.count) != packet.payload)
        #expect(try receiver.unprotect(protected) == packet)
    }

    @Test("Подмена и повтор пакета отбрасываются")
    func rejectsTamperingAndReplay() throws {
        let key = try SRTPMasterKey(bytes: Data(repeating: 0x42, count: SRTPMasterKey.byteCount))
        let sender = try SRTPContext(masterKey: key)
        let receiver = try SRTPContext(masterKey: key)
        let packet = RTPPacket(
            payloadType: 8,
            sequenceNumber: 100,
            timestamp: 160,
            ssrc: 99,
            payload: Data(repeating: 0xD5, count: 160)
        )
        let protected = try sender.protect(packet)

        var changed = protected
        changed[20] ^= 1
        #expect(throws: SRTPError.authenticationFailed) {
            _ = try receiver.unprotect(changed)
        }

        #expect(try receiver.unprotect(protected) == packet)
        #expect(throws: SRTPError.replayedPacket) {
            _ = try receiver.unprotect(protected)
        }
    }

    @Test("ROC переживает переход sequence number через ноль")
    func rolloverCounter() throws {
        let key = try SRTPMasterKey(bytes: Data(repeating: 0x77, count: SRTPMasterKey.byteCount))
        let sender = try SRTPContext(masterKey: key)
        let receiver = try SRTPContext(masterKey: key)

        for sequence in [UInt16.max - 1, UInt16.max, 0, 1] {
            let packet = RTPPacket(
                payloadType: 0,
                sequenceNumber: sequence,
                timestamp: UInt32(sequence),
                ssrc: 1234,
                payload: Data([UInt8(truncatingIfNeeded: sequence)])
            )
            #expect(try receiver.unprotect(sender.protect(packet)) == packet)
        }
    }
}

private extension Data {
    init(hex: String) {
        precondition(hex.count.isMultiple(of: 2))
        self.init(stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)!
        })
    }
}
