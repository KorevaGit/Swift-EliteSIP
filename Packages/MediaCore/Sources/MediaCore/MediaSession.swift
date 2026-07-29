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

    public enum SessionError: Error, Sendable, Equatable, CustomStringConvertible {
        /// Пересогласование сменило кодек. Пересобрать на ходу нельзя: от кодека
        /// зависит вся цепочка звука, включая частоты микшера.
        case codecChanged(from: AudioCodec, to: AudioCodec)

        public var description: String {
            switch self {
            case .codecChanged(let from, let to):
                "собеседник сменил кодек с \(from.sdpName) на \(to.sdpName) — тракт надо пересобрать"
            }
        }
    }

    /// Чем кончилось пересогласование.
    public enum Renegotiation: Sendable, Equatable {
        /// Изменилось только направление: звук перенаправлен, поток тот же.
        case directionOnly
        /// Собеседник вернулся с другого адреса или с другими ключами — поток
        /// RTP пересобран на том же локальном порту.
        case streamRebuilt
    }

    /// Локальный порт RTP. Нужен приложению: повторное предложение обязано
    /// нести тот же порт, а при пересборке сессии — занять его заново.
    public let localPort: UInt16

    private let engine: VoiceAudioEngine

    /// Всё, что меняется при пересогласовании, — одним куском под одним замком.
    private struct Transport {
        let rtp: RTPSession
        let rtcp: RTCPSession
        let configuration: RTPSession.Configuration
        let negotiated: NegotiatedMedia
    }

    /// Поток RTP живёт под замком, потому что пересогласование подменяет его
    /// целиком, пока отправка кадров идёт с потока кодирования.
    private let transport: OSAllocatedUnfairLock<Transport?>

    /// Джиттер-буфер трогают два потока: приём RTP и подача в звук.
    private let bufferLock = NSLock()
    private var jitter: JitterBuffer

    /// SSRC собеседника — узнаётся из первого же принятого пакета.
    private let remoteSSRC = OSAllocatedUnfairLock(initialState: UInt32?.none)
    private let remoteViewLock = OSAllocatedUnfairLock(initialState: RTCPSession.RemoteView?.none)

    /// Что сейчас можно делать со звуком.
    private struct Flow {
        /// Отдавать принятое в звук. Выключается на удержании: музыка ожидания
        /// в ухо оператору, который в это время говорит с другим, — не то,
        /// чего от удержания ждут.
        var receivesAudio = true
        /// Идёт событие DTMF: кадры звука в этот момент не отправляются.
        var isSendingTone = false
    }

    private let flow = OSAllocatedUnfairLock(initialState: Flow())

    public init(
        negotiated: NegotiatedMedia,
        localPort: UInt16,
        inputDeviceUID: String? = nil,
        outputDeviceUID: String? = nil,
        releasesDeviceWhenIdle: Bool = true,
        automaticGainControl: Bool = true
    ) throws {
        self.localPort = localPort

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
        transport = OSAllocatedUnfairLock(
            initialState: try Self.makeTransport(negotiated: negotiated, localPort: localPort)
        )
    }

    /// Собирает пару RTP и RTCP под уже согласованные параметры.
    private static func makeTransport(
        negotiated: NegotiatedMedia,
        localPort: UInt16
    ) throws -> Transport {
        let configuration = RTPSession.Configuration(negotiated: negotiated)
        let rtp = try RTPSession(
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
        let rtcp = RTCPSession(
            ssrc: rtp.synchronizationSource,
            canonicalName: "elitesip@\(localPort)",
            clockRate: negotiated.codec.rtpClockRate,
            localPort: localPort + 1,
            remoteHost: negotiated.remoteAddress,
            remotePort: negotiated.remotePort + 1
        )
        return Transport(rtp: rtp, rtcp: rtcp, configuration: configuration, negotiated: negotiated)
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
        wireTransport()

        engine.onEncodedFrame = { [weak self] frame in
            guard let self else { return }
            // Пока идёт событие DTMF, звук в линию не уходит.
            //
            // Не из экономии: все пакеты одного нажатия обязаны нести одну и ту
            // же метку времени (RFC 4733 §2.5.1), а каждый отправленный кадр
            // звука её двигает. Кадр посреди тона превращает одно нажатие в
            // серию коротких, и голосовое меню на той стороне слышит мусор.
            guard !flow.withLock({ $0.isSendingTone }) else { return }
            currentRTP?.send(encodedFrame: frame)
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

        startTransport()
        try engine.start()
    }

    /// Вешает обработчики на текущий поток RTP и RTCP.
    ///
    /// Отдельно от `start`, потому что при пересогласовании поток меняется, а
    /// звук и буфер остаются те же. Обработчик приёма намеренно замыкается на
    /// свой payload type события, а не читает его из общего состояния: иначе
    /// каждый принятый пакет брал бы замок, который в этот момент держит
    /// пересогласование.
    private func wireTransport() {
        guard let current = transport.withLock({ $0 }) else { return }
        let eventPayloadType = current.configuration.telephoneEventPayloadType
        // Обе половины по отдельности, а не через `current`: отчёт RTCP берёт
        // счётчики у RTP, и замыкание, захватившее пару целиком, замкнуло бы
        // RTCP сам на себя — сессия не освободилась бы никогда.
        let rtp = current.rtp
        let rtcp = current.rtcp

        rtp.onReceivedPacket = { [weak self] packet in
            guard let self else { return }
            // События DTMF в звук не отдаём: их полезная нагрузка — не аудио, и
            // декодированная как G.711 она превратится в громкий треск.
            if let eventPayloadType, packet.payloadType == eventPayloadType {
                return
            }
            // На удержании принятое просто выбрасывается. Копить его в буфере
            // нельзя: к возврату в разговор там будет минута протухшей музыки,
            // которую оператор услышит вместо собеседника.
            guard flow.withLock({ $0.receivesAudio }) else { return }
            // SSRC собеседника нужен для отчётов: без него блок отчёта
            // некуда адресовать.
            remoteSSRC.withLock { if $0 == nil { $0 = packet.ssrc } }
            bufferLock.withLock { jitter.push(packet) }
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
    }

    private func startTransport() {
        guard let current = transport.withLock({ $0 }) else { return }
        current.rtp.start()
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
        if current.rtp.isSecured {
            onDiagnostic?("RTCP выключен: защищённый поток требует SRTCP, он ещё не сделан")
        } else {
            current.rtcp.start()
        }
    }

    private var currentRTP: RTPSession? {
        transport.withLock { $0?.rtp }
    }

    /// Что собеседник видит про наш поток. Приезжает раз в пять секунд.
    public var onRemoteView: (@Sendable (RTCPSession.RemoteView) -> Void)?

    /// Последний отчёт собеседника о нашем потоке, если он был.
    public var remoteView: RTCPSession.RemoteView? {
        remoteViewLock.withLock { $0 }
    }

    public func stop() {
        dtmfTask.withLock { task in
            task?.cancel()
            task = nil
        }
        engine.stop()
        let current = transport.withLock { $0 }
        if let current {
            if !current.rtp.isSecured { current.rtcp.stop() }
            current.rtp.stop()
        }
        bufferLock.withLock { jitter.reset() }
    }

    // MARK: - Удержание

    /// Немой микрофон. Работает и как удержание, и как отдельная кнопка.
    public var isMicrophoneMuted: Bool {
        get { engine.isMuted }
        set { engine.isMuted = newValue }
    }

    /// Отдавать принятое в звук.
    public var isReceivingAudio: Bool {
        get { flow.withLock { $0.receivesAudio } }
        set {
            flow.withLock { $0.receivesAudio = newValue }
            // Буфер чистится на входе в удержание: то, что в нём лежит, к
            // возврату уже безнадёжно старое.
            if !newValue { bufferLock.withLock { jitter.reset() } }
        }
    }

    /// Разговор на удержании: микрофон нем, принятое в звук не идёт.
    ///
    /// Обе стороны глушатся сразу, независимо от того, что написано в SDP.
    /// Направление в SDP — это договорённость с сервером о том, кому что
    /// отправлять; удержание же означает, что оператор ушёл к другому
    /// собеседнику, и ни его голос, ни музыка ожидания сюда попасть не должны.
    public var isHeld: Bool {
        get { isMicrophoneMuted && !isReceivingAudio }
        set {
            isMicrophoneMuted = newValue
            isReceivingAudio = !newValue
        }
    }

    /// Применяет согласованное направление к звуку.
    ///
    /// Направление — это то, о чём договорились в SDP, и оно ортогонально
    /// удержанию по нашей воле: сервер может поставить нас на удержание сам
    /// (`a=sendonly` с его стороны), и тогда молчать надо, даже если кнопку
    /// никто не нажимал.
    public func apply(direction: MediaDirection) {
        isMicrophoneMuted = !direction.sendsAudio
        isReceivingAudio = direction.receivesAudio
    }

    // MARK: - Пересогласование

    /// Параметры, о которых договорились в последний раз.
    public var negotiated: NegotiatedMedia? {
        transport.withLock { $0?.negotiated }
    }

    /// Применяет новые параметры потока к идущему разговору.
    ///
    /// Дешёвый случай — сменилось только направление: удержание и возврат из
    /// него в подавляющем большинстве случаев именно такие, и трогать ради них
    /// звуковую карту нельзя. Пересборка тракта слышна как провал, а на
    /// AirPods стоит ещё и переключения режима.
    ///
    /// Дорогой случай — собеседник вернулся с другого адреса, порта или с
    /// новыми ключами SRTP. Тогда поток RTP пересобирается целиком, но на том
    /// же локальном порту и с тем же аудиотрактом: порт мы объявили в SDP, и
    /// менять его посреди диалога нельзя.
    @discardableResult
    public func renegotiate(to updated: NegotiatedMedia) throws -> Renegotiation {
        guard let current = transport.withLock({ $0 }) else { return .directionOnly }

        guard current.negotiated.codec == updated.codec else {
            throw SessionError.codecChanged(from: current.negotiated.codec, to: updated.codec)
        }

        // Старая запись удержания — адрес 0.0.0.0 или нулевой порт. Пересобирать
        // сокет на такой адрес нельзя и не нужно: он означает «мне сейчас
        // ничего не шли», а не «шли вот сюда». А вот удержание по `a=sendonly`
        // адрес сохраняет и вполне может его сменить: музыку ожидания Asterisk
        // отдаёт со своего порта, и не всегда с прежнего.
        let endpointChanged = !updated.isStreamDisabled
            && (updated.remoteAddress != current.negotiated.remoteAddress
                || updated.remotePort != current.negotiated.remotePort)
        let securityChanged = updated.security != current.negotiated.security

        guard endpointChanged || securityChanged else {
            apply(direction: updated.direction)
            transport.withLock {
                $0 = Transport(
                    rtp: current.rtp,
                    rtcp: current.rtcp,
                    configuration: current.configuration,
                    negotiated: updated
                )
            }
            return .directionOnly
        }

        let replacement = try Self.makeTransport(negotiated: updated, localPort: localPort)

        // Порядок обязателен: сначала подменить, потом закрыть старый поток и
        // только потом чистить буфер. Закрыть первым — значит потерять кадры,
        // почистить раньше закрытия — значит оставить в буфере то, что старый
        // сокет успел отдать уже после чистки.
        transport.withLock { $0 = replacement }
        current.rtp.stop()
        if !current.rtp.isSecured { current.rtcp.stop() }
        bufferLock.withLock { jitter.reset() }
        remoteSSRC.withLock { $0 = nil }
        remoteViewLock.withLock { $0 = nil }

        wireTransport()
        startTransport()
        apply(direction: updated.direction)

        return .streamRebuilt
    }

    // MARK: - DTMF

    private let dtmfTask = OSAllocatedUnfairLock(initialState: Task<Void, Never>?.none)
    private let dtmfQueue = OSAllocatedUnfairLock(initialState: [DTMFStep]())

    /// Согласован ли telephone-event. Если нет, тоны отправить нечем.
    public var supportsTelephoneEvents: Bool {
        transport.withLock { $0?.configuration.telephoneEventPayloadType != nil }
    }

    /// Отправляет набор DTMF по RFC 4733.
    ///
    /// Возвращает false, если собеседник telephone-event не подтвердил: молча
    /// проглотить нажатие нельзя — оператор будет думать, что попал в меню, а
    /// на той стороне не произошло ничего.
    ///
    /// Нажатия, пришедшие во время передачи, встают в очередь, а не начинают
    /// второй тон поверх первого. Оператор набирает быстрее, чем идёт тон, и
    /// без очереди половина цифр терялась бы.
    @discardableResult
    public func send(dtmf sequence: DTMFSequence, timing: DTMFTiming? = nil) -> Bool {
        guard supportsTelephoneEvents else { return false }
        guard !sequence.isEmpty else { return true }

        dtmfQueue.withLock { $0.append(contentsOf: sequence.steps) }

        dtmfTask.withLock { task in
            guard task == nil else { return }
            task = Task { [weak self] in
                await self?.drainDTMFQueue(timing: timing)
                self?.dtmfTask.withLock { $0 = nil }
            }
        }
        return true
    }

    /// Отправляет один символ: цифру, звёздочку или решётку.
    @discardableResult
    public func send(dtmf character: Character, timing: DTMFTiming? = nil) -> Bool {
        guard let event = TelephoneEventPayload.event(for: character) else { return false }
        return send(dtmf: DTMFSequence(steps: [.tone(event)]), timing: timing)
    }

    private func drainDTMFQueue(timing requested: DTMFTiming?) async {
        let timing = effectiveTiming(requested)

        while !Task.isCancelled {
            let step = dtmfQueue.withLock { queue -> DTMFStep? in
                queue.isEmpty ? nil : queue.removeFirst()
            }
            guard let step else { return }

            switch step {
            case .pause(let milliseconds):
                try? await Task.sleep(for: .milliseconds(milliseconds))

            case .tone(let event):
                await sendTone(event: event, timing: timing)
                // Пауза между тонами — здесь, а не в раскладке: очередь
                // пополняется по нажатию, и заранее раскладывать нечего.
                try? await Task.sleep(for: .milliseconds(timing.gapMilliseconds))
            }
        }
    }

    /// Такт отправки берётся из согласованного потока, а не у вызывающего.
    ///
    /// Длительность тона и паузы — дело настроек, а вот пакетное время — дело
    /// договорённости с сервером, и знать его снаружи неоткуда.
    private func effectiveTiming(_ requested: DTMFTiming?) -> DTMFTiming {
        var timing = requested ?? DTMFTiming()
        timing.packetTimeMilliseconds =
            transport.withLock { $0?.configuration.packetTimeMilliseconds } ?? defaultPacketTimeMilliseconds
        return timing
    }

    private func sendTone(event: UInt8, timing: DTMFTiming) async {
        flow.withLock { $0.isSendingTone = true }
        defer { flow.withLock { $0.isSendingTone = false } }

        for action in DTMFPlanner.actions(forEvent: event, timing: timing) {
            guard !Task.isCancelled else { return }
            switch action {
            case .wait(let milliseconds):
                try? await Task.sleep(for: .milliseconds(milliseconds))

            case .packet(let packet):
                guard let rtp = currentRTP else { return }
                rtp.send(event: packet.payload, isFirst: packet.isFirst)
                if packet.completesEvent {
                    rtp.finishEvent(advancingTimestampBy: packet.timestampAdvance)
                }
            }
        }
    }

    // MARK: - Диагностика

    public var statistics: JitterBuffer.Statistics {
        bufferLock.withLock { jitter.statistics }
    }

    public var summary: String {
        let stats = statistics
        let codec = transport.withLock { $0?.configuration.codec } ?? .pcmu
        // Длительность считается по отсчётам, которые запросила звуковая карта:
        // это единственные часы в разговоре, которые нельзя оспорить.
        let seconds = Double(engine.renderedSampleCount) / Double(codec.sampleRate)
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
