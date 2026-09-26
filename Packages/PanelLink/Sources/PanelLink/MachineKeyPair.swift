import CryptoKit
import Foundation

/// Своя пара ключей машины: под её открытую часть Spark шифрует конфигурацию.
///
/// Здесь только криптография — ни сети, ни таймеров. Контракт с панелью —
/// spark.elitesochi.com/docs/elitesip-qr-pair.md:
///
///     общий    = X25519(свой закрытый, эфемерный панели)
///     ключ AES = HKDF-SHA256(общий, salt = эфемерный ‖ свой открытый,
///                            info = "elitesip.pair.v1", 32 байта)
///     шифр     = эфемерный (32) ‖ nonce (12) ‖ шифротекст ‖ тег (16), aad = "ESIPP1"
///
/// **Пара живёт всю жизнь машины**, а не одну сессию: пока ключей активации
/// не было, каждая правка места в Spark шифруется под этот же ключ. Закрытая
/// часть лежит в настройках машины (файл под 0600) и уходит только сбросом.
public struct MachineKeyPair: Sendable {

    private let privateKey: Curve25519.KeyAgreement.PrivateKey

    public init() {
        privateKey = Curve25519.KeyAgreement.PrivateKey()
    }

    /// Пара из сохранённого закрытого ключа.
    public init(rawPrivateKey: Data) throws {
        privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawPrivateKey)
    }

    /// Закрытый ключ для хранения.
    public var rawPrivateKey: Data { privateKey.rawRepresentation }

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

    /// Расшифровывает то, что Spark зашифровал под эту машину.
    public func open(_ sealed: Data) throws -> Data {
        let bytes = [UInt8](sealed)
        guard bytes.count > 32 + 12 + 16 else { throw PanelLinkError.configDidNotOpen }
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
            // Чужой ключ и битый файл — один ответ.
            throw PanelLinkError.configDidNotOpen
        }
    }
}

/// Ключ канала: им машина входит на сервер обновлений за своими объектами.
///
/// Создаётся самой машиной, и в Spark уходит только его SHA-256 — ровно то,
/// что сервер обновлений держит в machines/<id>. Сам ключ не покидает машину.
public enum ChannelKey {

    /// 32 случайных байта в base64url без выравнивания.
    public static func generate() -> String {
        let key = SymmetricKey(size: .bits256)
        let raw = key.withUnsafeBytes { Data($0) }
        return raw.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// SHA-256 ключа канала в hex — так его знает Spark.
    public static func hash(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
