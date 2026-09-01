import Compat
import Foundation
import os

// не переводится: счётчики медиа — журнал и отчёт диагностики.

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
    ) throws -> (offer: SessionDescription, port: UInt16, reservation: RTPPortReservation) {
        let reservation = try RTPSession.reservePortPair()
        let port = reservation.rtpPort
        return (
            SDPNegotiator.makeOffer(
                address: localAddress, port: port, codecs: codecs, security: security
            ),
            port,
            reservation
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
    ) throws -> (
        answer: SessionDescription,
        media: NegotiatedMedia,
        port: UInt16,
        reservation: RTPPortReservation
    ) {
        if security == .sdesRequired,
           offer.audio?.protocolName.caseInsensitiveCompare("RTP/SAVP") != .orderedSame {
            throw SDPNegotiationError.secureMediaRequired
        }

        let reservation = try RTPSession.reservePortPair()
        do {
            let negotiated = try SDPNegotiator.makeAnswer(
                to: offer,
                address: localAddress,
                port: reservation.rtpPort,
                supported: codecs
            )
            return (
                negotiated.answer,
                negotiated.media,
                reservation.rtpPort,
                reservation
            )
        } catch {
            reservation.release()
            throw error
        }
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
    private let portReservation: RTPPortReservation

    /// Общий аудиотракт. Сессия им не владеет — берёт на время разговора.
    private let bus: VoiceAudioBus
    /// Ключ владения. Считается от самой сессии, поэтому уникален и умирает
    /// вместе с ней.
    private var token: VoiceAudioBus.Token { ObjectIdentifier(self) }
    /// Под какие настройки поднимать тракт, когда эта линия его получит.
    private let audioConfiguration: VoiceAudioEngine.Configuration

    /// Состояние звука этой линии, пока тракт у кого-то другого.
    ///
    /// Своего движка у фоновой линии больше нет, а причины молчать
    /// (`AppModel.applyAudioState`) складываются на ней в любой момент — и
    /// когда она в фоне, и когда её только что вернули. Значение хранится
    /// здесь и досылается в тракт при получении владения; иначе возврат из
    /// фона отдавал бы линию с чужой громкостью и чужим mute.
    private struct AudioState {
        var isMuted = false
        /// Множители громкости. Хранятся здесь по той же причине, что и mute:
        /// ползунок двигают когда угодно, в том числе пока тракт у соседней
        /// линии, и значение обязано дожить до возврата.
        var microphoneGain: Float = 1
        var playbackVolume: Float = 1
        /// Что успел намерить движок, пока звук был наш. Для сводки после
        /// звонка: счётчики общего тракта обнуляются на смене владельца, и
        /// спросить их у уже отпущенного движка нельзя.
        var renderedSamples = 0
        var starvedRenders = 0
        var route = AudioRoute(input: nil, output: nil)
        var usesEchoCancellation = false
    }

    private let audio = UnfairLock(initialState: AudioState())

    /// Всё, что меняется при пересогласовании, — одним куском под одним замком.
    private struct Transport {
        let rtp: RTPSession
        let rtcp: RTCPSession
        let configuration: RTPSession.Configuration
        let negotiated: NegotiatedMedia
    }

    /// Поток RTP живёт под замком, потому что пересогласование подменяет его
    /// целиком, пока отправка кадров идёт с потока кодирования.
    private let transport: UnfairLock<Transport?>

    /// Джиттер-буфер трогают два потока: приём RTP и подача в звук.
    private let bufferLock = NSLock()
    private var jitter: JitterBuffer

    /// Кто из говорящих на нашем порту — собеседник. Устройство и цена решения
    /// — в `RemoteSourceFilter`.
    private let remoteSource = UnfairLock(initialState: RemoteSourceFilter())
    private let remoteViewLock = UnfairLock(initialState: RTCPSession.RemoteView?.none)

    /// Что сейчас можно делать со звуком.
    private struct Flow {
        /// Отдавать принятое в звук. Выключается на удержании: музыка ожидания
        /// в ухо оператору, который в это время говорит с другим, — не то,
        /// чего от удержания ждут.
        var receivesAudio = true
        /// Идёт событие DTMF: кадры звука в этот момент не отправляются.
        var isSendingTone = false
    }

    private let flow = UnfairLock(initialState: Flow())

    /// Собирает медиа-половину разговора.
    ///
    /// `bus` — общий аудиотракт приложения. Без него сессия заводит свой
    /// собственный, и это не поблажка вызывающему: так работают `sipcheck`,
    /// `audioprobe` и тесты, у которых разговор ровно один, а общий тракт был
    /// бы лишней связностью. Внутри приложения передавать общий обязательно —
    /// линий до трёх, и звуковая карта у них одна.
    public init(
        negotiated: NegotiatedMedia,
        reservation: RTPPortReservation,
        bus: VoiceAudioBus? = nil,
        inputDeviceUID: String? = nil,
        outputDeviceUID: String? = nil,
        releasesDeviceWhenIdle: Bool = true,
        automaticGainControl: Bool = false,
        microphoneGain: Float = 1,
        playbackVolume: Float = 1
    ) throws {
        localPort = reservation.rtpPort
        portReservation = reservation

        jitter = JitterBuffer(
            codec: negotiated.codec,
            packetTimeMilliseconds: negotiated.packetTimeMilliseconds
        )
        audioConfiguration = VoiceAudioEngine.Configuration(
            codec: negotiated.codec,
            packetTimeMilliseconds: negotiated.packetTimeMilliseconds,
            inputDeviceUID: inputDeviceUID,
            outputDeviceUID: outputDeviceUID,
            releasesDeviceWhenIdle: releasesDeviceWhenIdle,
            automaticGainControl: automaticGainControl,
            microphoneGain: microphoneGain,
            playbackVolume: playbackVolume
        )
        self.bus = try bus ?? VoiceAudioBus(configuration: audioConfiguration)
        transport = UnfairLock(
            initialState: try Self.makeTransport(negotiated: negotiated, localPort: localPort)
        )

        // Обработчики вешаются здесь, а не в `start()`, и это не перестановка
        // ради порядка. Отсутствие одной такой строки — назначения
        // `rtp.onFailure` — и было ошибкой, из-за которой отказ сокета не
        // доезжал даже в журнал: пока проводка живёт в отдельном шаге, её можно
        // забыть, а забытую заметить нечем. В `init` она обязательна по
        // построению, и непровязанной сессии больше не существует.
        //
        // Раньше момента, чем `start()`, ничего не случится: сокет ещё не
        // запущен, и звать обработчики некому.
        wireTransport()

        // Громкость запоминается у линии сразу, а не только в конфигурации
        // тракта: `claimAudio` досылает в движок именно эти значения, и без
        // засева первый же захват тракта вернул бы единицу поверх выбранного.
        // Берётся из конфигурации, потому что границы проверила уже она.
        audio.withLock { state in
            state.microphoneGain = audioConfiguration.microphoneGain
            state.playbackVolume = audioConfiguration.playbackVolume
        }
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
    ///
    /// Обработчики теперь хранятся у сессии, а не у движка: движок общий, и
    /// висящее на нём замыкание фоновой линии писало бы в журнал за чужой
    /// разговор. В тракт они уходят в момент, когда сессия его забирает.
    public var onDiagnostic: (@Sendable (String) -> Void)?

    /// Распакованные отсчёты принятого звука — для диагностики.
    public var onDecodedSamples: (@Sendable ([Int16]) -> Void)?

    /// События аудиотракта: пересборка после смены устройства, смена маршрута.
    public var onAudioEvent: (@Sendable (VoiceAudioEngine.Event) -> Void)?

    /// Отказ транспорта медиа: сокет, шифрование, отправка.
    ///
    /// Отдельно от `onDiagnostic`, потому что это не подробность про формат, а
    /// причина, по которой разговор молчит, — и уровень у неё другой.
    /// Сигнализация в этот момент цела: диалог живёт, кнопки работают, на
    /// экране «Разговор». Без этой строки разбор жалобы «звук был, потом
    /// пропал» начинается с пустого места.
    public var onTransportFailure: (@Sendable (String) -> Void)?

    /// Работает ли системное эхоподавление в этом разговоре.
    ///
    /// Пока звук наш — спрашиваем тракт, иначе отдаём последнее известное:
    /// фоновая линия про эхоподавление ответить не может, а показать «нет» ей
    /// значит соврать оператору, что разговор идёт через колонки без защиты.
    public var usesEchoCancellation: Bool {
        bus.withEngine(token) { $0.usesEchoCancellation }
            ?? audio.withLock { $0.usesEchoCancellation }
    }

    /// Пиковые уровни в обе стороны, от 0 до 1. Чтение сбрасывает пик.
    ///
    /// У фоновой линии уровней нет по существу: её микрофон молчит, а принятое
    /// выбрасывается. Ноль здесь — правда, а не заглушка.
    public var inputLevel: Float { bus.withEngine(token) { $0.inputLevel } ?? 0 }
    public var outputLevel: Float { bus.withEngine(token) { $0.outputLevel } ?? 0 }

    /// Собирает обработчики для общего тракта.
    ///
    /// Каждый проверяет, что звук всё ещё наш. Проверка не лишняя: между
    /// снятием владения и остановкой движка помещается уже начатый вызов из
    /// потока подачи, и без неё фоновая линия успела бы отправить свой кадр в
    /// чужой разговор.
    private func makeHandlers() -> VoiceAudioBus.Handlers {
        var handlers = VoiceAudioBus.Handlers()
        handlers.diagnostic = { [weak self] message in self?.onDiagnostic?(message) }
        handlers.event = { [weak self] event in self?.onAudioEvent?(event) }
        handlers.decodedSamples = { [weak self] samples in self?.onDecodedSamples?(samples) }

        handlers.encodedFrame = { [weak self] frame in
            guard let self, bus.isOwner(token) else { return }
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
        handlers.needsFrame = { [weak self] in
            guard let self, bus.isOwner(token) else { return nil }
            guard let frame = bufferLock.withLock({ jitter.pop() }) else { return nil }
            return VoiceAudioEngine.PlaybackFrame(
                payload: frame.payload,
                isConcealment: frame.isConcealment
            )
        }
        return handlers
    }

    /// Забирает общий тракт себе и запускает его.
    private func claimAudio() throws {
        try bus.claim(token, configuration: audioConfiguration, handlers: makeHandlers())
        // Всё, что накопилось на линии, пока звука у неё не было, досылается
        // сразу: mute, поставленный на фоновой линии, обязан пережить возврат.
        let (muted, gain, volume) = audio.withLock {
            ($0.isMuted, $0.microphoneGain, $0.playbackVolume)
        }
        bus.withEngine(token) { engine in
            engine.isMuted = muted
            engine.microphoneGain = gain
            engine.playbackVolume = volume
            audio.withLock { state in
                state.route = engine.route
                state.usesEchoCancellation = engine.usesEchoCancellation
            }
        }
    }

    /// Отпускает общий тракт, запомнив то, что после этого спросить будет не у
    /// кого.
    private func releaseAudio() {
        bus.withEngine(token) { engine in
            audio.withLock { state in
                state.renderedSamples += engine.renderedSampleCount
                state.starvedRenders += engine.starvedRenderCount
                state.route = engine.route
                state.usesEchoCancellation = engine.usesEchoCancellation
            }
        }
        bus.release(token)
    }

    public func start() throws {
        // `wireTransport` здесь больше нет: обработчики уже висят с `init`.
        portReservation.activate()
        startTransport()
        do {
            try claimAudio()
        } catch {
            stop()
            throw error
        }
        isAudioRunning.withLock { $0 = true }
    }

    /// Очередь, на которой тракт поднимается и снимается.
    ///
    /// Общая на все сессии и последовательная. Это не экономия на потоках, а
    /// порядок: подъём одной линии обязан идти после снятия другой, иначе на
    /// устройстве окажутся две `VoiceProcessingIO` разом — а это, по замерам
    /// M6, не два разговора, а один испорченный. Тот же порядок держит у себя
    /// `VoiceAudioBus`, и вторая очередь его не подменяет, а повторяет с
    /// другой стороны.
    private static let lifecycle = DispatchQueue(label: "com.elite.EliteSIP.media-lifecycle")

    /// `start()`, не задерживающий вызывающего.
    ///
    /// Подъём тракта стоит до восьми десятых секунды на открытии устройства —
    /// цифра из `VoiceAudioBus.claim`, — и всё это время главный актор стоит:
    /// панель не перерисовывается, кнопки не отвечают. Ждать всё равно
    /// приходится, и порядок обязателен: 200 OK уходит после подъёма медиа,
    /// иначе первые кадры Asterisk летят в закрытый порт. Но ждать должен тот,
    /// кто позвал, а не весь интерфейс.
    public func startWithoutBlocking() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.lifecycle.async { [self] in
                continuation.resume(with: Result { try start() })
            }
        }
    }

    /// `stop()`, не задерживающий вызывающего.
    ///
    /// Снятие дороже подъёма: `RTPSession.stop` ждёт закрытия сокета до
    /// полусекунды, движок останавливается синхронно, и замер 6 августа
    /// 2026 дал в сумме 1,4 секунды. Столько интерфейс не отвечал после
    /// отбоя — ровно в тот момент, когда оператор набирает следующий номер и
    /// жмёт по неотвечающей панели ещё раз.
    ///
    /// Сессия удерживается замыканием до конца остановки. Без этого последняя
    /// ссылка на неё могла бы исчезнуть раньше, и `deinit` позвал бы `stop()`
    /// второй раз, с чужого потока и посреди первого.
    public func stopWithoutBlocking() {
        Self.lifecycle.async { [self] in stop() }
    }

    /// Поднимает поток RTP, не трогая звуковую карту.
    ///
    /// Существует ради проверок: `start()` забирает общий аудиотракт, а
    /// разрешения на микрофон в сборочной машине никто не выдаст. Всё, что
    /// касается приёма пакетов — фильтр источника, джиттер-буфер, счётчики, —
    /// проверяется без единого звука.
    ///
    /// Прикладному коду не нужен и потому не `public`: ему нужен разговор
    /// целиком, а разговор без звука разговором не является.
    func startWithoutAudio() {
        portReservation.activate()
        startTransport()
    }

    /// Вешает обработчики на текущий поток RTP и RTCP.
    ///
    /// Зовётся из `init` — чтобы непровязанной сессии не бывало вовсе — и из
    /// `renegotiate`, где поток подменяется целиком, а звук и буфер остаются те
    /// же. Обработчик приёма намеренно замыкается на свой payload type события,
    /// а не читает его из общего состояния: иначе каждый принятый пакет брал бы
    /// замок, который в этот момент держит пересогласование.
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

            // Чей это голос. Заодно узнаётся SSRC для отчётов RTCP: без него
            // блок отчёта некуда адресовать.
            switch remoteSource.withLock({ $0.admit(ssrc: packet.ssrc) }) {
            case .known:
                break
            case .foreign:
                // Молча: чужой поток может идти сколько угодно, и строка на
                // каждый его пакет залила бы журнал вместо того, чтобы о чём-то
                // сообщить.
                return
            case .adopted:
                // Источник сменился по-настоящему. Буфер выбрасывается вместе
                // с ним: в нём лежат кадры прежнего потока, а номера
                // последовательности у нового свои, и склеивать одно с другим
                // по номерам — верный способ получить кашу вместо речи.
                bufferLock.withLock { jitter.reset() }
                onDiagnostic?("источник потока сменился, SSRC \(packet.ssrc)")
            }

            bufferLock.withLock { jitter.push(packet) }
        }

        // Отказ сокета, шифрования или отправки. До этой строки он не доезжал
        // никуда: обработчик был объявлен, срабатывал в четырёх местах и не был
        // назначен ни одним вызывающим.
        rtp.onFailure = { [weak self] reason in
            self?.onTransportFailure?(reason)
        }

        rtcp.statisticsProvider = { [weak self] in
            guard let self else { return RTCPSession.LocalStatistics() }

            var statistics = RTCPSession.LocalStatistics()
            let sent = rtp.sendStatistics
            statistics.packetsSent = sent.packets
            statistics.octetsSent = sent.octets
            statistics.rtpTimestamp = sent.timestamp
            statistics.remoteSSRC = remoteSource.withLock { $0.accepted }

            bufferLock.withLock {
                statistics.fractionLost = jitter.fractionLostSinceLastReport()
                statistics.cumulativeLost = jitter.cumulativePacketsLost
                statistics.highestSequenceNumber = jitter.extendedHighestSequenceNumber
                statistics.jitter = jitter.jitterInClockUnits
            }
            return statistics
        }

        // Журнал RTCP выводится там же, где форматы звука: провал привязки порта
        // и прощание собеседника иначе не видны ничем.
        rtcp.onDiagnostic = { [weak self] message in
            self?.onDiagnostic?(message)
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

    /// Сессию нельзя выбросить работающей.
    ///
    /// `stop()` идемпотентен, поэтому обычный путь (снятие линии) от этого
    /// ничего не теряет. Нужен `deinit` для путей, где ссылка теряется молча:
    /// звонок, успевший закончиться, пока поднимался звук, — тогда и порт, и
    /// сокет RTP, и звуковое устройство остались бы занятыми до выхода из
    /// приложения, а движок деаллоцировался бы работающим (см. `deinit` в
    /// `VoiceAudioEngine`).
    ///
    /// `engine.stop()` заходит на очередь движка синхронно, так что отпускать
    /// последнюю ссылку на сессию нельзя из блока, выполняющегося на ней же.
    deinit {
        stop()
    }

    public func stop() {
        cancelDTMFQueue()
        isAudioRunning.withLock { $0 = false }
        releaseAudio()
        let current = transport.withLock { $0 }
        if let current {
            if !current.rtp.isSecured { current.rtcp.stop() }
            current.rtp.stop()
        }
        bufferLock.withLock { jitter.reset() }
        portReservation.release()
    }

    // MARK: - Фоновая линия

    /// Отпускает звуковую карту, не трогая ни RTP, ни резервацию порта.
    ///
    /// Нужно многолинейности: аудиотракт у оператора один — один микрофон, один
    /// выход, одна обработка голоса, — а разговоров до трёх. Держать три
    /// запущенных `VoiceProcessingIO` на одном устройстве нельзя: они делят
    /// устройство между собой, а на Bluetooth-гарнитуре ещё и удерживают её в
    /// режиме двусторонней связи всё время, пока жива хоть одна линия.
    ///
    /// Сигнализация при этом продолжается полностью: удержанная линия остаётся
    /// в диалоге, отвечает на повторные INVITE и держит свою пару портов, так
    /// что вернуть её в разговор можно без пересогласования.
    public func suspendAudio() {
        // Без проверки «а был ли запущен»: линия могла уйти в фон и до того,
        // как поднялся её тракт, и заглушить её надо всё равно.
        isAudioRunning.withLock { $0 = false }
        // Порядок тот же, что при удержании: сначала замолчать, потом отпускать
        // устройство. Иначе последний захваченный кадр успевает уйти в линию
        // уже после того, как оператор переключился на другую.
        isHeld = true
        releaseAudio()
        bufferLock.withLock { jitter.reset() }
    }

    /// Возвращает линию в разговор: аудиотракт собирается заново на том же
    /// потоке RTP.
    ///
    /// Слышно как короткий провал — ровно как при смене устройства посреди
    /// разговора, и по той же причине: граф собирается с нуля.
    /// Условие выхода — владение трактом, а не собственный флаг «я запущена».
    ///
    /// Разница появилась вместе с общим трактом и стоит потерянного звука.
    /// Линия может считать себя работающей и при этом не владеть трактом: его
    /// успела забрать другая — например, консультация, ответившая уже после
    /// того, как оператор переключился обратно. По флагу такая линия молча не
    /// возвращала бы себе звук, а на экране оставалось бы «Разговор».
    public func resumeAudio() throws {
        guard !ownsAudio else { return }
        try claimAudio()
        isAudioRunning.withLock { $0 = true }
        isHeld = false
    }

    /// Наш ли сейчас общий тракт.
    public var ownsAudio: Bool { bus.isOwner(token) }

    /// Работает ли аудиотракт этой линии.
    public var isAudioActive: Bool { isAudioRunning.withLock { $0 } }

    /// Признак ведётся здесь, а не спрашивается у движка: `VoiceAudioEngine`
    /// считает себя запущенным и после отказа сборки графа, а решение
    /// «отпустили ли мы карту» принимаем мы.
    private let isAudioRunning = UnfairLock(initialState: false)

    // MARK: - Удержание

    /// Немой микрофон. Работает и как удержание, и как отдельная кнопка.
    ///
    /// Хранится у сессии, а не спрашивается у тракта: тракт общий, и у фоновой
    /// линии его нет вовсе. Причины молчать складываются на линии в любой
    /// момент (`AppModel.applyAudioState`), в том числе пока она в фоне, — и
    /// значение обязано дожить до возврата.
    public var isMicrophoneMuted: Bool {
        get { audio.withLock { $0.isMuted } }
        set {
            audio.withLock { $0.isMuted = newValue }
            bus.withEngine(token) { $0.isMuted = newValue }
        }
    }

    /// Усиление микрофона и громкость воспроизведения.
    ///
    /// Хранятся у сессии и досылаются в тракт, как и mute: тракт общий, у
    /// фоновой линии его нет вовсе, а ползунок двигают не спрашивая, какая
    /// линия сейчас звучит.
    public var microphoneGain: Float {
        get { audio.withLock { $0.microphoneGain } }
        set {
            // Границы проверяются здесь тоже, а не только в движке: значение
            // хранится у линии и досылается ею — сохранить непроверенное
            // значило бы вернуть его в тракт при следующем захвате.
            let value = newValue.clampedGain(to: VoiceAudioEngine.Configuration.microphoneGainLimit)
            audio.withLock { $0.microphoneGain = value }
            bus.withEngine(token) { $0.microphoneGain = value }
        }
    }

    public var playbackVolume: Float {
        get { audio.withLock { $0.playbackVolume } }
        set {
            let value = newValue.clampedGain(to: 1)
            audio.withLock { $0.playbackVolume = value }
            bus.withEngine(token) { $0.playbackVolume = value }
        }
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
        //
        // Оба сокета закрываются с ожиданием и обязательно ДО `startTransport`:
        // новая пара встаёт на те же локальные порты, а `cancel()` асинхронный.
        // Для RTP это слышно как тишина, для RTCP не слышно вообще — просто
        // пропадает статистика собеседника.
        transport.withLock { $0 = replacement }
        current.rtp.stop()
        if !current.rtp.isSecured { current.rtcp.stop() }
        bufferLock.withLock { jitter.reset() }
        // Собеседник за новым сокетом — заново неизвестно кто: поток он мог
        // пересобрать вместе с адресом, и прежний SSRC ничего про него не
        // говорит.
        remoteSource.withLock { $0 = RemoteSourceFilter() }
        remoteViewLock.withLock { $0 = nil }

        wireTransport()
        startTransport()
        apply(direction: updated.direction)

        return .streamRebuilt
    }

    // MARK: - DTMF

    /// Шаг несёт свой тайминг с собой.
    ///
    /// Иначе набор, вставший в очередь позади чужого, играется чужими
    /// длительностями: worker создаётся один раз и запомнил бы тайминг того,
    /// кто его завёл. Настройки при этом меняются прямо во время разговора.
    private enum QueuedDTMFItem {
        case step(DTMFStep, timing: DTMFTiming?)
        case completion(CheckedContinuation<Bool, Never>)
    }

    private struct DTMFState {
        var task: Task<Void, Never>?
        var queue: [QueuedDTMFItem] = []
    }

    /// Задача и очередь живут под одним замком. Иначе новый тон мог попасть
    /// между обнаружением пустой очереди и обнулением task и остаться без worker.
    private let dtmfState = UnfairLock(initialState: DTMFState())

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
        enqueueDTMF(sequence, timing: timing, completion: nil)
        return true
    }

    /// Ждёт, пока последовательность действительно выйдет из очереди RTP.
    ///
    /// Это не подтверждение выполнения команды сервером, но уже не простое
    /// «поставлено в очередь». При остановке media-сессии возвращает false.
    public func sendAndWait(
        dtmf sequence: DTMFSequence,
        timing: DTMFTiming? = nil
    ) async -> Bool {
        guard supportsTelephoneEvents else { return false }
        guard !sequence.isEmpty else { return true }

        return await withCheckedContinuation { continuation in
            enqueueDTMF(sequence, timing: timing, completion: continuation)
        }
    }

    /// Отправляет один символ: цифру, звёздочку или решётку.
    @discardableResult
    public func send(dtmf character: Character, timing: DTMFTiming? = nil) -> Bool {
        guard let event = TelephoneEventPayload.event(for: character) else { return false }
        return send(dtmf: DTMFSequence(steps: [.tone(event)]), timing: timing)
    }

    private func enqueueDTMF(
        _ sequence: DTMFSequence,
        timing: DTMFTiming?,
        completion: CheckedContinuation<Bool, Never>?
    ) {
        dtmfState.withLock { state in
            state.queue.append(contentsOf: sequence.steps.map { .step($0, timing: timing) })
            if let completion {
                state.queue.append(.completion(completion))
            }
            guard state.task == nil else { return }
            state.task = Task { [weak self] in
                await self?.drainDTMFQueue()
            }
        }
    }

    private func drainDTMFQueue() async {
        while !Task.isCancelled {
            let item = dtmfState.withLock { state -> QueuedDTMFItem? in
                guard !state.queue.isEmpty else {
                    // Обнуление task атомарно с проверкой очереди: следующий
                    // send либо увидит worker, либо сам создаст новый.
                    state.task = nil
                    return nil
                }
                return state.queue.removeFirst()
            }
            guard let item else { return }

            switch item {
            case .completion(let continuation):
                continuation.resume(returning: !Task.isCancelled)

            case .step(.pause(let milliseconds), _):
                try? await Task.sleep(.milliseconds(milliseconds))

            case .step(.tone(let event), let requested):
                let timing = effectiveTiming(requested)
                guard await sendTone(event: event, timing: timing) else {
                    failPendingDTMF()
                    return
                }
                // Пауза между тонами — здесь, а не в раскладке: очередь
                // пополняется по нажатию, и заранее раскладывать нечего.
                try? await Task.sleep(.milliseconds(timing.gapMilliseconds))
            }
        }
        failPendingDTMF()
    }

    private func cancelDTMFQueue() {
        let pending = dtmfState.withLock { state -> [QueuedDTMFItem] in
            state.task?.cancel()
            state.task = nil
            defer { state.queue.removeAll() }
            return state.queue
        }
        resumeCompletions(in: pending, result: false)
    }

    private func failPendingDTMF() {
        let pending = dtmfState.withLock { state -> [QueuedDTMFItem] in
            state.task = nil
            defer { state.queue.removeAll() }
            return state.queue
        }
        resumeCompletions(in: pending, result: false)
    }

    private func resumeCompletions(in items: [QueuedDTMFItem], result: Bool) {
        for item in items {
            if case .completion(let continuation) = item {
                continuation.resume(returning: result)
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

    private func sendTone(event: UInt8, timing: DTMFTiming) async -> Bool {
        flow.withLock { $0.isSendingTone = true }
        defer { flow.withLock { $0.isSendingTone = false } }

        for action in DTMFPlanner.actions(forEvent: event, timing: timing) {
            guard !Task.isCancelled else { return false }
            switch action {
            case .wait(let milliseconds):
                try? await Task.sleep(.milliseconds(milliseconds))

            case .packet(let packet):
                guard let rtp = currentRTP else { return false }
                rtp.send(event: packet.payload, isFirst: packet.isFirst)
                if packet.completesEvent {
                    rtp.finishEvent(advancingTimestampBy: packet.timestampAdvance)
                }
            }
        }
        return !Task.isCancelled
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
        // Счётчики общего тракта принадлежат текущему владельцу и обнуляются на
        // смене, поэтому своё складывается из накопленного за прошлые владения
        // и того, что тракт намерил, пока он наш. Иначе сводка после разговора
        // с переключением линий показывала бы только последний кусок.
        let counters = audio.withLock { $0 }
        let live = bus.withEngine(token) { ($0.renderedSampleCount, $0.starvedRenderCount) }
        let renderedSamples = counters.renderedSamples + (live?.0 ?? 0)
        let starvedRenders = counters.starvedRenders + (live?.1 ?? 0)

        // Длительность считается по отсчётам, которые запросила звуковая карта:
        // это единственные часы в разговоре, которые нельзя оспорить.
        let seconds = Double(renderedSamples) / Double(codec.sampleRate)
        let buffer = bufferLock.withLock { (jitter.jitterMilliseconds, jitter.targetDepth) }
        return String(
            format: "принято %d, спрятано %d, не по порядку %d, недоборов %d, "
                + "проиграно %.1f с, пустых рендеров %d, джиттер %.1f мс, запас %d кадр.",
            stats.received, stats.concealed, stats.reordered, stats.underruns,
            seconds, starvedRenders, buffer.0, buffer.1
        ) + (remoteView.map { " | у собеседника: \($0.summary)" } ?? "")
    }

    public var route: AudioRoute {
        bus.withEngine(token) { $0.route } ?? audio.withLock { $0.route }
    }
}
