/// Аудиокодеки, которые предлагаем в SDP.
///
/// Только G.711 — по двум причинам. Первая: Asterisk поддерживает ulaw/alaw
/// всегда, без транскодинга и без дополнительных модулей. Вторая: кодек
/// реализуется таблицей, а не библиотекой, то есть не тянет зависимость.
/// G.722 и Opus добавляются позже отдельным кейсом, когда появится причина.
public enum AudioCodec: String, Sendable, Hashable, CaseIterable {
    /// G.711 µ-law.
    case pcmu = "PCMU"
    /// G.711 A-law.
    case pcma = "PCMA"

    /// Статический payload type по RFC 3551 — для G.711 он фиксированный,
    /// договариваться о нём в SDP не нужно.
    public var payloadType: UInt8 {
        switch self {
        case .pcmu: 0
        case .pcma: 8
        }
    }

    /// Имя для строки `a=rtpmap`.
    public var sdpName: String { rawValue }

    public var clockRate: UInt32 { 8000 }

    public var channelCount: Int { 1 }

    /// Сколько сэмплов укладывается в пакет заданной длительности.
    public func sampleCount(forPacketTime milliseconds: Int) -> Int {
        Int(clockRate) * milliseconds / 1000
    }

    /// Сколько байт занимает пакет заданной длительности.
    /// У G.711 один байт на сэмпл, но метод существует отдельно, чтобы
    /// добавление кодека с другим битрейтом не потребовало правок вызывающих.
    public func byteCount(forPacketTime milliseconds: Int) -> Int {
        sampleCount(forPacketTime: milliseconds)
    }

    public init?(staticPayloadType: UInt8) {
        switch staticPayloadType {
        case 0: self = .pcmu
        case 8: self = .pcma
        default: return nil
        }
    }
}

/// RFC 4733 telephone-event — так DTMF уезжает внутри RTP.
///
/// Это не аудиокодек: событие не несёт звук, поэтому в `AudioCodec` ему места
/// нет. Payload type динамический, 101 — то, что использует Asterisk по
/// умолчанию при `dtmfmode=rfc2833`, но в SDP его всё равно надо согласовывать.
public enum TelephoneEvent {
    public static let defaultPayloadType: UInt8 = 101
    public static let sdpName = "telephone-event"
    public static let clockRate: UInt32 = 8000

    /// Набор событий, которые может прислать или принять телефон:
    /// цифры, звёздочка, решётка и A–D.
    public static let supportedEventRange = "0-16"
}

/// Стандартная длительность RTP-пакета. 20 мс — то, что ждёт Asterisk, и
/// компромисс между задержкой и накладными расходами на заголовки.
public let defaultPacketTimeMilliseconds = 20
