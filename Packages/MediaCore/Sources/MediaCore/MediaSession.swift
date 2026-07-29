import Foundation
import os

/// Медиа-половина разговора: RTP, джиттер-буфер и аудиотракт вместе.
///
/// О SIP по-прежнему не знает ничего: на вход — уже согласованные параметры
/// потока, на выход — звук и статистика. Склейку с сигнализацией делает
/// приложение, и разделение слоёв от переезда сюда не пострадало.
///
/// Лежит в пакете, а не в приложении, ради проверки на живой АТС: собрать
/// разговор целиком — RTP, буфер и звуковую карту — и послушать, что получилось,
/// нужно из `sipcheck`, а тот к приложению не линкуется. Внутри приложения
/// связывание с сигнализацией так и осталось в `AppModel`.
public final class MediaSession: @unchecked Sendable {

    /// Собирает предложение SDP и занимает порт под RTP.
    ///
    /// Порт занимается ДО отправки INVITE: номер порта уходит в предложении, и
    /// узнать его потом уже негде.
    /// Возвращается сам объект предложения, а не только байты: разбор ответа
    /// сверяется с ним, чтобы понять итоговое направление потока.
    public static func makeOffer(
        localAddress: String,
        codecs: [AudioCodec] = SDPNegotiator.defaultCodecs,
        security: MediaSecurityPolicy = .none
    ) throws -> (offer: SessionDescription, port: UInt16) {
        let port = try RTPSession.reserveEvenPort()
        return (
            SDPNegotiator.makeOffer(
                address: localAddress, port: port, codecs: codecs, security: security
            ),
            port
        )
    }

    /// Отвечает на чужое предложение и занимает порт под RTP.
    ///
    /// Зеркало `makeOffer`, и порядок здесь так же обязателен: порт нужен уже в
    /// ответе. Разница в том, что выбор кодека и защиты сделан не нами —
    /// предложение задаёт рамки, а мы в них укладываемся.
    ///
    /// Политика защиты проверяется отдельно от согласования: `sdesRequired`
    /// означает, что открытое предложение надо отклонить звонком, а не принять
    /// молча. Незаметный откат на открытый RTP на TLS-профиле — это ровно то,
    /// от чего защищались в M2b.
    public static func makeAnswer(
        to offer: SessionDescription,
        localAddress: String,
        codecs: [AudioCodec] = SDPNegotiator.defaultCodecs,
        security: MediaSecurityPolicy = .none
    ) throws -> (answer: SessionDescription, media: NegotiatedMedia, port: UInt16) {
        if security == .sdesRequired,
           offer.audio?.protocolName.caseInsensitiveCompare("RTP/SAVP") != .orderedSame {
            throw SDPNegotiationError.secureMediaRequired
        }

        let port = try RTPSession.reserveEvenPort()
        let negotiated = try SDPNegotiator.makeAnswer(
            to: offer,
            address: localAddress,
            port: port,
            supported: codecs
        )
        return (negotiated.answer, negotiated.media, port)
    }

    private let configuration: RTPSession.Configuration
    private let engine: VoiceAudioEngine
    private let rtp: RTPSession

    /// Джиттер-буфер трогают два потока: приём RTP и подача в звук.
    private let bufferLock = NSLock()
    private var jitter: JitterBuffer

    /// Обмен отчётами о качестве. Нужен ради обратной стороны: своя статистика
    /// не показывает, что происходит с нашим потоком у собеседника.
    private let rtcp: RTCPSession
    /// SSRC собеседника — узнаётся из первого же принятого пакета.
    private let remoteSSRC = OSAllocatedUnfairLock(initialState: UInt32?.none)
    private let remoteViewLock = OSAllocatedUnfairLock(initialState: RTCPSession.RemoteView?.none)

    public init(
        negotiated: NegotiatedMedia,
        localPort: UInt16,
        inputDeviceUID: String? = nil,
        outputDeviceUID: String? = nil,
        releasesDeviceWhenIdle: Bool = true,
        automaticGainControl: Bool = true
    ) throws {
        configuration = RTPSession.Configuration(negotiated: negotiated)

        jitter = JitterBuffer(
            codec: negotiated.codec,
            packetTimeMilliseconds: negotiated.packetTimeMilliseconds
        )
        engine = try VoiceAudioEngine(configuration: .init(
            codec: negotiated.codec,
            packetTimeMilliseconds: negotiated.packetTimeMilliseconds,
            inputDeviceUID: inputDeviceUID,
            outputDeviceUID: outputDeviceUID,
            releasesDeviceWhenIdle: releasesDeviceWhenIdle,
            automaticGainControl: automaticGainControl
        ))
        rtp = try RTPSession(
            configuration: configuration,
            localPort: localPort,
            remoteHost: negotiated.remoteAddress,
            remotePort: negotiated.remotePort
        )
        // RTCP живёт на порту RTP плюс один — RFC 3550 §11. Ради этого порт под
        // RTP и выбирается чётным.
        //
        // Собирается после RTP, потому что отчёты подписываются тем же SSRC,
        // что и поток: с чужим номером собеседник не свяжет одно с другим и
        // просто выбросит наши отчёты, а выглядеть это будет как исправный
        // обмен с пустой статистикой.
        rtcp = RTCPSession(
            ssrc: rtp.synchronizationSource,
            canonicalName: "elitesip@\(localPort)",
            clockRate: negotiated.codec.rtpClockRate,
            localPort: localPort + 1,
            remoteHost: negotiated.remoteAddress,
            remotePort: negotiated.remotePort + 1
        )
    }

    /// Куда писать подробности о форматах звука.
    public var onDiagnostic: (@Sendable (String) -> Void)? {
        get { engine.onDiagnostic }
        set { engine.onDiagnostic = newValue }
    }

    /// Пиковые уровни в обе стороны, от 0 до 1. Чтение сбрасывает пик.
    public var inputLevel: Float { engine.inputLevel }
    public var outputLevel: Float { engine.outputLevel }

    /// Распакованные отсчёты принятого звука — для диагностики.
    public var onDecodedSamples: (@Sendable ([Int16]) -> Void)? {
        get { engine.onDecodedSamples }
        set { engine.onDecodedSamples = newValue }
    }

    /// События аудиотракта: пересборка после смены устройства, смена маршрута.
    public var onAudioEvent: (@Sendable (VoiceAudioEngine.Event) -> Void)? {
        get { engine.onEvent }
        set { engine.onEvent = newValue }
    }

    public func start() throws {
        rtp.onReceivedPacket = { [weak self] packet in
            guard let self else { return }
            // События DTMF в звук не отдаём: их полезная нагрузка — не аудио, и
            // декодированная как G.711 она превратится в громкий треск.
            if let eventType = configuration.telephoneEventPayloadType, packet.payloadType == eventType {
                return
            }
            // SSRC собеседника нужен для отчётов: без него блок отчёта
            // некуда адресовать.
            remoteSSRC.withLock { if $0 == nil { $0 = packet.ssrc } }
            bufferLock.withLock { jitter.push(packet) }
        }

        engine.onEncodedFrame = { [weak self] frame in
            self?.rtp.send(encodedFrame: frame)
        }

        // Такт воспроизведения задаёт звуковая карта, а не таймер.
        //
        // Раньше здесь был `Task.sleep(20 мс)`, и он плыл: за 11 секунд
        // разговора уходило 465 кадров вместо ожидаемых 550. Джиттер-буфер это
        // скрадывал, но расхождение накапливалось весь разговор. Теперь кадр
        // просят ровно тогда, когда звуковой карте нужны отсчёты, — часы одни
        // и те же, и разойтись им не с чем.
        //
        // Смысл джиттер-буфера при этом сохраняется: связь между неровным
        // приходом из сети и ровным воспроизведением по-прежнему разорвана,
        // просто ровность теперь берётся у кварца, а не у планировщика.
        engine.onNeedsFrame = { [weak self] in
            guard let self else { return nil }
            guard let frame = bufferLock.withLock({ jitter.pop() }) else { return nil }
            return VoiceAudioEngine.PlaybackFrame(
                payload: frame.payload,
                isConcealment: frame.isConcealment
            )
        }

        rtcp.statisticsProvider = { [weak self] in
            guard let self else { return RTCPSession.LocalStatistics() }

            var statistics = RTCPSession.LocalStatistics()
            let sent = rtp.sendStatistics
            statistics.packetsSent = sent.packets
            statistics.octetsSent = sent.octets
            statistics.rtpTimestamp = sent.timestamp
            statistics.remoteSSRC = remoteSSRC.withLock { $0 }

            bufferLock.withLock {
                statistics.fractionLost = jitter.fractionLostSinceLastReport()
                statistics.cumulativeLost = jitter.cumulativePacketsLost
                statistics.highestSequenceNumber = jitter.extendedHighestSequenceNumber
                statistics.jitter = jitter.jitterInClockUnits
            }
            return statistics
        }

        rtcp.onRemoteView = { [weak self] view in
            self?.remoteViewLock.withLock { $0 = view }
            self?.onRemoteView?(view)
        }

        rtp.start()
        // RTCP поднимается только на незащищённом потоке.
        //
        // По RFC 3711 при SRTP отчёты обязаны идти как SRTCP: со своим набором
        // ключей, своим счётчиком и обязательной аутентификацией. Отправлять
        // рядом с зашифрованным звуком открытый RTCP нельзя по двум причинам —
        // собеседник его всё равно отбросит, а наружу утекут SSRC, счётчики и
        // тайминги разговора, который мы только что взялись прятать.
        //
        // Пока SRTCP не написан, в защищённом режиме статистики собеседника
        // просто нет. Это заметно, поэтому сказано вслух, а не спрятано.
        if rtp.isSecured {
            onDiagnostic?("RTCP выключен: защищённый поток требует SRTCP, он ещё не сделан")
        } else {
            rtcp.start()
        }
        try engine.start()
    }

    /// Что собеседник видит про наш поток. Приезжает раз в пять секунд.
    public var onRemoteView: (@Sendable (RTCPSession.RemoteView) -> Void)?

    /// Последний отчёт собеседника о нашем потоке, если он был.
    public var remoteView: RTCPSession.RemoteView? {
        remoteViewLock.withLock { $0 }
    }

    public func stop() {
        engine.stop()
        if !rtp.isSecured { rtcp.stop() }
        rtp.stop()
        bufferLock.withLock { jitter.reset() }
    }

    // MARK: - Диагностика

    public var statistics: JitterBuffer.Statistics {
        bufferLock.withLock { jitter.statistics }
    }

    public var summary: String {
        let stats = statistics
        // Длительность считается по отсчётам, которые запросила звуковая карта:
        // это единственные часы в разговоре, которые нельзя оспорить.
        let seconds = Double(engine.renderedSampleCount) / Double(configuration.codec.sampleRate)
        let buffer = bufferLock.withLock { (jitter.jitterMilliseconds, jitter.targetDepth) }
        return String(
            format: "принято %d, спрятано %d, не по порядку %d, недоборов %d, "
                + "проиграно %.1f с, пустых рендеров %d, джиттер %.1f мс, запас %d кадр.",
            stats.received, stats.concealed, stats.reordered, stats.underruns,
            seconds, engine.starvedRenderCount, buffer.0, buffer.1
        ) + (remoteView.map { " | у собеседника: \($0.summary)" } ?? "")
    }

    public var route: AudioRoute { engine.route }
}
