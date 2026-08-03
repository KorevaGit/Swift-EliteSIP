import Foundation

/// Аудиокодеки, которые предлагаем в SDP.
///
/// G.711 — обязательный минимум: Asterisk поддерживает ulaw и alaw всегда, без
/// транскодинга и без дополнительных модулей, а сам кодек реализуется таблицей.
/// G.722 добавлен ради полосы: 50–7000 Гц вместо 300–3400 при том же битрейте.
///
/// Оговорка, которую стоит знать до того, как радоваться широкой полосе: она
/// работает только там, где широкая полоса есть на всём пути. Лид, звонящий с
/// городского номера, всё равно приедет через G.711, и Asterisk перекодирует.
/// Выигрыш достаётся внутренним звонкам и очередям.
public enum AudioCodec: String, Sendable, Hashable, CaseIterable {
    /// G.711 µ-law.
    case pcmu = "PCMU"
    /// G.711 A-law.
    case pcma = "PCMA"
    /// G.722, широкая полоса.
    case g722 = "G722"

    /// Статический payload type по RFC 3551 — для этих трёх он фиксированный,
    /// договариваться о нём в SDP не нужно.
    public var payloadType: UInt8 {
        switch self {
        case .pcmu: 0
        case .pcma: 8
        case .g722: 9
        }
    }

    /// Имя для строки `a=rtpmap`.
    public var sdpName: String { rawValue }

    /// Частота часов RTP — то, в чём считаются метки времени в пакетах.
    ///
    /// У G.722 она равна 8000, хотя звук он оцифровывает на 16 000. Это не
    /// опечатка и не наша вольность: ошибка допущена в RFC 1890 и осознанно
    /// оставлена в RFC 3551 §4.5.2 ради совместимости с уже написанным. Кто про
    /// неё не знает, наращивает метку времени вдвое быстрее нужного, и
    /// собеседник слышит либо ускоренную речь, либо тишину — в зависимости от
    /// того, насколько строг его джиттер-буфер.
    public var rtpClockRate: UInt32 { 8000 }

    /// Настоящая частота дискретизации звука. Именно она задаёт формат
    /// аудиотракта.
    public var sampleRate: UInt32 {
        switch self {
        case .pcmu, .pcma: 8000
        case .g722: 16000
        }
    }

    public var channelCount: Int { 1 }

    /// Широкая полоса — для показа в интерфейсе и в журнале.
    public var isWideband: Bool { sampleRate > 8000 }

    /// Сколько отсчётов звука укладывается в пакет заданной длительности.
    public func sampleCount(forPacketTime milliseconds: Int) -> Int {
        Int(sampleRate) * milliseconds / 1000
    }

    /// На сколько растёт метка времени RTP за один пакет.
    ///
    /// Отдельно от `sampleCount`, потому что у G.722 это разные числа: 160
    /// против 320. Смешать их — самая частая ошибка в реализациях G.722.
    public func timestampIncrement(forPacketTime milliseconds: Int) -> UInt32 {
        rtpClockRate * UInt32(milliseconds) / 1000
    }

    /// Сколько байт занимает пакет заданной длительности.
    public func byteCount(forPacketTime milliseconds: Int) -> Int {
        switch self {
        case .pcmu, .pcma:
            // Байт на отсчёт.
            sampleCount(forPacketTime: milliseconds)
        case .g722:
            // Байт на пару отсчётов: шесть бит нижней полосы плюс два верхней.
            sampleCount(forPacketTime: milliseconds) / 2
        }
    }

    public init?(staticPayloadType: UInt8) {
        switch staticPayloadType {
        case 0: self = .pcmu
        case 8: self = .pcma
        case 9: self = .g722
        default: return nil
        }
    }
}

// MARK: - Кодирование

/// Кодер разговора.
///
/// Существует затем, чтобы разница между кодеками без состояния (G.711) и с
/// состоянием (G.722) не расползлась по аудиотракту. Экземпляр принадлежит
/// одному разговору и одному потоку: у G.722 предсказатель обязан идти ровно по
/// той же траектории, что у собеседника, и параллельный доступ эту траекторию
/// ломает.
public struct AudioFrameEncoder {

    public let codec: AudioCodec
    private var g722 = G722.Encoder()

    public init(codec: AudioCodec) {
        self.codec = codec
    }

    public mutating func encode(_ samples: [Int16]) -> Data {
        switch codec {
        case .pcmu, .pcma:
            G711.encode(samples, as: codec)
        case .g722:
            Data(g722.encode(samples))
        }
    }
}

/// Декодер разговора. Всё, что сказано про кодер, верно и здесь.
public struct AudioFrameDecoder {

    public let codec: AudioCodec
    private var g722 = G722.Decoder()

    public init(codec: AudioCodec) {
        self.codec = codec
    }

    public mutating func decode(_ payload: Data) -> [Int16] {
        switch codec {
        case .pcmu, .pcma:
            G711.decode(payload, as: codec)
        case .g722:
            g722.decode([UInt8](payload))
        }
    }
}

public extension AudioCodec {

    /// Молчащий кадр в этом кодеке.
    ///
    /// Нужен ровно в одном месте — на первую же дыру, когда повторять ещё
    /// нечего. У G.711 это таблица, у G.722 приходится честно закодировать
    /// нули: постоянного «байта тишины» у него нет, состояние в начале потока
    /// известно, и результат получается воспроизводимым.
    func silencePayload(forPacketTime milliseconds: Int) -> Data {
        switch self {
        case .pcmu, .pcma:
            return Data(
                repeating: G711.silenceByte(for: self),
                count: byteCount(forPacketTime: milliseconds)
            )
        case .g722:
            var encoder = AudioFrameEncoder(codec: self)
            return encoder.encode(
                [Int16](repeating: 0, count: sampleCount(forPacketTime: milliseconds))
            )
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
