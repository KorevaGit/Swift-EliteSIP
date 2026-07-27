import CryptoKit
import Foundation
import Network

/// Транспорт на Network.framework: UDP или TLS.
///
/// Класс помечен `@unchecked Sendable` осознанно. Вся изменяемая часть (фреймер,
/// локальный адрес, флаги) трогается только из обработчиков `NWConnection`,
/// а они приходят на одну и ту же последовательную очередь `queue`. Actor здесь
/// был бы хуже: у Network.framework колбэчная модель, и каждый колбэк пришлось бы
/// заворачивать в `Task`, что переупорядочивает приём пакетов.
public final class NetworkSIPTransport: SIPTransportChannel, @unchecked Sendable {

    public let transport: SIPTransport
    public let remote: SIPEndpoint
    public let events: AsyncStream<SIPTransportEvent>

    private let continuation: AsyncStream<SIPTransportEvent>.Continuation
    private let queue = DispatchQueue(label: "com.elite.EliteSIP.sip-transport")
    private let connection: NWConnection

    /// Только для потокового транспорта. На UDP датаграмма и есть сообщение.
    private var framer = SIPMessageFramer()
    private var didReportReady = false
    private var isStopped = false

    public init(
        remote: SIPEndpoint,
        transport: SIPTransport,
        tlsTrust: SIPTLSTrust = .system,
        serverName: String? = nil
    ) {
        self.transport = transport
        self.remote = remote

        let (stream, continuation) = AsyncStream<SIPTransportEvent>.makeStream(
            // Буфер с запасом: терять сигнализацию из-за переполнения нельзя,
            // а держать её бесконечно — способ съесть память на флуде.
            bufferingPolicy: .bufferingNewest(256)
        )
        self.events = stream
        self.continuation = continuation

        let parameters: NWParameters
        switch transport {
        case .udp:
            parameters = .udp
        case .tcp:
            parameters = .tcp
        case .tls:
            parameters = NWParameters(
                tls: Self.tlsOptions(trust: tlsTrust, serverName: serverName ?? remote.host),
                tcp: NWProtocolTCP.Options()
            )
        }

        // Не запрещаем ни один тип интерфейса: удалённые сотрудники ходят через
        // VPN, и отсечь его случайно нельзя.
        parameters.prohibitedInterfaceTypes = []

        connection = NWConnection(
            host: NWEndpoint.Host(remote.host),
            port: NWEndpoint.Port(rawValue: remote.port) ?? (transport == .tls ? 5061 : 5060),
            using: parameters
        )
    }

    // MARK: - Жизненный цикл

    public func start() async {
        connection.stateUpdateHandler = { [weak self] state in
            self?.handle(state: state)
        }
        connection.start(queue: queue)
    }

    public func stop() async {
        queue.sync {
            guard !isStopped else { return }
            isStopped = true
            connection.stateUpdateHandler = nil
            connection.cancel()
            continuation.yield(.cancelled)
            continuation.finish()
        }
    }

    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    // MARK: - Обработчики

    private func handle(state: NWConnection.State) {
        switch state {
        case .ready:
            guard !didReportReady else { return }
            didReportReady = true
            continuation.yield(.ready(local: localEndpoint()))
            receiveNext()

        case .failed(let error):
            continuation.yield(.failed(reason: error.localizedDescription))
            continuation.finish()

        case .cancelled:
            continuation.yield(.cancelled)
            continuation.finish()

        case .waiting(let error):
            // waiting — это «сети сейчас нет», не окончательный отказ.
            // Network.framework сам повторит попытку, поэтому канал не рвём.
            continuation.yield(.failed(reason: "ожидание сети: \(error.localizedDescription)"))

        case .setup, .preparing:
            break

        @unknown default:
            break
        }
    }

    private func localEndpoint() -> SIPEndpoint {
        if case .hostPort(let host, let port) = connection.currentPath?.localEndpoint {
            let text: String
            switch host {
            case .ipv4(let address): text = "\(address)"
            case .ipv6(let address): text = "\(address)".components(separatedBy: "%").first ?? "\(address)"
            case .name(let name, _): text = name
            @unknown default: text = "0.0.0.0"
            }
            return SIPEndpoint(host: text, port: port.rawValue)
        }
        return SIPEndpoint(host: "0.0.0.0", port: 0)
    }

    private func receiveNext() {
        if transport == .udp {
            connection.receiveMessage { [weak self] data, _, isComplete, error in
                self?.handleReceived(data: data, error: error, isComplete: isComplete)
            }
        } else {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                self?.handleReceived(data: data, error: error, isComplete: isComplete)
            }
        }
    }

    private func handleReceived(data: Data?, error: NWError?, isComplete: Bool) {
        if let error {
            continuation.yield(.failed(reason: error.localizedDescription))
            continuation.finish()
            return
        }

        if let data, !data.isEmpty {
            if transport == .udp {
                // Одна датаграмма — одно сообщение. Фреймер тут не нужен и
                // только мешал бы: датаграмма без Content-Length законна.
                continuation.yield(.received(data))
            } else {
                framer.append(data)
                do {
                    while let message = try framer.nextMessageData() {
                        continuation.yield(.received(message))
                    }
                } catch {
                    continuation.yield(.failed(reason: "поток испорчен: \(error)"))
                    continuation.finish()
                    return
                }
            }
        }

        // isComplete на потоковом соединении означает закрытие с другой стороны.
        if isComplete, transport != .udp {
            continuation.yield(.cancelled)
            continuation.finish()
            return
        }

        guard !isStopped else { return }
        receiveNext()
    }

    // MARK: - TLS

    private static func tlsOptions(trust: SIPTLSTrust, serverName: String) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions

        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        if !serverName.isEmpty {
            sec_protocol_options_set_tls_server_name(security, serverName)
        }

        switch trust {
        case .system:
            break

        case .pinnedCertificateSHA256(let fingerprints):
            sec_protocol_options_set_verify_block(security, { _, secTrust, complete in
                let trustRef = sec_trust_copy_ref(secTrust).takeRetainedValue()
                guard let chain = SecTrustCopyCertificateChain(trustRef) as? [SecCertificate],
                      let leaf = chain.first
                else {
                    complete(false)
                    return
                }
                let der = SecCertificateCopyData(leaf) as Data
                let digest = Data(SHA256.hash(data: der))
                complete(fingerprints.contains(digest))
            }, DispatchQueue(label: "com.elite.EliteSIP.tls-verify"))

        case .acceptAnyCertificateInsecurely:
            sec_protocol_options_set_verify_block(security, { _, _, complete in
                complete(true)
            }, DispatchQueue(label: "com.elite.EliteSIP.tls-verify"))
        }

        return options
    }
}
