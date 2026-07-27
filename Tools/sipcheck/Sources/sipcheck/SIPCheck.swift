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

        let printer = Task {
            for await event in agent.events {
                switch event {
                case .registration(let state):
                    print("   состояние: \(describe(state))")
                case .log(let level, let message):
                    print("   [\(level.rawValue)] \(message)")
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

        var callSucceeded = true
        if let number = arguments["call"] {
            callSucceeded = await placeCall(agent: agent, to: number, host: host, duration: duration)
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

    /// Звонит и гоняет RTP без микрофона.
    ///
    /// Звук здесь намеренно не задействован: у консольной программы нет бандла,
    /// а значит и разрешения на микрофон. Зато проверяется всё остальное —
    /// INVITE, согласование SDP, ACK, встречный поток RTP и BYE. «Слышно себя»
    /// проверяется в приложении, это единственное, что нельзя автоматизировать.
    private static func placeCall(
        agent: SIPUserAgent,
        to number: String,
        host: String,
        duration: Double
    ) async -> Bool {
        let address = await agent.mediaAddress ?? host
        let port: UInt16
        let offer: SessionDescription
        do {
            port = try RTPSession.reserveEvenPort()
            offer = SDPNegotiator.makeOffer(address: address, port: port)
        } catch {
            print("❌ не удалось занять порт RTP: \(error)")
            return false
        }
        print("→ звоню на \(number), локальный RTP-порт \(port), адрес в SDP \(address)")

        let received = Counter()
        var session: RTPSession?
        var answered = false

        for await event in await agent.placeCall(to: number, offer: offer.encodedData) {
            switch event {
            case .state(let state):
                print("   состояние звонка: \(state)")

            case .answered(let body, _):
                answered = true
                do {
                    let answer = try SessionDescription(parsing: body)
                    let media = try SDPNegotiator.resolveAnswer(answer, toOffer: offer)
                    print("   согласовано: \(media.codec.sdpName) на \(media.remoteAddress):\(media.remotePort)")

                    let rtp = RTPSession(
                        configuration: .init(negotiated: media),
                        localPort: port,
                        remoteHost: media.remoteAddress,
                        remotePort: media.remotePort
                    )
                    rtp.onReceivedPacket = { _ in received.increment() }
                    rtp.start()
                    session = rtp

                    // Шлём тишину: эхо-тест вернёт её обратно, и по встречному
                    // потоку видно, что медиа-путь живой в обе стороны.
                    let silence = Data(
                        repeating: G711.silenceByte(for: media.codec),
                        count: media.codec.byteCount(forPacketTime: media.packetTimeMilliseconds)
                    )
                    Task {
                        while !Task.isCancelled {
                            rtp.send(encodedFrame: silence)
                            try? await Task.sleep(for: .milliseconds(media.packetTimeMilliseconds))
                        }
                    }
                } catch {
                    print("❌ разбор ответа SDP не удался: \(error)")
                    return false
                }

                try? await Task.sleep(for: .seconds(duration))
                await agent.hangUp()

            case .failed(_, let reason):
                print("❌ звонок не состоялся: \(reason)")
                return false

            case .ended(let reason):
                session?.stop()
                let count = received.value
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
