import Foundation
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

        let deadline = Date().addingTimeInterval(duration)
        var registered = false
        while Date() < deadline {
            if await agent.registrationState.isRegistered {
                registered = true
            }
            try? await Task.sleep(for: .milliseconds(200))
        }

        let finalState = await agent.registrationState
        await agent.stop()
        printer.cancel()

        print(registered ? "✅ регистрация прошла" : "❌ регистрация не прошла: \(describe(finalState))")
        exit(registered ? 0 : 1)
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
