import Foundation
import Testing
@testable import PanelLink

/// Вектор выпущен настоящим `elitesip.SealForMachine` из Spark: обе половины
/// должны сходиться байт в байт, а не «по чтению».
struct PairSessionTests {

    let privateKey = Data(base64Encoded: "Vtctr55SzoqzVft7pbbq8occ4/470abouqHP6gH1aC8=")!
    let sealed = "4f0VOiU27K2DhYOr59IoeWiKGDEhhlOv+0jnQ0tE9yiix6OvTMAfHA3CoqPlizlAf9A1nL3LnCf3FRanmjPFLDK0/Blxf4MF"

    @Test func opensKeySealedBySpark() throws {
        let pair = try PairKeyPair(rawPrivateKey: privateKey)
        #expect(pair.publicKeyBase64 == "gVTpg5FyhfKjlaW2HGMVzVHtVAT1Cnp12hm2DNF6A28=")
        #expect(pair.fingerprint == "5e352bd38b5a3659")
        let key = try pair.openKey(sealedBase64: sealed)
        #expect(key == (try ActivationKey(input: "K7M2-9XQP-4TFB")))
    }

    @Test func otherMachineCannotOpen() {
        let other = PairKeyPair()
        #expect(throws: PanelLinkError.self) { try other.openKey(sealedBase64: sealed) }
    }

    @Test func tamperedPackageFails() throws {
        var bytes = [UInt8](Data(base64Encoded: sealed)!)
        bytes[bytes.count - 1] ^= 1
        let pair = try PairKeyPair(rawPrivateKey: privateKey)
        #expect(throws: PanelLinkError.self) {
            try pair.openKey(sealedBase64: Data(bytes).base64EncodedString())
        }
    }
}
