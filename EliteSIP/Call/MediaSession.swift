import Foundation
import MediaCore

/// Медиа-половина разговора: RTP, джиттер-буфер и аудиотракт вместе.
///
/// Живёт в приложении, а не в пакете, намеренно. SIPCore принимает и отдаёт тело
/// SDP байтами и о кодеках ничего не знает, MediaCore ничего не знает о SIP —
/// склейку делает тот, кто знает про обе стороны. Благодаря этому оба пакета
/// тестируются по отдельности и без звуковой карты.
final class MediaSession: @unchecked Sendable {

    /// Собирает предложение SDP и занимает порт под RTP.
    ///
    /// Порт занимается ДО отправки INVITE: номер порта уходит в предложении, и
    /// узнать его потом уже негде.
    /// Возвращается сам объект предложения, а не только байты: разбор ответа
    /// сверяется с ним, чтобы понять итоговое направление потока.
    static func makeOffer(localAddress: String) throws -> (offer: SessionDescription, port: UInt16) {
        let port = try RTPSession.reserveEvenPort()
        return (SDPNegotiator.makeOffer(address: localAddress, port: port), port)
    }

    private let configuration: RTPSession.Configuration
    private let engine: VoiceAudioEngine
    private let rtp: RTPSession

    /// Джиттер-буфер трогают два потока: приём RTP и такт воспроизведения.
    private let bufferLock = NSLock()
    private var jitter: JitterBuffer

    private var playoutTask: Task<Void, Never>?

    init(negotiated: NegotiatedMedia, localPort: UInt16) throws {
        configuration = RTPSession.Configuration(negotiated: negotiated)

        jitter = JitterBuffer(
            codec: negotiated.codec,
            packetTimeMilliseconds: negotiated.packetTimeMilliseconds
        )
        engine = try VoiceAudioEngine(configuration: .init(
            codec: negotiated.codec,
            packetTimeMilliseconds: negotiated.packetTimeMilliseconds
        ))
        rtp = RTPSession(
            configuration: configuration,
            localPort: localPort,
            remoteHost: negotiated.remoteAddress,
            remotePort: negotiated.remotePort
        )
    }

    func start() throws {
        rtp.onReceivedPacket = { [weak self] packet in
            guard let self else { return }
            // События DTMF в звук не отдаём: их полезная нагрузка — не аудио, и
            // декодированная как G.711 она превратится в громкий треск.
            if let eventType = configuration.telephoneEventPayloadType, packet.payloadType == eventType {
                return
            }
            bufferLock.withLock { jitter.push(packet) }
        }

        engine.onEncodedFrame = { [weak self] frame in
            self?.rtp.send(encodedFrame: frame)
        }

        rtp.start()
        try engine.start()
        startPlayout()
    }

    func stop() {
        playoutTask?.cancel()
        playoutTask = nil
        engine.stop()
        rtp.stop()
        bufferLock.withLock { jitter.reset() }
    }

    /// Такт воспроизведения: раз в packet time забирает кадр из буфера.
    ///
    /// Отдельный такт, а не выдача кадра прямо по приходу пакета: смысл
    /// джиттер-буфера именно в том, чтобы разорвать связь между неровным
    /// приходом из сети и ровным воспроизведением.
    private func startPlayout() {
        let interval = Duration.milliseconds(configuration.packetTimeMilliseconds)

        playoutTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self else { return }

                let frame = bufferLock.withLock { jitter.pop() }
                if let frame {
                    engine.enqueue(encodedFrame: frame.payload)
                }
            }
        }
    }

    // MARK: - Диагностика

    var statistics: JitterBuffer.Statistics {
        bufferLock.withLock { jitter.statistics }
    }

    var summary: String {
        let stats = statistics
        return "принято \(stats.received), потеряно \(stats.concealed), не по порядку \(stats.reordered), недоборов \(stats.underruns)"
    }
}
