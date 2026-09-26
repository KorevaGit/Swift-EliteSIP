import CryptoKit
import Foundation
import Testing
@testable import PanelLink

/// Конфигурация машины, собранная **настоящим Spark на Go** (`sealConfig`):
/// подпись ключом с семенем 0x42×32, шифрование под пару машины ниже.
/// Разойдутся стороны — разойдётся здесь, а не на машине сотрудника.
enum ConfigFixture {
    static let installationID = "4def1c28841b17be078d88f914636d04"
    static let machinePrivateKey = Data(base64Encoded: "Vtctr55SzoqzVft7pbbq8occ4/470abouqHP6gH1aC8=")!

    static let publicKey = try! Curve25519.Signing.PublicKey(
        rawRepresentation: Data(base64Encoded: "IVL40Zt5HSRFMkLhXy6rbLfP+ntqXtMAl5YOBpiB2xI=")!)

    static let config = Data(base64Encoded: """
        eyJwYXlsb2FkIjoiZXlKbWIzSnRZWFFpT2pFc0ltbHVjM1JoYkd4aGRHbHZibDlwWkNJNklqUmtaV1l4WXpJNE9EUXhZakUzWW1Vd056aGtPRG\
        htT1RFME5qTTJaREEwSWl3aWNtVjJhWE5wYjI0aU9qTXNJbWx6YzNWbFpGOWhkQ0k2SWpJd01qWXRNRGt0TWpaVU1USTZNREE2TURCYUlpd2lj\
        MlZoYkdWa0lqb2lOMnRzYjFJd2VEaEtWa1p4VmpKV2RrVXZUakZqWWpkcU5GSlJjRmhpZGpGdlRDdHVjazlrUjNoRlJrOU9Ua0oyWlhWVk1HUX\
        lSVGxDTVV4NFRWUkNLMlpYTW1kWlJYZGtiVXhvTW5Gb1NEVk5ZWEZpZEVSNVFUbEpjMUpHTmxob1NHdHhRMWh0UVN0b1RscHNNREJ6YzJaaFdu\
        UmxZMWh6VjB0UE5VSTBPRlV4TldGaFlYUlhhbkJoVFZVclZIaE1lRXB2YlVwc2VYaDFhemszYVU1dFJWTnlXVFZEVG5CWlpGUlVhVkEzTUhwT1\
        dWaFlTakpWVjA5Q1ZtdE9jalpaYlhsUVNpOHhVbTh4V1hCT1luQkVLMFpVVG1kVE1YTnlRbUZ0YjJSVWJtbGFTRE1yY0hSdFlUTnZlR3h6TUhj\
        NVRUY3dOVVJZSzBwbE5XMWljaXRFUjFGMVpqTXdNR05YYjJwS05uRjJZa2wxU0VzeU0zSm5VVmhhYUVoUGNISTBZV05WWmxaWFZYVTNNbWhhS3\
        pnNGNHUmtieXRQVFhNMVFXSmxZMlprVjI5WmFqVXhaMnRxTUhOeFVFOXFaWGhEYmxWa2VsWmlSMDkxTmtKVVZYWmpUV3RQVjJSMWFEUTlJbjA9\
        Iiwic2lnbmF0dXJlIjoiUkVlWXE1V2JxT0ptV2R6ZU9zK2NsVmlXa0ZidUIwYmpwN0t6NUIvMEF0ZFRIQzZXZmpGVGN6UEU3dC9GNHRQNkhNNX\
        N0UHN3U1kwaytDbHZCczM0Q1E9PSJ9
        """.replacingOccurrences(of: "\n", with: ""))!
}

@Suite("Пара ключей машины")
struct MachineKeyPairTests {

    @Test("открытая часть и отпечаток совпадают с тем, что знает Spark")
    func publicKeyAndFingerprint() throws {
        let pair = try MachineKeyPair(rawPrivateKey: ConfigFixture.machinePrivateKey)
        #expect(pair.publicKeyBase64 == "gVTpg5FyhfKjlaW2HGMVzVHtVAT1Cnp12hm2DNF6A28=")
        #expect(pair.fingerprint == "5e352bd38b5a3659")
        #expect(try MachineKeyPair(rawPrivateKey: pair.rawPrivateKey).publicKeyBase64 == pair.publicKeyBase64)
    }

    @Test("ключ канала: 43 знака base64url, хеш — SHA-256 hex")
    func channelKey() {
        let key = ChannelKey.generate()
        #expect(key.count == 43)
        #expect(!key.contains("+") && !key.contains("/") && !key.contains("="))
        #expect(ChannelKey.hash("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(ChannelKey.generate() != key)
    }
}

@Suite("Конфигурация машины")
struct MachineConfigTests {

    @Test("конфигурация от Spark проверяется и расшифровывается")
    func opensSparkConfig() throws {
        let pair = try MachineKeyPair(rawPrivateKey: ConfigFixture.machinePrivateKey)
        let config = try MachineConfig.verified(ConfigFixture.config, publicKey: ConfigFixture.publicKey,
                                                installationID: ConfigFixture.installationID, keyPair: pair)
        #expect(config.revision == 3)
        #expect(config.employee == "Смирнов П.")
        #expect(config.number == "172")
        #expect(config.sipPassword == "sip-пароль")
        #expect(config.workFormat == "remote")
        #expect(config.presetID == "6D1F5A20-0000-4000-8000-000000000001")
        #expect(config.presetName == "Менеджер")
        #expect(config.adminPassword == "")
    }

    @Test("чужая машина не расшифрует")
    func otherMachineCannotOpen() {
        #expect(throws: PanelLinkError.configDidNotOpen) {
            try MachineConfig.verified(ConfigFixture.config, publicKey: ConfigFixture.publicKey,
                                       installationID: ConfigFixture.installationID, keyPair: MachineKeyPair())
        }
    }

    /// Иначе подсунутая конфигурация соседней машины увела бы эту на чужой номер.
    @Test("конфигурация чужой машины не принимается, хотя подпись сходится")
    func rejectsForeignInstallation() throws {
        let pair = try MachineKeyPair(rawPrivateKey: ConfigFixture.machinePrivateKey)
        #expect(throws: PanelLinkError.malformedBundle) {
            try MachineConfig.verified(ConfigFixture.config, publicKey: ConfigFixture.publicKey,
                                       installationID: "0000000000000000", keyPair: pair)
        }
    }

    @Test("чужой ключ подписи не подходит")
    func rejectsForeignSigner() throws {
        let pair = try MachineKeyPair(rawPrivateKey: ConfigFixture.machinePrivateKey)
        #expect(throws: PanelLinkError.signatureDidNotMatch) {
            try MachineConfig.verified(ConfigFixture.config, publicKey: Curve25519.Signing.PrivateKey().publicKey,
                                       installationID: ConfigFixture.installationID, keyPair: pair)
        }
    }

    @Test("подделанный байт ломает проверку")
    func rejectsTampered() throws {
        let pair = try MachineKeyPair(rawPrivateKey: ConfigFixture.machinePrivateKey)
        var broken = ConfigFixture.config
        broken[broken.count - 30] ^= 0x01
        #expect(throws: (any Error).self) {
            try MachineConfig.verified(broken, publicKey: ConfigFixture.publicKey,
                                       installationID: ConfigFixture.installationID, keyPair: pair)
        }
    }
}
