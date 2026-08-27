import CryptoKit
import Foundation
import Testing
@testable import PanelLink

/// Помашинные объекты, собранные **настоящей панелью на Go**.
///
/// Перевыпускаются `go run ./cmd/fixtures` в `elitesupport`. Разойдутся
/// стороны — разойдётся здесь, а не на машине, которую сбросили не вовремя.
enum MachineFixture {
    static let installationID = "8f2c4a1b9d3e5f60"

    static let publicKey = try! Curve25519.Signing.PublicKey(
        rawRepresentation: Data(base64Encoded: "A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=")!)

    static let access = Data(base64Encoded: """
        eyJwYXlsb2FkIjoiZXlKbWIzSnRZWFFpT2pFc0ltbHVjM1JoYkd4aGRHbHZibDlwWkNJNklqaG1NbU0wWVRGaU9XUXpaVFZtTmpBaUxDSndjbV\
        Z6WlhSZmFXUWlPaUkyUkRGR05VRXlNQzB3TURBd0xUUXdNREF0T0RBd01DMHdNREF3TURBd01EQXdNREVpTENKaFpHMXBibDl3WVhOemQyOXla\
        Q0k2SXRDLzBMRFJnTkMrMEx2UmpDM1F2OUdBMExYUXROR0QwWUhSZ3RDdzBMM1F2dEN5MExyUXVDSXNJbWx6YzNWbFpGOWhkQ0k2SWpJd01qWX\
        RNRGd0TWpWVU1USTZNREE2TURCYUluMD0iLCJzaWduYXR1cmUiOiJURDlRR0M2TG1HM21uanp1UHJKUDY5blpab0RaNGw1T1NEc29sdDVrejVx\
        Nm1aZkpsNk9sNjRDY05mL3FDRVRJRkRJSmtuNVFKNXBPTXFxQVlRVHZDZz09In0=
        """.replacingOccurrences(of: "\n", with: ""))!

    static let revocation = Data(base64Encoded: """
        eyJwYXlsb2FkIjoiZXlKbWIzSnRZWFFpT2pFc0ltbHVjM1JoYkd4aGRHbHZibDlwWkNJNklqaG1NbU0wWVRGaU9XUXpaVFZtTmpBaUxDSnlaWF\
        p2YTJWa1gyRjBJam9pTWpBeU5pMHdPQzB5TlZReE1qb3dNRG93TUZvaWZRPT0iLCJzaWduYXR1cmUiOiJma3lzMzNseG00UU52eURkMHJpNGp3\
        Y3hXZWJLNjZIV04vbmY2b0Jhb1k0Z3AwUmhyaXpWSytqTXJWWjhmN3J1QVRhdUQ2MkszWjczUm1WUkxCLzhEQT09In0=
        """.replacingOccurrences(of: "\n", with: ""))!
}

@Suite("Помашинный доступ")
struct MachineAccessTests {

    @Test("объект от панели проходит проверку и разбирается")
    func opensPanelObject() throws {
        let access = try MachineAccess.verified(MachineFixture.access,
                                                publicKey: MachineFixture.publicKey,
                                                installationID: MachineFixture.installationID)

        #expect(access.installationID == MachineFixture.installationID)
        #expect(access.presetID == "6D1F5A20-0000-4000-8000-000000000001")
        #expect(access.adminPassword == "пароль-предустановки")
    }

    /// Подписанный объект чужой машины — это чужой административный пароль.
    /// Принимать его молча нельзя, даже если канал его почему-то отдал.
    @Test("чужой доступ не принимается, хотя подпись сходится")
    func rejectsForeignMachine() {
        #expect(throws: PanelLinkError.malformedBundle) {
            try MachineAccess.verified(MachineFixture.access,
                                       publicKey: MachineFixture.publicKey,
                                       installationID: "0000000000000000")
        }
    }

    @Test("подделанный байт ломает проверку")
    func rejectsTampered() {
        var broken = MachineFixture.access
        broken[broken.count - 20] ^= 0x01
        #expect(throws: (any Error).self) {
            try MachineAccess.verified(broken,
                                       publicKey: MachineFixture.publicKey,
                                       installationID: MachineFixture.installationID)
        }
    }

    @Test("чужой ключ подписи не подходит")
    func rejectsForeignKey() throws {
        let stranger = Curve25519.Signing.PrivateKey().publicKey
        #expect(throws: PanelLinkError.signatureDidNotMatch) {
            try MachineAccess.verified(MachineFixture.access,
                                       publicKey: stranger,
                                       installationID: MachineFixture.installationID)
        }
    }
}

@Suite("Отзыв")
struct RevocationTests {

    @Test("отзыв от панели проходит проверку")
    func opensPanelRevocation() throws {
        let revocation = try Revocation.verified(MachineFixture.revocation,
                                                 publicKey: MachineFixture.publicKey,
                                                 installationID: MachineFixture.installationID)
        #expect(revocation.installationID == MachineFixture.installationID)
    }

    /// Сброс запускает только подписанный отзыв. Неподписанный объект — это
    /// то, что подсунет любой, кто дотянется до бакета или до сети между.
    @Test("неподписанное не сбрасывает машину")
    func rejectsUnsigned() {
        let bare = Data(#"{"format":1,"installation_id":"8f2c4a1b9d3e5f60","revoked_at":"2026-08-25T12:00:00Z"}"#.utf8)
        #expect(throws: (any Error).self) {
            try Revocation.verified(bare,
                                    publicKey: MachineFixture.publicKey,
                                    installationID: MachineFixture.installationID)
        }
    }

    /// Иначе подсунутый объект соседней машины сбрасывал бы эту.
    @Test("отзыв чужой машины не сбрасывает нашу")
    func rejectsForeignMachine() {
        #expect(throws: PanelLinkError.malformedBundle) {
            try Revocation.verified(MachineFixture.revocation,
                                    publicKey: MachineFixture.publicKey,
                                    installationID: "0000000000000000")
        }
    }
}
