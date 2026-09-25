import CryptoKit
import Foundation

/// Привязка по QR: машина показывает код, установщик в EliteGuard отдаёт ей
/// выпущенный ключ, Spark запечатывает его открытым ключом этой машины.
///
/// Здесь только криптография — ни сети, ни таймеров. Контракт с панелью —
/// spark.elitesochi.com/docs/elitesip-qr-pair.md:
///
///     общий    = X25519(свой закрытый, эфемерный панели)
///     ключ AES = HKDF-SHA256(общий, salt = эфемерный ‖ свой открытый,
///                            info = "elitesip.pair.v1", 32 байта)
///     пакет    = эфемерный (32) ‖ nonce (12) ‖ шифротекст ‖ тег (16), aad = "ESIPP1"
///
/// Закрытый ключ живёт только в памяти и только одну сессию: QR перевыпускается
/// каждые три минуты, и вместе с ним — пара.
public struct PairKeyPair: Sendable {

    private let privateKey: Curve25519.KeyAgreement.PrivateKey

    public init() {
        privateKey = Curve25519.KeyAgreement.PrivateKey()
    }

    /// Для тестов: пара из известного закрытого ключа.
    public init(rawPrivateKey: Data) throws {
        privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawPrivateKey)
    }

    /// Открытая часть в base64 — то, что уходит в Spark при открытии сессии.
    public var publicKeyBase64: String {
        privateKey.publicKey.rawRepresentation.base64EncodedString()
    }

    /// Отпечаток для QR: первые восемь байт SHA-256 открытого ключа в hex.
    public var fingerprint: String {
        SHA256.hash(data: privateKey.publicKey.rawRepresentation)
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Распечатывает ключ активации, присланный через сессию.
    public func openKey(sealedBase64: String) throws -> ActivationKey {
        guard let sealed = Data(base64Encoded: sealedBase64) else {
            throw PanelLinkError.keyDidNotOpen
        }
        let plain = try open(sealed)
        guard let text = String(data: plain, encoding: .utf8) else {
            throw PanelLinkError.keyDidNotOpen
        }
        return try ActivationKey(input: text)
    }

    func open(_ sealed: Data) throws -> Data {
        let bytes = [UInt8](sealed)
        guard bytes.count > 32 + 12 + 16 else { throw PanelLinkError.keyDidNotOpen }
        do {
            let ephemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(bytes[0..<32]))
            let shared = try privateKey.sharedSecretFromKeyAgreement(with: ephemeral)
            let salt = ephemeral.rawRepresentation + privateKey.publicKey.rawRepresentation
            let key = shared.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: salt,
                sharedInfo: Data("elitesip.pair.v1".utf8),
                outputByteCount: 32)
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: Data(bytes[32..<44])),
                ciphertext: Data(bytes[44..<(bytes.count - 16)]),
                tag: Data(bytes[(bytes.count - 16)...]))
            return try AES.GCM.open(box, using: key, authenticating: Data("ESIPP1".utf8))
        } catch {
            // Как и у пакета активации: чужой ключ и битый файл — один ответ.
            throw PanelLinkError.keyDidNotOpen
        }
    }
}
