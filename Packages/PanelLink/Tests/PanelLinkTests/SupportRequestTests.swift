import CryptoKit
import Foundation
import Testing
@testable import PanelLink

@Suite("Запрос архива для техподдержки")
struct SupportRequestTests {

    static let requestID = "0123456789abcdef0123456789abcdef"
    static let installationID = "6D1F5A20-0000-4000-8000-0000000000AA"
    static let signer = Curve25519.Signing.PrivateKey()

    private func envelope(_ payload: String, key: Curve25519.Signing.PrivateKey = signer) throws -> Data {
        let bytes = Data(payload.utf8)
        let signature = try key.signature(for: bytes)
        return try JSONSerialization.data(withJSONObject: [
            "payload": bytes.base64EncodedString(),
            "signature": signature.base64EncodedString(),
        ])
    }

    private func payload(installationID: String = installationID, requestID: String = requestID) -> String {
        """
        {"format":1,"installation_id":"\(installationID)","request_id":"\(requestID)",\
        "requested_at":"2026-11-24T09:00:00Z","expires_at":"2026-11-25T09:00:00Z"}
        """
    }

    @Test("подписанный запрос разбирается")
    func verifies() throws {
        let request = try SupportRequest.verified(envelope(payload()), publicKey: Self.signer.publicKey,
                                                  installationID: Self.installationID)
        #expect(request.requestID == Self.requestID)
        #expect(request.expiresAt == ISO8601DateFormatter().date(from: "2026-11-25T09:00:00Z"))
    }

    @Test("чужая подпись не принимается")
    func foreignSignature() throws {
        let data = try envelope(payload(), key: Curve25519.Signing.PrivateKey())
        #expect(throws: PanelLinkError.self) {
            try SupportRequest.verified(data, publicKey: Self.signer.publicKey, installationID: Self.installationID)
        }
    }

    @Test("запрос чужой машины или с негодным именем отвергается", arguments: [
        ("0000000000000000", requestID),
        (installationID, "../../etc/passwd"),
        (installationID, "0123456789ABCDEF0123456789ABCDEF"),
    ])
    func rejected(installationID: String, requestID: String) throws {
        let data = try envelope(payload(installationID: installationID, requestID: requestID))
        #expect(throws: PanelLinkError.self) {
            try SupportRequest.verified(data, publicKey: Self.signer.publicKey, installationID: Self.installationID)
        }
    }
}
