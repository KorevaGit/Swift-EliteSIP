import Foundation

/// Итог согласования: всё, что нужно медиа-слою, чтобы начать говорить.
public struct NegotiatedMedia: Sendable, Hashable {
    public var codec: AudioCodec
    public var payloadType: UInt8
    /// Payload type для DTMF, если собеседник его подтвердил.
    public var telephoneEventPayloadType: UInt8?
    public var remoteAddress: String
    public var remotePort: UInt16
    /// Направление С НАШЕЙ точки зрения.
    public var direction: MediaDirection
    public var packetTimeMilliseconds: Int
    public var security: MediaSecurity

    public init(
        codec: AudioCodec,
        payloadType: UInt8,
        telephoneEventPayloadType: UInt8? = nil,
        remoteAddress: String,
        remotePort: UInt16,
        direction: MediaDirection = .sendrecv,
        packetTimeMilliseconds: Int = defaultPacketTimeMilliseconds,
        security: MediaSecurity = .none
    ) {
        self.codec = codec
        self.payloadType = payloadType
        self.telephoneEventPayloadType = telephoneEventPayloadType
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.direction = direction
        self.packetTimeMilliseconds = packetTimeMilliseconds
        self.security = security
    }

    /// Поток отключён целиком: отправлять физически некуда.
    ///
    /// Нулевой порт и адрес `0.0.0.0` — старая запись удержания из RFC 2543, и
    /// chan_sip до сих пор шлёт именно её, иногда вообще не трогая направление.
    /// Отличать её от нового `a=sendonly` приходится вот зачем: на этот адрес
    /// нельзя пересобирать сокет, его надо просто переждать.
    public var isStreamDisabled: Bool {
        remotePort == 0 || remoteAddress == "0.0.0.0"
    }

    /// Собеседник поставил нас на удержание: звука от нас больше не ждут.
    ///
    /// Заметить это важнее, чем кажется: если пропустить, оператор продолжит
    /// говорить в линию, где его никто не слышит, и узнает об этом только по
    /// недоумению собеседника после возврата.
    public var isHeld: Bool {
        isStreamDisabled || !direction.sendsAudio
    }
}

public enum SDPNegotiationError: Error, Sendable, Equatable, CustomStringConvertible {
    case noAudioSection
    case noCommonCodec(offered: [UInt8])
    case noRemoteAddress
    case secureMediaRequired
    case missingCryptoAttribute
    case cryptoTagMismatch
    case unsupportedMediaProtocol(String)

    public var description: String {
        switch self {
        case .noAudioSection:
            "в SDP нет аудио-секции"
        case .noCommonCodec(let offered):
            "нет общего кодека, предложены payload type: \(offered.map(String.init).joined(separator: ", "))"
        case .noRemoteAddress:
            "в SDP не указан адрес для медиа"
        case .secureMediaRequired:
            "сервер не подтвердил обязательный SRTP"
        case .missingCryptoAttribute:
            "в защищённом SDP нет поддерживаемого атрибута a=crypto"
        case .cryptoTagMismatch:
            "сервер выбрал неизвестное предложение a=crypto"
        case .unsupportedMediaProtocol(let name):
            "неподдерживаемый протокол медиа \(name)"
        }
    }
}

public enum MediaSecurityPolicy: Sendable, Hashable {
    case none
    case sdesRequired
}

/// Составление предложения и разбор ответа по RFC 3264.
public enum SDPNegotiator {

    /// Кодеки, которые предлагаем по умолчанию, в порядке предпочтения.
    ///
    /// G.722 первым: он единственный здесь широкополосный, а Asterisk выбирает
    /// первый из списка, который умеет сам. Если разговор уходит в город, G.722
    /// всё равно не переживёт стык с телефонной сетью, и Asterisk молча
    /// согласится на G.711 — потерять от этой попытки нечего.
    ///
    /// PCMU перед PCMA потому, что так настроен боевой пир.
    public static let defaultCodecs: [AudioCodec] = [.g722, .pcmu, .pcma]

    /// Кодеки без широкой полосы. Пригодится, когда понадобится заставить
    /// разговор идти узкой полосой, не трогая остальную настройку.
    public static let narrowbandCodecs: [AudioCodec] = [.pcmu, .pcma]

    /// Наше предложение.
    ///
    /// Порядок кодеков — это порядок предпочтения, и отвечающая сторона обычно
    /// его уважает. PCMU первым потому, что так настроен боевой пир.
    public static func makeOffer(
        address: String,
        port: UInt16,
        codecs: [AudioCodec] = defaultCodecs,
        telephoneEventPayloadType: UInt8? = TelephoneEvent.defaultPayloadType,
        direction: MediaDirection = .sendrecv,
        sessionID: UInt64 = UInt64(Date().timeIntervalSince1970),
        sessionVersion: UInt64 = 1,
        packetTimeMilliseconds: Int = defaultPacketTimeMilliseconds,
        security: MediaSecurityPolicy = .none
    ) -> SessionDescription {
        var formats = codecs.map(\.payloadType)
        var attributes: [SessionDescription.Attribute] = codecs.map {
            .init(name: "rtpmap", value: RTPMap(
                payloadType: $0.payloadType,
                encodingName: $0.sdpName,
                clockRate: $0.rtpClockRate
            ).value)
        }

        if let eventType = telephoneEventPayloadType {
            formats.append(eventType)
            attributes.append(.init(name: "rtpmap", value: RTPMap(
                payloadType: eventType,
                encodingName: TelephoneEvent.sdpName,
                clockRate: TelephoneEvent.clockRate
            ).value))
            // fmtp обязателен: без него часть серверов не понимает, какие
            // события мы умеем принимать, и отбрасывает DTMF.
            attributes.append(.init(name: "fmtp", value: "\(eventType) \(TelephoneEvent.supportedEventRange)"))
        }

        attributes.append(.init(name: "ptime", value: String(packetTimeMilliseconds)))
        attributes.append(.init(name: direction.rawValue))

        let protocolName: String
        switch security {
        case .none:
            protocolName = "RTP/AVP"
        case .sdesRequired:
            protocolName = "RTP/SAVP"
            attributes.append(.init(
                name: "crypto",
                value: SDESCryptoAttribute(key: .random()).value
            ))
        }

        return SessionDescription(
            origin: .init(sessionID: sessionID, sessionVersion: sessionVersion, address: address),
            connection: .init(address: address),
            media: [
                MediaDescription(
                    port: port,
                    protocolName: protocolName,
                    formats: formats,
                    attributes: attributes
                )
            ]
        )
    }

    /// Повторное предложение внутри уже идущего разговора.
    ///
    /// Строится правкой прежнего описания, а не сборкой нового, и это
    /// принципиально. Порт менять нельзя — он объявлен и занят. Ключ SDES
    /// перевыпускать нельзя — по нему собеседник расшифровывает наш поток, и
    /// новый ключ означает пересборку контекстов на обеих сторонах ради смены
    /// одной строчки направления. Набор кодеков менять тоже незачем: договорились
    /// один раз.
    ///
    /// Расти обязана только версия сессии в `o=`: по ней принимающая сторона
    /// понимает, что описание новое. Неизменная версия — законный повод
    /// проигнорировать предложение целиком (RFC 3264 §8), и Asterisk этим
    /// правом пользуется.
    public static func makeReoffer(
        from previous: SessionDescription,
        direction: MediaDirection
    ) -> SessionDescription {
        var reoffer = previous
        reoffer.origin.sessionVersion &+= 1

        reoffer.media = previous.media.map { section in
            guard section.type == "audio" else { return section }
            var updated = section
            updated.attributes.removeAll { attribute in
                MediaDirection.allCases.contains { $0.rawValue == attribute.name.lowercased() }
            }
            updated.attributes.append(.init(name: direction.rawValue))
            return updated
        }

        return reoffer
    }

    /// Разбирает ответ на наше предложение.
    public static func resolveAnswer(
        _ answer: SessionDescription,
        toOffer offer: SessionDescription,
        supported: [AudioCodec] = defaultCodecs
    ) throws -> NegotiatedMedia {
        guard let audio = answer.audio else { throw SDPNegotiationError.noAudioSection }

        guard let address = audio.connection?.address ?? answer.connection?.address else {
            throw SDPNegotiationError.noRemoteAddress
        }

        // Кодек выбираем по порядку ОТВЕТА: отвечающая сторона говорит, чем она
        // будет пользоваться, и навязывать ей свой порядок нельзя.
        let maps = audio.rtpMaps
        var chosen: (AudioCodec, UInt8)?
        for format in audio.formats {
            // Статические payload type (0 и 8) можно опознать без rtpmap —
            // RFC 3551 закрепляет их жёстко, и chan_sip иногда rtpmap не шлёт.
            if let map = maps[format] {
                if let codec = supported.first(where: { map.matches($0) }) {
                    chosen = (codec, format)
                    break
                }
            } else if let codec = AudioCodec(staticPayloadType: format), supported.contains(codec) {
                chosen = (codec, format)
                break
            }
        }

        guard let (codec, payloadType) = chosen else {
            throw SDPNegotiationError.noCommonCodec(offered: audio.formats)
        }

        let eventType = audio.formats.first { format in
            maps[format]?.isTelephoneEvent == true
        }

        // Наше направление — это встречное к тому, что объявил собеседник,
        // пересечённое с тем, что мы просили в предложении.
        let offeredDirection = offer.audio?.direction ?? .sendrecv
        let direction = intersect(ours: offeredDirection, theirs: audio.direction)
        let security = try resolveSecurity(answer: audio, offer: offer.audio)

        return NegotiatedMedia(
            codec: codec,
            payloadType: payloadType,
            telephoneEventPayloadType: eventType,
            remoteAddress: address,
            remotePort: audio.port,
            direction: direction,
            packetTimeMilliseconds: audio.packetTimeMilliseconds ?? defaultPacketTimeMilliseconds,
            security: security
        )
    }

    /// Составляет ответ на чужое предложение и заодно возвращает итог.
    /// - Parameter localKey: наш ключ SRTP. Задаётся при пересогласовании: в
    ///   ответе на повторный INVITE ключ обязан остаться прежним, иначе поток
    ///   придётся пересобирать на каждое удержание.
    public static func makeAnswer(
        to offer: SessionDescription,
        address: String,
        port: UInt16,
        supported: [AudioCodec] = defaultCodecs,
        sessionID: UInt64 = UInt64(Date().timeIntervalSince1970),
        packetTimeMilliseconds: Int = defaultPacketTimeMilliseconds,
        localKey: SRTPMasterKey? = nil
    ) throws -> (answer: SessionDescription, media: NegotiatedMedia) {
        guard let audio = offer.audio else { throw SDPNegotiationError.noAudioSection }
        guard let remoteAddress = audio.connection?.address ?? offer.connection?.address else {
            throw SDPNegotiationError.noRemoteAddress
        }

        let maps = audio.rtpMaps
        var chosen: (AudioCodec, UInt8)?
        for format in audio.formats {
            if let map = maps[format], let codec = supported.first(where: { map.matches($0) }) {
                chosen = (codec, format)
                break
            }
            if maps[format] == nil, let codec = AudioCodec(staticPayloadType: format), supported.contains(codec) {
                chosen = (codec, format)
                break
            }
        }
        guard let (codec, payloadType) = chosen else {
            throw SDPNegotiationError.noCommonCodec(offered: audio.formats)
        }

        let eventType = audio.formats.first { maps[$0]?.isTelephoneEvent == true }
        let direction = audio.direction.reversed

        var attributes: [SessionDescription.Attribute] = [
            .init(name: "rtpmap", value: RTPMap(
                payloadType: payloadType,
                encodingName: codec.sdpName,
                clockRate: codec.rtpClockRate
            ).value)
        ]
        var formats = [payloadType]

        if let eventType {
            formats.append(eventType)
            attributes.append(.init(name: "rtpmap", value: RTPMap(
                payloadType: eventType,
                encodingName: TelephoneEvent.sdpName,
                clockRate: TelephoneEvent.clockRate
            ).value))
            attributes.append(.init(name: "fmtp", value: "\(eventType) \(TelephoneEvent.supportedEventRange)"))
        }

        attributes.append(.init(name: "ptime", value: String(packetTimeMilliseconds)))
        attributes.append(.init(name: direction.rawValue))

        let protocolName: String
        let security: MediaSecurity
        switch audio.protocolName.uppercased() {
        case "RTP/AVP":
            protocolName = "RTP/AVP"
            security = .none
        case "RTP/SAVP":
            guard let remoteCrypto = audio.sdesCryptoAttributes.first else {
                throw SDPNegotiationError.missingCryptoAttribute
            }
            let key = localKey ?? SRTPMasterKey.random()
            attributes.append(.init(
                name: "crypto",
                value: SDESCryptoAttribute(tag: remoteCrypto.tag, suite: remoteCrypto.suite, key: key).value
            ))
            protocolName = "RTP/SAVP"
            security = .sdes(local: key, remote: remoteCrypto.key)
        default:
            throw SDPNegotiationError.unsupportedMediaProtocol(audio.protocolName)
        }

        let answer = SessionDescription(
            origin: .init(sessionID: sessionID, address: address),
            connection: .init(address: address),
            media: [
                MediaDescription(
                    port: port,
                    protocolName: protocolName,
                    formats: formats,
                    attributes: attributes
                )
            ]
        )

        let media = NegotiatedMedia(
            codec: codec,
            payloadType: payloadType,
            telephoneEventPayloadType: eventType,
            remoteAddress: remoteAddress,
            remotePort: audio.port,
            direction: direction,
            packetTimeMilliseconds: audio.packetTimeMilliseconds ?? packetTimeMilliseconds,
            security: security
        )

        return (answer, media)
    }

    /// Пересечение направлений двух сторон.
    ///
    /// Если мы просили только слушать, а собеседник только слушает, говорить
    /// некому — получается inactive. Эта таблица и есть логика удержания.
    static func intersect(ours: MediaDirection, theirs: MediaDirection) -> MediaDirection {
        let weSend = ours.sendsAudio && theirs.receivesAudio
        let weReceive = ours.receivesAudio && theirs.sendsAudio

        return switch (weSend, weReceive) {
        case (true, true): .sendrecv
        case (true, false): .sendonly
        case (false, true): .recvonly
        case (false, false): .inactive
        }
    }

    private static func resolveSecurity(
        answer: MediaDescription,
        offer: MediaDescription?
    ) throws -> MediaSecurity {
        guard let offer else { throw SDPNegotiationError.noAudioSection }

        switch offer.protocolName.uppercased() {
        case "RTP/AVP":
            guard answer.protocolName.caseInsensitiveCompare("RTP/AVP") == .orderedSame else {
                throw SDPNegotiationError.unsupportedMediaProtocol(answer.protocolName)
            }
            return .none

        case "RTP/SAVP":
            guard answer.protocolName.caseInsensitiveCompare("RTP/SAVP") == .orderedSame else {
                throw SDPNegotiationError.secureMediaRequired
            }
            guard let localCrypto = offer.sdesCryptoAttributes.first,
                  let remoteCrypto = answer.sdesCryptoAttributes.first
            else {
                throw SDPNegotiationError.missingCryptoAttribute
            }
            guard localCrypto.tag == remoteCrypto.tag, localCrypto.suite == remoteCrypto.suite else {
                throw SDPNegotiationError.cryptoTagMismatch
            }
            return .sdes(local: localCrypto.key, remote: remoteCrypto.key)

        default:
            throw SDPNegotiationError.unsupportedMediaProtocol(offer.protocolName)
        }
    }
}
