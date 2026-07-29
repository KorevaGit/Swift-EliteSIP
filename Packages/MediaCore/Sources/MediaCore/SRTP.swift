import CommonCrypto
import Foundation

/// Единственный профиль SDES, который нужен `chan_sip` Asterisk 13.
///
/// Он использует AES-128 в режиме counter для шифрования и HMAC-SHA1,
/// усечённый до 80 бит, для аутентификации каждого RTP-пакета.
public enum SRTPCryptoSuite: String, Sendable, Hashable {
    case aesCM128HMACSHA1_80 = "AES_CM_128_HMAC_SHA1_80"

    public var masterKeyByteCount: Int { 16 }
    public var masterSaltByteCount: Int { 14 }
    public var authenticationTagByteCount: Int { 10 }
}

/// 128-битный master key и 112-битный master salt в форме `inline:` из SDES.
public struct SRTPMasterKey: Sendable, Hashable {
    public static let byteCount = 30

    public let bytes: Data

    public init(bytes: Data) throws {
        guard bytes.count == Self.byteCount else {
            throw SRTPError.invalidMasterKeyLength(bytes.count)
        }
        self.bytes = bytes
    }

    public static func random() -> SRTPMasterKey {
        var generator = SystemRandomNumberGenerator()
        let bytes = Data((0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        // Длина строится здесь и известна статически.
        return try! SRTPMasterKey(bytes: bytes)
    }

    var encryptionKey: Data { bytes.prefix(16) }
    var salt: Data { bytes.dropFirst(16) }
}

/// Значение строки `a=crypto` по RFC 4568.
public struct SDESCryptoAttribute: Sendable, Hashable {
    public var tag: UInt32
    public var suite: SRTPCryptoSuite
    public var key: SRTPMasterKey

    public init(tag: UInt32 = 1, suite: SRTPCryptoSuite = .aesCM128HMACSHA1_80, key: SRTPMasterKey) {
        self.tag = tag
        self.suite = suite
        self.key = key
    }

    public init?(_ value: some StringProtocol) {
        let fields = value.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 3,
              let tag = UInt32(fields[0]),
              tag > 0,
              tag <= Int32.max,
              let suite = SRTPCryptoSuite(rawValue: String(fields[1])),
              fields[2].hasPrefix("inline:"),
              !fields[2].contains("|")
        else {
            return nil
        }

        // Lifetime, MKI и ослабляющие session parameters не поддерживаем:
        // проигнорировать их означало бы согласиться на семантику, которую
        // криптографический контекст не выполняет.
        let keyParameters = fields[2].dropFirst("inline:".count)
        guard let bytes = Data(base64Encoded: String(keyParameters)),
              let key = try? SRTPMasterKey(bytes: bytes)
        else {
            return nil
        }

        self.tag = tag
        self.suite = suite
        self.key = key
    }

    public var value: String {
        "\(tag) \(suite.rawValue) inline:\(key.bytes.base64EncodedString())"
    }
}

/// Результат согласования защиты медиа.
public enum MediaSecurity: Sendable, Hashable {
    case none
    case sdes(local: SRTPMasterKey, remote: SRTPMasterKey)

    public var isEncrypted: Bool {
        if case .sdes = self { true } else { false }
    }

    /// Наш ключ, если поток защищён.
    ///
    /// Нужен пересогласованию: отвечая на повторный INVITE, ключ надо повторить,
    /// а не выпустить новый. Новый означал бы пересборку потока на каждое
    /// удержание — со сменой SSRC и слышимым разрывом на ровном месте.
    public var localKey: SRTPMasterKey? {
        if case .sdes(let local, _) = self { local } else { nil }
    }
}

public enum SRTPError: Error, Sendable, Equatable, LocalizedError {
    case invalidMasterKeyLength(Int)
    case packetTooShort
    case malformedRTPHeader
    case authenticationFailed
    case replayedPacket
    case cryptoFailure(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidMasterKeyLength(let count):
            "Ключ SRTP должен занимать 30 байт, получено \(count)."
        case .packetTooShort:
            "Пакет SRTP короче заголовка RTP и тега аутентификации."
        case .malformedRTPHeader:
            "Повреждён заголовок защищённого RTP-пакета."
        case .authenticationFailed:
            "Пакет SRTP не прошёл проверку подлинности."
        case .replayedPacket:
            "Повторно полученный пакет SRTP отброшен."
        case .cryptoFailure(let status):
            "CommonCrypto вернул ошибку \(status)."
        }
    }
}

/// Состояние одного направления SRTP-потока по RFC 3711.
///
/// Для разговора создаются два независимых контекста: исходящий из нашего
/// ключа SDES и входящий из ключа Asterisk. Смешивать их нельзя — у направлений
/// разные ключи, rollover counter и окно защиты от повторов.
public final class SRTPContext: @unchecked Sendable {
    private let encryptionKey: Data
    private let authenticationKey: Data
    private let saltKey: Data

    private var outboundROC: UInt32 = 0
    private var lastOutboundSequence: UInt16?

    private var highestInboundIndex: UInt64?
    private var replayWindow: UInt64 = 0

    public init(masterKey: SRTPMasterKey) throws {
        let masterEncryptionKey = masterKey.encryptionKey
        let masterSalt = masterKey.salt
        encryptionKey = try Self.derive(label: 0x00, count: 16, key: masterEncryptionKey, salt: masterSalt)
        authenticationKey = try Self.derive(label: 0x01, count: 20, key: masterEncryptionKey, salt: masterSalt)
        saltKey = try Self.derive(label: 0x02, count: 14, key: masterEncryptionKey, salt: masterSalt)
    }

    /// Доступно модульным тестам с `@testable`: ключи сверяются с векторами
    /// RFC 3711, но наружу пакета ключевой материал не экспортируется.
    var derivedSessionKeys: (encryption: Data, authentication: Data, salt: Data) {
        (encryptionKey, authenticationKey, saltKey)
    }

    /// Шифрует payload, оставляя RTP-заголовок открытым, и добавляет 80-битный
    /// тег HMAC-SHA1. Индекс пакета выводится из sequence number и ROC.
    public func protect(_ packet: RTPPacket) throws -> Data {
        if let previous = lastOutboundSequence, previous > 0xC000, packet.sequenceNumber < 0x4000 {
            outboundROC &+= 1
        }
        lastOutboundSequence = packet.sequenceNumber

        let index = UInt64(outboundROC) << 16 | UInt64(packet.sequenceNumber)
        let plain = packet.encoded()
        let headerLength = try Self.rtpHeaderLength(in: plain)
        let header = plain.prefix(headerLength)
        let payload = plain.dropFirst(headerLength)
        let encryptedPayload = try crypt(Data(payload), ssrc: packet.ssrc, packetIndex: index)

        var authenticated = Data(header)
        authenticated.append(encryptedPayload)
        authenticated.append(contentsOf: Self.bigEndianBytes(outboundROC))
        let tag = Self.hmacSHA1(key: authenticationKey, message: authenticated)
            .prefix(SRTPCryptoSuite.aesCM128HMACSHA1_80.authenticationTagByteCount)

        var result = Data(header)
        result.append(encryptedPayload)
        result.append(tag)
        return result
    }

    /// Сначала проверяет HMAC и replay window, и только затем расшифровывает.
    /// Неподлинные данные никогда не попадают в RTP-парсер и аудиотракт.
    public func unprotect(_ protectedPacket: Data) throws -> RTPPacket {
        let tagLength = SRTPCryptoSuite.aesCM128HMACSHA1_80.authenticationTagByteCount
        guard protectedPacket.count >= RTPPacket.headerByteCount + tagLength else {
            throw SRTPError.packetTooShort
        }

        let authenticatedLength = protectedPacket.count - tagLength
        let encryptedPacket = protectedPacket.prefix(authenticatedLength)
        let receivedTag = protectedPacket.suffix(tagLength)
        let bytes = [UInt8](encryptedPacket)
        guard bytes.count >= RTPPacket.headerByteCount else { throw SRTPError.packetTooShort }

        let sequence = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        let ssrc = UInt32(bytes[8]) << 24
            | UInt32(bytes[9]) << 16
            | UInt32(bytes[10]) << 8
            | UInt32(bytes[11])
        let index = estimatedInboundIndex(for: sequence)
        let roc = UInt32(truncatingIfNeeded: index >> 16)

        var authenticated = Data(encryptedPacket)
        authenticated.append(contentsOf: Self.bigEndianBytes(roc))
        let expectedTag = Self.hmacSHA1(key: authenticationKey, message: authenticated).prefix(tagLength)
        guard Self.constantTimeEqual(receivedTag, expectedTag) else {
            throw SRTPError.authenticationFailed
        }
        guard !isReplay(index) else { throw SRTPError.replayedPacket }

        let headerLength = try Self.rtpHeaderLength(in: Data(encryptedPacket))
        let header = encryptedPacket.prefix(headerLength)
        let encryptedPayload = encryptedPacket.dropFirst(headerLength)
        let payload = try crypt(Data(encryptedPayload), ssrc: ssrc, packetIndex: index)

        var plain = Data(header)
        plain.append(payload)
        let packet = try RTPPacket(parsing: plain)
        accept(index)
        return packet
    }

    // MARK: - Индекс и replay protection

    private func estimatedInboundIndex(for sequence: UInt16) -> UInt64 {
        guard let highest = highestInboundIndex else { return UInt64(sequence) }
        let localSequence = UInt16(truncatingIfNeeded: highest)
        var guessedROC = UInt32(truncatingIfNeeded: highest >> 16)

        if localSequence < 0x8000 {
            if Int(sequence) - Int(localSequence) > 0x8000, guessedROC > 0 {
                guessedROC -= 1
            }
        } else if Int(localSequence) - 0x8000 > Int(sequence) {
            guessedROC &+= 1
        }
        return UInt64(guessedROC) << 16 | UInt64(sequence)
    }

    private func isReplay(_ index: UInt64) -> Bool {
        guard let highest = highestInboundIndex else { return false }
        if index > highest { return false }
        let distance = highest - index
        guard distance < 64 else { return true }
        return replayWindow & (UInt64(1) << distance) != 0
    }

    private func accept(_ index: UInt64) {
        guard let highest = highestInboundIndex else {
            highestInboundIndex = index
            replayWindow = 1
            return
        }
        guard index > highest else {
            replayWindow |= UInt64(1) << (highest - index)
            return
        }

        let shift = index - highest
        replayWindow = shift >= 64 ? 1 : (replayWindow << shift) | 1
        highestInboundIndex = index
    }

    // MARK: - RFC 3711 crypto

    private func crypt(_ input: Data, ssrc: UInt32, packetIndex: UInt64) throws -> Data {
        var iv = [UInt8](saltKey) + [0, 0]
        let ssrcBytes = Self.bigEndianBytes(ssrc)
        for offset in 0..<4 { iv[4 + offset] ^= ssrcBytes[offset] }
        for offset in 0..<6 {
            iv[8 + offset] ^= UInt8(truncatingIfNeeded: packetIndex >> UInt64((5 - offset) * 8))
        }
        return try Self.aesCTR(input, key: encryptionKey, initialCounter: iv)
    }

    private static func derive(label: UInt8, count: Int, key: Data, salt: Data) throws -> Data {
        var counter = [UInt8](salt) + [0, 0]
        counter[7] ^= label
        return try aesCTR(Data(repeating: 0, count: count), key: key, initialCounter: counter)
    }

    private static func aesCTR(_ input: Data, key: Data, initialCounter: [UInt8]) throws -> Data {
        var counter = initialCounter
        var output = [UInt8](repeating: 0, count: input.count)
        let source = [UInt8](input)
        var offset = 0

        while offset < source.count {
            let stream = try aesEncryptBlock(counter, key: key)
            let length = min(16, source.count - offset)
            for index in 0..<length {
                output[offset + index] = source[offset + index] ^ stream[index]
            }
            offset += length
            incrementCounter(&counter)
        }
        return Data(output)
    }

    private static func aesEncryptBlock(_ block: [UInt8], key: Data) throws -> [UInt8] {
        precondition(block.count == kCCBlockSizeAES128)
        var result = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        let resultCount = result.count
        var moved = 0
        let status = key.withUnsafeBytes { keyBytes in
            block.withUnsafeBytes { blockBytes in
                result.withUnsafeMutableBytes { resultBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress,
                        key.count,
                        nil,
                        blockBytes.baseAddress,
                        block.count,
                        resultBytes.baseAddress,
                        resultCount,
                        &moved
                    )
                }
            }
        }
        guard status == kCCSuccess, moved == kCCBlockSizeAES128 else {
            throw SRTPError.cryptoFailure(status)
        }
        return result
    }

    private static func hmacSHA1(key: Data, message: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        key.withUnsafeBytes { keyBytes in
            message.withUnsafeBytes { messageBytes in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA1),
                    keyBytes.baseAddress,
                    key.count,
                    messageBytes.baseAddress,
                    message.count,
                    &digest
                )
            }
        }
        return Data(digest)
    }

    private static func rtpHeaderLength(in data: Data) throws -> Int {
        let bytes = [UInt8](data)
        guard bytes.count >= RTPPacket.headerByteCount else { throw SRTPError.packetTooShort }
        guard bytes[0] >> 6 == RTPPacket.version else { throw SRTPError.malformedRTPHeader }

        var length = RTPPacket.headerByteCount + Int(bytes[0] & 0x0F) * 4
        guard bytes.count >= length else { throw SRTPError.malformedRTPHeader }
        if bytes[0] & 0x10 != 0 {
            guard bytes.count >= length + 4 else { throw SRTPError.malformedRTPHeader }
            let words = Int(UInt16(bytes[length + 2]) << 8 | UInt16(bytes[length + 3]))
            length += 4 + words * 4
            guard bytes.count >= length else { throw SRTPError.malformedRTPHeader }
        }
        return length
    }

    private static func incrementCounter(_ counter: inout [UInt8]) {
        for index in counter.indices.reversed() {
            counter[index] &+= 1
            if counter[index] != 0 { break }
        }
    }

    private static func constantTimeEqual(_ lhs: some DataProtocol, _ rhs: some DataProtocol) -> Bool {
        let left = Array(lhs)
        let right = Array(rhs)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }

    private static func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ]
    }
}
