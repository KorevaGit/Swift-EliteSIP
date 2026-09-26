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

    static let revocation = Data(base64Encoded: """
        eyJwYXlsb2FkIjoiZXlKbWIzSnRZWFFpT2pFc0ltbHVjM1JoYkd4aGRHbHZibDlwWkNJNklqaG1NbU0wWVRGaU9XUXpaVFZtTmpBaUxDSnlaWF\
        p2YTJWa1gyRjBJam9pTWpBeU5pMHdPQzB5TlZReE1qb3dNRG93TUZvaWZRPT0iLCJzaWduYXR1cmUiOiJma3lzMzNseG00UU52eURkMHJpNGp3\
        Y3hXZWJLNjZIV04vbmY2b0Jhb1k0Z3AwUmhyaXpWSytqTXJWWjhmN3J1QVRhdUQ2MkszWjczUm1WUkxCLzhEQT09In0=
        """.replacingOccurrences(of: "\n", with: ""))!
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
