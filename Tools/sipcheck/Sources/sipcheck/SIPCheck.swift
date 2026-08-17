import Foundation
import MediaCore
import SIPCore

/// Консольная проверка SIPCore против живого Asterisk.
///
/// Нужна потому, что юнит-тесты проверяют логику, а совместимость — нет.
/// chan_sip придирчив к деталям (Contact, rport, форма Authorization), и увидеть
/// это можно только на настоящем сервере. GUI для такой проверки — лишний слой:
/// здесь виден весь обмен и точный код ответа.
///
/// Примеры:
///   swift run sipcheck --user 100 --password elite100 --transport udp --port 5060
///   swift run sipcheck --user 200 --password elite200 --transport tls --port 5061 --insecure-tls
@main
struct SIPCheck {

    static func main() async {
        let arguments = Arguments(CommandLine.arguments)

        guard let user = arguments["user"], let password = arguments["password"] else {
            print("""
            Использование: sipcheck --user <номер> --password <пароль> [опции]

              --host <адрес>        по умолчанию 127.0.0.1
              --port <порт>         по умолчанию 5060 для udp, 5061 для tls
              --transport udp|tls   по умолчанию udp
              --expires <секунды>   по умолчанию 120
              --duration <секунды>  сколько держать регистрацию, по умолчанию 10
              --insecure-tls        не проверять сертификат (лаборатория)
              --call <номер>        позвонить и прогнать RTP (например 600)
              --answer              ждать входящий и принять его
              --reject              ждать входящий и отклонить (486)
              --audio               поднять настоящий звук: микрофон, буфер, карта
              --narrowband          предлагать только G.711, без широкой полосы
              --dtmf <набор>        отправить тоны в разговоре: цифры и запятые-паузы
              --dtmf-after <сек>    через сколько их отправить, по умолчанию 1
              --hold <секунды>      поставить на удержание и через столько вернуть
              --lines <a,b,c>       живой прогон параллельных линий (M6)
              --consult <номер>     консультационный перевод: --call клиент,
                                    --consult коллега, REFER с Replaces
            """)
            exit(2)
        }

        let transport = SIPTransport(name: arguments["transport"] ?? "udp") ?? .udp
        let host = arguments["host"] ?? "127.0.0.1"
        let port = arguments["port"].flatMap { UInt16($0) } ?? transport.defaultPort
        let expires = arguments["expires"].flatMap { Int($0) } ?? 120
        let duration = arguments["duration"].flatMap { Double($0) } ?? 10

        let account = SIPAccount(
            username: user,
            displayName: "sipcheck",
            domain: host,
            serverPort: port,
            transport: transport,
            registrationExpires: expires
        )

        let channel = NetworkSIPTransport(
            remote: account.signalingEndpoint,
            transport: transport,
            tlsTrust: arguments.hasFlag("insecure-tls") ? .acceptAnyCertificateInsecurely : .system,
            serverName: host
        )

        let agent = SIPUserAgent(
            account: account,
            credentials: DigestAuthentication.Credentials(username: user, password: password),
            channel: channel
        )

        print("→ \(account.signalingEndpoint) по \(transport.protocolName), номер \(user), держим \(Int(duration)) с")

        // Входящий приезжает событием агента, а не по нашему запросу, поэтому
        // ловится здесь же, в общем потоке, и передаётся ожидающему через
        // продолжение — иначе пришлось бы заводить второй поток событий.
        let incoming = IncomingSlot()

        let printer = Task {
            for await event in agent.events {
                switch event {
                case .registration(let state):
                    print("   состояние: \(describe(state))")
                case .log(let level, let message):
                    print("   [\(level.rawValue)] \(message)")
                case .incomingCall(let call):
                    print("← входящий от \(call.displayNumber) на \(call.calledNumber)")
                    await incoming.deliver(call)
                case .unsupportedRequest(let method):
                    print("   отклонён запрос \(method.rawValue)")
                }
            }
        }

        await agent.start()

        // Ждём регистрации: звонить без неё Asterisk не даст.
        let registerDeadline = Date().addingTimeInterval(15)
        var registered = false
        while Date() < registerDeadline, !registered {
            registered = await agent.registrationState.isRegistered
            try? await Task.sleep(for: .milliseconds(100))
        }

        guard registered else {
            let finalState = await agent.registrationState
            await agent.stop()
            printer.cancel()
            print("❌ регистрация не прошла: \(describe(finalState))")
            exit(1)
        }
        print("✅ регистрация прошла")

        // Пересогласователь нужен обеим веткам: удержание с той стороны — это
        // повторный INVITE, и без него sipcheck проверял бы не то, что делает
        // приложение. Заодно это единственный способ увидеть, чем именно
        // Asterisk объявляет удержание на живом стенде.
        let live = LiveMedia(
            codecs: arguments.hasFlag("narrowband")
                ? SDPNegotiator.narrowbandCodecs
                : SDPNegotiator.defaultCodecs
        )
        await agent.setMediaRenegotiator { _, offer in
            live.renegotiate(offer: offer)
        }

        let plan = CallPlan(
            duration: duration,
            dtmf: arguments["dtmf"],
            dtmfAfter: arguments["dtmf-after"].flatMap { Double($0) },
            holdAfter: arguments["hold"].flatMap { Double($0) }
        )

        var callSucceeded = true
        if let list = arguments["lines"] {
            // Многолинейный прогон живёт отдельно от `placeCall`: там одна
            // линия со звуком, здесь три без него. Смешивать их в одном методе
            // значило бы получить третий режим, который не проверяет ни одного
            // из двух.
            let numbers = list.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            callSucceeded = await LinesCheck.runParallel(
                agent: agent,
                host: host,
                numbers: numbers,
                codecs: live.supportedCodecs,
                secureMedia: transport == .tls
            )
        } else if let colleague = arguments["consult"] {
            callSucceeded = await LinesCheck.runConsultation(
                agent: agent,
                host: host,
                client: arguments["call"] ?? "600",
                colleague: colleague,
                codecs: live.supportedCodecs,
                secureMedia: transport == .tls
            )
        } else if arguments.hasFlag("answer") || arguments.hasFlag("reject") {
            callSucceeded = await waitForIncomingCall(
                agent: agent,
                incoming: incoming,
                host: host,
                duration: duration,
                answering: arguments.hasFlag("answer"),
                withAudio: arguments.hasFlag("audio"),
                narrowbandOnly: arguments.hasFlag("narrowband"),
                secureMedia: transport == .tls,
                live: live,
                plan: plan
            )
        } else if let number = arguments["call"] {
            callSucceeded = await placeCall(
                agent: agent,
                to: number,
                host: host,
                duration: duration,
                withAudio: arguments.hasFlag("audio"),
                narrowbandOnly: arguments.hasFlag("narrowband"),
                secureMedia: transport == .tls,
                live: live,
                plan: plan
            )
        } else {
            let deadline = Date().addingTimeInterval(duration)
            while Date() < deadline {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        await agent.stop()
        printer.cancel()
        exit(callSucceeded ? 0 : 1)
    }

    /// Ждёт входящий звонок и отвечает на него или отклоняет.
    ///
    /// Зеркало `placeCall` и нужна ровно затем же: тесты проверяют логику
    /// приёма, а придирчивость chan_sip к нашему 200 OK — только живой сервер.
    /// Кто именно позвонит, инструмент не решает; на лабе проще всего так:
    ///
    ///   docker exec elitesip-freepbx asterisk -rx 'channel originate SIP/100 extension 650@from-internal'
    private static func waitForIncomingCall(
        agent: SIPUserAgent,
        incoming: IncomingSlot,
        host: String,
        duration: Double,
        answering: Bool,
        withAudio: Bool,
        narrowbandOnly: Bool,
        secureMedia: Bool,
        live: LiveMedia,
        plan: CallPlan
    ) async -> Bool {
        print("→ жду входящий \(Int(duration)) с…")

        guard let call = await incoming.wait(timeout: duration) else {
            print("❌ входящего так и не было")
            return false
        }

        guard answering else {
            await agent.rejectIncomingCall(status: 486)
            print("✅ вызов отклонён 486")
            return true
        }

        let address = await agent.mediaAddress ?? host
        let prepared: (
            answer: SessionDescription,
            media: NegotiatedMedia,
            port: UInt16,
            reservation: RTPPortReservation
        )
        do {
            prepared = try MediaSession.makeAnswer(
                to: try SessionDescription(parsing: call.offer),
                localAddress: address,
                codecs: narrowbandOnly ? SDPNegotiator.narrowbandCodecs : SDPNegotiator.defaultCodecs,
                security: secureMedia ? .sdesRequired : .none
            )
        } catch {
            await agent.rejectIncomingCall(status: 488)
            print("❌ на предложение ответить нечем: \(error)")
            return false
        }
        defer { prepared.reservation.release() }

        let media = prepared.media
        print("   отвечаю: \(media.security.isEncrypted ? "SRTP" : "RTP") \(media.codec.sdpName) на \(media.remoteAddress):\(media.remotePort), свой порт \(prepared.port)")

        let received = Counter()
        var rtp: RTPSession?
        var audio: MediaSession?

        // Медиа поднимается ДО 200 OK: Asterisk начинает слать RTP сразу по
        // ответу, и порт к этому моменту обязан слушать.
        do {
            if withAudio {
                guard await VoiceAudioEngine.requestMicrophoneAccess() else {
                    await agent.rejectIncomingCall(status: 486)
                    print("❌ микрофон не разрешён — разрешите его терминалу и повторите")
                    return false
                }
                let session = try MediaSession(
                    negotiated: media,
                    reservation: prepared.reservation
                )
                session.onDiagnostic = { print("   звук: \($0)") }
                session.onTransportFailure = { print("   ✖ медиа: \($0)") }
                try session.start()
                audio = session
            } else {
                let session = try RTPSession(
                    configuration: .init(negotiated: media),
                    localPort: prepared.port,
                    remoteHost: media.remoteAddress,
                    remotePort: media.remotePort
                )
                session.onReceivedPacket = { _ in received.increment() }
                prepared.reservation.activate()
                session.start()
                rtp = session

                let silence = silenceFrame(for: media)
                Task {
                    while !Task.isCancelled {
                        // Пока идёт тон, звук молчит: иначе кадр посреди события
                        // сдвинет метку времени и разрежет одно нажатие на два.
                        if !live.isSendingTone {
                            session.send(encodedFrame: silence)
                        }
                        try? await Task.sleep(for: .milliseconds(media.packetTimeMilliseconds))
                    }
                }
            }
        } catch {
            await agent.rejectIncomingCall(status: 500)
            print("❌ медиа не поднялось: \(error)")
            return false
        }

        live.install(session: audio, rtp: rtp, local: prepared.answer, address: address, port: prepared.port)

        guard await agent.answerIncomingCall(answer: prepared.answer.encodedData) else {
            print("❌ ответить не удалось: вызова уже нет")
            return false
        }
        print("✅ отправлен 200 OK")

        await plan.run(agent: agent, live: live)
        await agent.hangUp()

        let count = audio.map { $0.statistics.received } ?? received.value
        if let audio {
            print("   звук: \(audio.summary)")
            audio.stop()
        }
        rtp?.stop()

        print(count > 0
            ? "✅ встречный поток RTP получен: \(count) пакетов"
            : "❌ встречного потока RTP не было — медиа не дошло")
        return count > 0
    }

    /// Кадр тишины для любого согласованного кодека.
    ///
    /// Не константный байт: у G.722 постоянного байта тишины не существует —
    /// это ADPCM с состоянием, и нули в полезной нагрузке дают не тишину, а
    /// щелчки. Тишина здесь получается тем же путём, что и настоящий звук, —
    /// кодированием нулевых отсчётов.
    static func silenceFrame(for media: NegotiatedMedia) -> Data {
        var encoder = AudioFrameEncoder(codec: media.codec)
        return encoder.encode(
            [Int16](repeating: 0, count: media.codec.sampleCount(forPacketTime: media.packetTimeMilliseconds))
        )
    }

    /// Звонит и гоняет RTP.
    ///
    /// Без `--audio` звук не задействован: проверяются INVITE, согласование
    /// SDP, ACK, встречный поток RTP и BYE. С `--audio` поднимается настоящий
    /// тракт — микрофон, джиттер-буфер, звуковая карта, — и это единственный
    /// способ увидеть на длинном разговоре то, чего не покажет ни один
    /// юнит-тест: недоборы, расхождение такта и режим гарнитуры.
    ///
    /// Разрешение на микрофон у консольной программы берётся у терминала: своего
    /// бандла у неё нет. Если терминалу микрофон не разрешён, `--audio` честно
    /// об этом скажет и звонок пойдёт на тишине.
    private static func placeCall(
        agent: SIPUserAgent,
        to number: String,
        host: String,
        duration: Double,
        withAudio: Bool = false,
        narrowbandOnly: Bool = false,
        secureMedia: Bool = false,
        live: LiveMedia,
        plan: CallPlan
    ) async -> Bool {
        let address = await agent.mediaAddress ?? host
        let reservation: RTPPortReservation
        let port: UInt16
        let offer: SessionDescription
        do {
            reservation = try RTPSession.reservePortPair()
            port = reservation.rtpPort
            offer = SDPNegotiator.makeOffer(
                address: address,
                port: port,
                codecs: narrowbandOnly ? SDPNegotiator.narrowbandCodecs : SDPNegotiator.defaultCodecs,
                security: secureMedia ? .sdesRequired : .none
            )
        } catch {
            print("❌ не удалось занять порт RTP: \(error)")
            return false
        }
        defer { reservation.release() }
        print("→ звоню на \(number), локальный RTP-порт \(port), адрес в SDP \(address)")

        let received = Counter()
        var session: RTPSession?
        var audio: MediaSession?
        var heard: ToneAnalyser?
        var answered = false

        for await event in await agent.placeCall(to: number, offer: offer.encodedData).events {
            switch event {
            case .state(let state):
                print("   состояние звонка: \(state)")

            case .answered(let body, _):
                answered = true
                do {
                    let answer = try SessionDescription(parsing: body)
                    let media = try SDPNegotiator.resolveAnswer(answer, toOffer: offer)
                    print("   согласовано: \(media.security.isEncrypted ? "SRTP" : "RTP") \(media.codec.sdpName) на \(media.remoteAddress):\(media.remotePort)")

                    if withAudio {
                        guard await VoiceAudioEngine.requestMicrophoneAccess() else {
                            print("❌ микрофон не разрешён — разрешите его терминалу и повторите")
                            return false
                        }
                        let session = try MediaSession(
                            negotiated: media,
                            reservation: reservation
                        )
                        session.onDiagnostic = { print("   звук: \($0)") }
                        session.onTransportFailure = { print("   ✖ медиа: \($0)") }
                        session.onAudioEvent = { event in
                            switch event {
                            case .restarted(let reason): print("   ⟳ тракт пересобран: \(reason)")
                            case .restarting(let reason, let attempt):
                                print("   … пересобираю тракт, попытка \(attempt): \(reason)")
                            case .broken(let reason): print("   ✖ звук пропал: \(reason)")
                            case .routeChanged(let route): print("   маршрут: \(route.summary)")
                            }
                        }
                        // Что именно мы услышали. По совпадению счётчиков
                        // пакетов чужой кодер не проверишь: неверно собранный
                        // декодер отдаёт ровно столько же кадров, только шум.
                        let analyser = ToneAnalyser(sampleRate: Double(media.codec.sampleRate))
                        session.onDecodedSamples = { analyser.add($0) }
                        try session.start()
                        audio = session
                        heard = analyser
                        print("   говорите — эхо-тест вернёт голос обратно")
                    } else {
                        let rtp = try RTPSession(
                            configuration: .init(negotiated: media),
                            localPort: port,
                            remoteHost: media.remoteAddress,
                            remotePort: media.remotePort
                        )
                        rtp.onReceivedPacket = { _ in received.increment() }
                        reservation.activate()
                        rtp.start()
                        session = rtp

                        // Шлём тишину: эхо-тест вернёт её обратно, и по встречному
                        // потоку видно, что медиа-путь живой в обе стороны.
                        let silence = silenceFrame(for: media)
                        Task {
                            while !Task.isCancelled {
                                if !live.isSendingTone {
                                    rtp.send(encodedFrame: silence)
                                }
                                try? await Task.sleep(for: .milliseconds(media.packetTimeMilliseconds))
                            }
                        }
                    }
                } catch {
                    print("❌ разбор ответа SDP не удался: \(error)")
                    return false
                }

                live.install(session: audio, rtp: session, local: offer, address: address, port: port)
                await plan.run(agent: agent, live: live)
                await agent.hangUp()

            case .failed(_, let reason):
                print("❌ звонок не состоялся: \(reason)")
                return false

            case .ended(let reason):
                // Со звуком счёт принятых ведёт сам джиттер-буфер: считать те
                // же пакеты вторым счётчиком значит завести второй источник
                // правды там, где он уже есть.
                let count = audio.map { $0.statistics.received } ?? received.value
                if let audio {
                    print("   звук: \(audio.summary)")
                    if let heard { print("   услышано: \(heard.report())") }
                    audio.stop()
                }
                session?.stop()
                print("   звонок завершён: \(reason)")
                print(count > 0
                    ? "✅ встречный поток RTP получен: \(count) пакетов"
                    : "❌ встречного потока RTP не было — медиа не дошло")
                return answered && count > 0
            }
        }

        return false
    }

    private static func describe(_ state: SIPRegistrationState) -> String {
        switch state {
        case .idle: "не подключено"
        case .registering: "регистрация"
        case .registered(let expiresAt, let contact):
            "зарегистрирован до \(expiresAt.formatted(date: .omitted, time: .standard)), Contact \(contact)"
        case .unregistering: "снятие регистрации"
        case .failed(let reason, _): "ошибка — \(reason)"
        }
    }
}

/// Медиа идущего звонка — общее место для звонка и пересогласователя.
///
/// Пересогласователь ставится на агента до звонка, а дотянуться ему нужно до
/// сессии, которая появится позже. Отсюда этот ящик: без него проверить
/// серверное удержание на живом стенде нечем.
final class LiveMedia: @unchecked Sendable {

    private let lock = NSLock()
    private let codecs: [AudioCodec]

    private var session: MediaSession?
    private var rtp: RTPSession?
    private var local: SessionDescription?
    private var address = ""
    private var port: UInt16 = 0
    private var sendingTone = false

    init(codecs: [AudioCodec]) {
        self.codecs = codecs
    }

    /// Список кодеков, с которым собран этот прогон. Многолинейной проверке
    /// нужен тот же самый: разные списки у линий означали бы разные разговоры.
    var supportedCodecs: [AudioCodec] { codecs }

    /// Идёт событие DTMF: кадры звука в этот момент отправлять нельзя.
    ///
    /// В `MediaSession` этот запрет встроен, а здесь поток тишины гоняет
    /// отдельная задача, и без флага она двигает метку времени посреди тона.
    /// Asterisk читает это как конец одного события и начало нового —
    /// и слышит лишнюю цифру. Проверено на 603: «4915» доехало как «49155».
    var isSendingTone: Bool {
        get { lock.withLock { sendingTone } }
        set { lock.withLock { sendingTone = newValue } }
    }

    func install(
        session: MediaSession?,
        rtp: RTPSession?,
        local: SessionDescription,
        address: String,
        port: UInt16
    ) {
        lock.withLock {
            self.session = session
            self.rtp = rtp
            self.local = local
            self.address = address
            self.port = port
        }
    }

    var localDescription: SessionDescription? { lock.withLock { local } }
    var mediaSession: MediaSession? { lock.withLock { session } }
    var rtpSession: RTPSession? { lock.withLock { rtp } }

    func remember(local description: SessionDescription) {
        lock.withLock { local = description }
    }

    /// Ответ на чужой повторный INVITE. Тот же путь, что в приложении.
    func renegotiate(offer body: Data) -> Data? {
        let state = lock.withLock { (session, local, address, port) }
        guard state.1 != nil else { return nil }

        do {
            let offer = try SessionDescription(parsing: body)
            let negotiated = try SDPNegotiator.makeAnswer(
                to: offer,
                address: state.2,
                port: state.3,
                supported: codecs,
                localKey: state.0?.negotiated?.security.localKey
            )
            print("← повторный INVITE: \(negotiated.media.direction.rawValue) "
                + "\(negotiated.media.remoteAddress):\(negotiated.media.remotePort)"
                + (negotiated.media.isHeld ? " — нас поставили на удержание" : ""))

            if let session = state.0 {
                let outcome = try session.renegotiate(to: negotiated.media)
                if outcome == .streamRebuilt { print("   поток RTP пересобран") }
                session.isMicrophoneMuted = negotiated.media.isHeld
            }
            lock.withLock { local = negotiated.answer }
            return negotiated.answer.encodedData
        } catch {
            print("❌ пересогласование отклонено: \(error)")
            return nil
        }
    }
}

/// Что делать внутри разговора: подождать, поставить на удержание, набрать тоны.
struct CallPlan: Sendable {

    let duration: Double
    let dtmf: String?
    let dtmfAfter: Double?
    let holdAfter: Double?

    func run(agent: SIPUserAgent, live: LiveMedia) async {
        // Ждём, пока на той стороне будет кому слушать.
        //
        // Момент важен и настраивается: голосовое меню начинает принимать
        // цифры не с первой секунды, а после приглашения. Тон, отправленный
        // раньше, просто пропадает — и выглядит это как неработающий DTMF.
        // На стенде 603 (Read с приглашением) верный момент — около четырёх
        // секунд, по умолчанию берём одну.
        let settle = dtmfAfter ?? min(1.0, duration / 4)
        try? await Task.sleep(for: .seconds(settle))

        if let dtmf {
            await send(dtmf: dtmf, live: live)
        }

        if let holdAfter {
            await hold(agent: agent, live: live, seconds: holdAfter)
        }

        let spent = settle + (holdAfter ?? 0)
        if spent < duration {
            try? await Task.sleep(for: .seconds(duration - spent))
        }
    }

    private func send(dtmf text: String, live: LiveMedia) async {
        let sequence = DTMFSequence(text)
        guard sequence.hasTones else {
            print("❌ в наборе «\(text)» нет ни одного тона")
            return
        }

        if let session = live.mediaSession {
            guard session.send(dtmf: sequence) else {
                print("❌ собеседник не подтвердил telephone-event — тоны отправить нечем")
                return
            }
            print("→ тоны \(sequence.displayText) отправлены")
            return
        }

        // Без --audio сессии звука нет, а проверить DTMF всё равно надо: на
        // headless-машине микрофона может не быть вовсе. Раскладка та же самая.
        guard let rtp = live.rtpSession else { return }
        live.isSendingTone = true
        defer { live.isSendingTone = false }

        for action in DTMFPlanner.actions(for: sequence) {
            switch action {
            case .wait(let milliseconds):
                try? await Task.sleep(for: .milliseconds(milliseconds))
            case .packet(let packet):
                rtp.send(event: packet.payload, isFirst: packet.isFirst)
                if packet.completesEvent {
                    rtp.finishEvent(advancingTimestampBy: packet.timestampAdvance)
                }
            }
        }
        print("→ тоны \(sequence.displayText) отправлены")
    }

    private func hold(agent: SIPUserAgent, live: LiveMedia, seconds: Double) async {
        guard let local = live.localDescription else { return }

        do {
            let held = SDPNegotiator.makeReoffer(from: local, direction: .sendonly)
            _ = try await agent.reinvite(offer: held.encodedData)
            live.remember(local: held)
            live.mediaSession?.isHeld = true
            print("→ разговор на удержании, вернём через \(Int(seconds)) с")

            try? await Task.sleep(for: .seconds(seconds))

            let resumed = SDPNegotiator.makeReoffer(from: held, direction: .sendrecv)
            let answer = try await agent.reinvite(offer: resumed.encodedData)
            live.remember(local: resumed)
            live.mediaSession?.isHeld = false

            if !answer.isEmpty, let session = live.mediaSession {
                let negotiated = try SDPNegotiator.resolveAnswer(
                    try SessionDescription(parsing: answer), toOffer: resumed
                )
                let outcome = try session.renegotiate(to: negotiated)
                if outcome == .streamRebuilt {
                    print("   поток RTP пересобран на \(negotiated.remoteAddress):\(negotiated.remotePort)")
                }
            }
            print("✅ возврат с удержания")
        } catch {
            print("❌ удержание не удалось: \(error)")
        }
    }
}

/// Разбор аргументов вида `--ключ значение` и `--флаг`.
private struct Arguments {

    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ raw: [String]) {
        var index = 1
        while index < raw.count {
            let token = raw[index]
            guard token.hasPrefix("--") else {
                index += 1
                continue
            }
            let name = String(token.dropFirst(2))
            let next = index + 1 < raw.count ? raw[index + 1] : nil
            if let next, !next.hasPrefix("--") {
                values[name] = next
                index += 2
            } else {
                flags.insert(name)
                index += 1
            }
        }
    }

    subscript(_ name: String) -> String? { values[name] }

    func hasFlag(_ name: String) -> Bool { flags.contains(name) }
}

/// Потокобезопасный счётчик: пакеты считаются на очереди RTP-сессии.
/// Место под входящий звонок.
///
/// Существует потому, что входящий приезжает в общий поток событий агента, а
/// ждать его надо в другом месте. Актор, а не мьютекс с семафором: звонок может
/// прийти и до того, как его начали ждать, и это нормальный случай — сервер
/// звонит, когда захочет.
private actor IncomingSlot {

    private var pending: SIPIncomingCall?
    private var waiter: CheckedContinuation<SIPIncomingCall?, Never>?

    func deliver(_ call: SIPIncomingCall) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: call)
        } else {
            pending = call
        }
    }

    func wait(timeout: Double) async -> SIPIncomingCall? {
        if let pending {
            self.pending = nil
            return pending
        }

        let timer = Task {
            try? await Task.sleep(for: .seconds(timeout))
            self.giveUp()
        }
        defer { timer.cancel() }

        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    private func giveUp() {
        guard let waiter else { return }
        self.waiter = nil
        waiter.resume(returning: nil)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock { count += 1 }
    }

    var value: Int {
        lock.withLock { count }
    }
}

/// Что приехало в звуке: уровень и на какой частоте сосредоточена энергия.
///
/// Нужен для проверки чужого кодера. Наши тесты доказывают, что наш декодер
/// обращает наш кодер, но не то, что он понимает Asterisk: ошибка в таблице или
/// в сдвиге может быть самосогласованной. А вот тон 1004 Гц, сгенерированный
/// Asterisk и разобранный нами, проверяет именно стык.
final class ToneAnalyser: @unchecked Sendable {

    private let lock = NSLock()
    private let sampleRate: Double
    private var samples: [Double] = []
    private var peak = 0.0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    func add(_ block: [Int16]) {
        lock.withLock {
            for value in block {
                let scaled = Double(value) / 32768
                peak = max(peak, abs(scaled))
                // Двух секунд с запасом хватает на разбор, а расти без предела
                // диагностике незачем.
                if samples.count < Int(sampleRate) * 2 { samples.append(scaled) }
            }
        }
    }

    func report() -> String {
        let (block, level) = lock.withLock { (samples, peak) }
        // Начало пропускаем: там ещё тишина до первого пакета.
        let usable = Array(block.dropFirst(block.count / 4))
        guard usable.count > 1000 else { return "звука не было" }

        var best = (frequency: 0.0, magnitude: 0.0)
        for frequency in stride(from: 100.0, through: min(7000, sampleRate / 2 - 200), by: 4) {
            let magnitude = goertzel(usable, frequency: frequency)
            if magnitude > best.magnitude { best = (frequency, magnitude) }
        }

        let total = sqrt(usable.reduce(0) { $0 + $1 * $1 } / Double(usable.count))
        // Доля энергии в найденном тоне: у чистого синуса она близка к единице,
        // у мусора расползается по всему спектру.
        let purity = best.magnitude / (total * sqrt(2))
        // Амплитуда самого тона, а не пик отсчётов: пик зависит от того,
        // попал ли отсчёт на вершину синуса, и врёт тем сильнее, чем выше
        // частота относительно выборки.
        return String(
            format: "тон %.0f Гц, амплитуда %.4f (%+.2f дБ), пик %.3f, чистота %.0f %%",
            best.frequency, best.magnitude, 20 * log10(max(best.magnitude, 1e-9)),
            level, purity * 100
        )
    }

    private func goertzel(_ values: [Double], frequency: Double) -> Double {
        let omega = 2 * Double.pi * frequency / sampleRate
        let coefficient = 2 * cos(omega)
        var previous = 0.0
        var beforePrevious = 0.0
        for value in values {
            let current = value + coefficient * previous - beforePrevious
            beforePrevious = previous
            previous = current
        }
        let real = previous - beforePrevious * cos(omega)
        let imaginary = beforePrevious * sin(omega)
        return 2 * sqrt(real * real + imaginary * imaginary) / Double(values.count)
    }
}
