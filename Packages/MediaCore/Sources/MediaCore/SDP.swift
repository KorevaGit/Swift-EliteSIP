import Foundation

/// Описание сессии по RFC 4566 — тело INVITE и 200 OK.
///
/// Модель осознанно неполная: из всех типов строк реализованы те, что реально
/// присылает Asterisk и что нужно нам. Незнакомые строки не теряются, а
/// складываются в `unknownLines` — так их видно при отладке, и они не мешают
/// разбору остального.
public struct SessionDescription: Sendable, Hashable {

    public struct Origin: Sendable, Hashable {
        public var username: String
        public var sessionID: UInt64
        public var sessionVersion: UInt64
        public var networkType: String
        public var addressType: String
        public var address: String

        public init(
            username: String = "-",
            sessionID: UInt64,
            sessionVersion: UInt64 = 1,
            networkType: String = "IN",
            addressType: String = "IP4",
            address: String
        ) {
            self.username = username
            self.sessionID = sessionID
            self.sessionVersion = sessionVersion
            self.networkType = networkType
            self.addressType = addressType
            self.address = address
        }
    }

    public struct Connection: Sendable, Hashable {
        public var networkType: String
        public var addressType: String
        public var address: String

        public init(networkType: String = "IN", addressType: String = "IP4", address: String) {
            self.networkType = networkType
            self.addressType = addressType
            self.address = address
        }
    }

    public struct Attribute: Sendable, Hashable {
        public var name: String
        public var value: String?

        public init(name: String, value: String? = nil) {
            self.name = name
            self.value = value
        }
    }

    public var origin: Origin
    public var sessionName: String
    public var connection: Connection?
    public var startTime: UInt64
    public var stopTime: UInt64
    public var attributes: [Attribute]
    public var media: [MediaDescription]
    public var unknownLines: [String]

    public init(
        origin: Origin,
        sessionName: String = "EliteSIP",
        connection: Connection? = nil,
        startTime: UInt64 = 0,
        stopTime: UInt64 = 0,
        attributes: [Attribute] = [],
        media: [MediaDescription] = [],
        unknownLines: [String] = []
    ) {
        self.origin = origin
        self.sessionName = sessionName
        self.connection = connection
        self.startTime = startTime
        self.stopTime = stopTime
        self.attributes = attributes
        self.media = media
        self.unknownLines = unknownLines
    }

    /// Первая аудио-секция. Видео у нас нет, так что это и есть «медиа».
    public var audio: MediaDescription? {
        media.first { $0.type == "audio" }
    }

    public static let contentType = "application/sdp"
}

/// Секция `m=` с относящимися к ней строками.
public struct MediaDescription: Sendable, Hashable {

    public var type: String
    public var port: UInt16
    public var protocolName: String
    /// Payload type'ы в порядке предпочтения отправителя. Порядок значим.
    public var formats: [UInt8]
    public var connection: SessionDescription.Connection?
    public var attributes: [SessionDescription.Attribute]

    public init(
        type: String = "audio",
        port: UInt16,
        protocolName: String = "RTP/AVP",
        formats: [UInt8] = [],
        connection: SessionDescription.Connection? = nil,
        attributes: [SessionDescription.Attribute] = []
    ) {
        self.type = type
        self.port = port
        self.protocolName = protocolName
        self.formats = formats
        self.connection = connection
        self.attributes = attributes
    }

    // MARK: - Атрибуты

    public func attribute(_ name: String) -> String? {
        attributes.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public func hasAttribute(_ name: String) -> Bool {
        attributes.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// `a=rtpmap:0 PCMU/8000` → [0: RTPMap(...)].
    public var rtpMaps: [UInt8: RTPMap] {
        var result: [UInt8: RTPMap] = [:]
        for attribute in attributes where attribute.name.caseInsensitiveCompare("rtpmap") == .orderedSame {
            guard let value = attribute.value, let map = RTPMap(value) else { continue }
            result[map.payloadType] = map
        }
        return result
    }

    /// Направление потока. Отсутствие атрибута означает sendrecv (RFC 4566 §6).
    public var direction: MediaDirection {
        for candidate in MediaDirection.allCases where hasAttribute(candidate.rawValue) {
            return candidate
        }
        return .sendrecv
    }

    public var packetTimeMilliseconds: Int? {
        attribute("ptime").flatMap { Int($0) }
    }

    /// Все корректные предложения SDES в порядке отправителя.
    public var sdesCryptoAttributes: [SDESCryptoAttribute] {
        attributes.compactMap { attribute in
            guard attribute.name.caseInsensitiveCompare("crypto") == .orderedSame,
                  let value = attribute.value
            else {
                return nil
            }
            return SDESCryptoAttribute(value)
        }
    }
}

/// `a=sendrecv` и родственники. Нужны не для красоты: удержание вызова в M4 —
/// это re-INVITE со сменой направления, а не отдельная команда SIP.
public enum MediaDirection: String, Sendable, Hashable, CaseIterable {
    case sendrecv
    case sendonly
    case recvonly
    case inactive

    /// Что нам делать с направлением собеседника при ответе.
    public var reversed: MediaDirection {
        switch self {
        case .sendrecv: .sendrecv
        case .sendonly: .recvonly
        case .recvonly: .sendonly
        case .inactive: .inactive
        }
    }

    public var receivesAudio: Bool {
        self == .sendrecv || self == .recvonly
    }

    public var sendsAudio: Bool {
        self == .sendrecv || self == .sendonly
    }
}

/// `a=rtpmap:101 telephone-event/8000`.
public struct RTPMap: Sendable, Hashable {

    public var payloadType: UInt8
    public var encodingName: String
    public var clockRate: UInt32
    public var channels: Int?

    public init(payloadType: UInt8, encodingName: String, clockRate: UInt32, channels: Int? = nil) {
        self.payloadType = payloadType
        self.encodingName = encodingName
        self.clockRate = clockRate
        self.channels = channels
    }

    public init?(_ value: some StringProtocol) {
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, let payloadType = UInt8(parts[0]) else { return nil }

        let encoding = parts[1].split(separator: "/", omittingEmptySubsequences: true)
        guard encoding.count >= 2, let clockRate = UInt32(encoding[1]) else { return nil }

        self.payloadType = payloadType
        self.encodingName = String(encoding[0])
        self.clockRate = clockRate
        self.channels = encoding.count > 2 ? Int(encoding[2]) : nil
    }

    public var value: String {
        var result = "\(payloadType) \(encodingName)/\(clockRate)"
        if let channels {
            result += "/\(channels)"
        }
        return result
    }

    /// Соответствует ли этот rtpmap нашему кодеку.
    public func matches(_ codec: AudioCodec) -> Bool {
        encodingName.caseInsensitiveCompare(codec.sdpName) == .orderedSame
            && clockRate == codec.rtpClockRate
    }

    public var isTelephoneEvent: Bool {
        encodingName.caseInsensitiveCompare(TelephoneEvent.sdpName) == .orderedSame
    }
}
