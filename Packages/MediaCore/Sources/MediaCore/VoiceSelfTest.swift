import Compat
import Foundation

/// Самопроверка голоса: записать пять секунд и сразу их воспроизвести.
///
/// **Зачем именно так.** Менеджеру нужно ответить на один вопрос — «меня
/// слышно и я слышу?» — не звоня коллеге и не дёргая поддержку. Проверка идёт
/// через тот же `VoiceAudioEngine`, что и разговор: то же выбранное
/// устройство, то же приватное агрегатное устройство при разных сторонах, тот
/// же блок обработки голоса и тот же кодек. Отдельный `AVAudioEngine` был бы
/// проще, но проверял бы не то, что ломается: ломается связка «выбранный
/// микрофон + выбранный динамик + обработка голоса», а не умение macOS писать
/// звук.
///
/// Запись живёт в памяти и стирается вместе с объектом — на диск не попадает
/// ничего. Это не мелочь: в пяти секундах вполне может оказаться чужой голос.
public final class VoiceSelfTest: @unchecked Sendable {

    public enum Phase: Sendable, Equatable {
        case idle
        /// Идёт запись. Число — сколько секунд осталось, для обратного отсчёта.
        case recording(remainingSeconds: Int)
        case playing
        case finished
        case failed(String)
    }

    /// Сколько секунд пишем. Пять — согласовано: хватает на фразу и не успевает
    /// надоесть.
    public static let recordingSeconds = 5

    /// Смена этапа. Вызывается на главной очереди — этим состоянием крутится
    /// интерфейс.
    public var onPhase: (@Sendable (Phase) -> Void)?

    /// Подробности в журнал.
    public var onDiagnostic: (@Sendable (String) -> Void)?

    private let bus: VoiceAudioBus
    private let configuration: VoiceAudioEngine.Configuration
    private var token: VoiceAudioBus.Token { ObjectIdentifier(self) }
    private let frameCapacity: Int

    /// Записанное и позиция воспроизведения под одним замком: их трогают два
    /// разных потока звука — захвата и подачи.
    private let state = UnfairLock(initialState: State())

    private struct State: Sendable {
        var frames: [Data] = []
        var playbackIndex = 0
        var isRecording = false
        var isPlaying = false
    }

    /// Собирает проверку под те же настройки звука, с которыми идёт разговор,
    /// и на том же общем тракте.
    ///
    /// `releasesDeviceWhenIdle` намеренно оставлен как в настройках: если у
    /// человека Bluetooth-гарнитура и приложение отпускает её между звонками,
    /// проверка обязана пройти тот же путь захвата устройства, что и звонок, —
    /// иначе она подтвердит работоспособность того, чего в звонке не будет.
    ///
    /// Общий тракт вместо своего движка — это ещё и единственный способ
    /// гарантировать, что проверка и разговор не откроют устройство
    /// одновременно: владелец у тракта один, и он же решает, кому отказать.
    public init(bus: VoiceAudioBus, configuration: VoiceAudioEngine.Configuration) throws {
        self.bus = bus
        self.configuration = configuration
        let packetTime = max(configuration.packetTimeMilliseconds, 1)
        frameCapacity = VoiceSelfTest.recordingSeconds * 1000 / packetTime
    }

    /// Просит доступ к микрофону — тем же способом, что и звонок.
    public static func requestMicrophoneAccess() async -> Bool {
        await VoiceAudioEngine.requestMicrophoneAccess()
    }

    /// Начинает запись. Воспроизведение начнётся само, как только наберётся
    /// пять секунд.
    public func start() {
        state.withLock {
            $0.frames.removeAll(keepingCapacity: true)
            $0.playbackIndex = 0
            $0.isRecording = true
            $0.isPlaying = false
        }

        var handlers = VoiceAudioBus.Handlers()
        handlers.diagnostic = { [weak self] message in
            self?.onDiagnostic?(message)
        }

        handlers.encodedFrame = { [weak self] frame in
            guard let self else { return }
            let finished: Bool = state.withLock {
                guard $0.isRecording else { return false }
                $0.frames.append(frame)
                guard $0.frames.count >= frameCapacity else { return false }
                $0.isRecording = false
                $0.isPlaying = true
                return true
            }
            if finished {
                report(.playing)
            } else {
                reportRemainingSeconds()
            }
        }

        handlers.needsFrame = { [weak self] in
            guard let self else { return nil }
            let payload: Data? = state.withLock { state -> Data? in
                guard state.isPlaying, state.playbackIndex < state.frames.count else { return nil }
                defer { state.playbackIndex += 1 }
                return state.frames[state.playbackIndex]
            }
            if let payload {
                return VoiceAudioEngine.PlaybackFrame(payload: payload, isConcealment: false)
            }
            // Дошли до конца записи — но только если играли. Пока идёт запись,
            // играть нечего, и это тоже nil.
            let wasPlaying: Bool = state.withLock {
                guard $0.isPlaying else { return false }
                $0.isPlaying = false
                return true
            }
            // Отпускать тракт прямо отсюда нельзя: этот обработчик вызывает
            // поток подачи, а остановка его же и дожидается. Раньше это сходило
            // с рук — остановка потока не ждала, — но ждать её пришлось
            // научить: перенастройка общего движка меняет кодеки, и делать это
            // под работающим потоком нельзя. Уводим завершение на главную
            // очередь: там оно никому не мешает.
            if wasPlaying {
                DispatchQueue.main.async { [weak self] in self?.finish() }
            }
            return nil
        }

        do {
            try bus.claim(token, configuration: configuration, handlers: handlers)
            report(.recording(remainingSeconds: VoiceSelfTest.recordingSeconds))
        } catch {
            state.withLock { $0.isRecording = false }
            report(.failed(error.localizedDescription))
        }
    }

    /// Прекращает проверку и забывает запись.
    ///
    /// Вызывается и кнопкой «Остановить», и при уходе с экрана: держать
    /// открытым микрофон, который никто не слушает, нельзя — на гарнитуре это
    /// приглушает звук всей системы.
    public func cancel() {
        let wasActive: Bool = state.withLock {
            let active = $0.isRecording || $0.isPlaying
            $0.isRecording = false
            $0.isPlaying = false
            $0.frames.removeAll()
            $0.playbackIndex = 0
            return active
        }
        bus.release(token)
        if wasActive { report(.idle) }
    }

    private func finish() {
        bus.release(token)
        state.withLock { $0.frames.removeAll() }
        report(.finished)
    }

    /// Обратный отсчёт считается по числу записанных кадров, а не по таймеру:
    /// кадры приходят от звуковой карты, и если она встала, отсчёт обязан
    /// встать вместе с ней, а не дорисовать нули на экране.
    private func reportRemainingSeconds() {
        let captured = state.withLock { $0.frames.count }
        let perSecond = max(frameCapacity / VoiceSelfTest.recordingSeconds, 1)
        let elapsed = captured / perSecond
        let remaining = max(VoiceSelfTest.recordingSeconds - elapsed, 0)
        report(.recording(remainingSeconds: remaining))
    }

    private func report(_ phase: Phase) {
        let handler = onPhase
        DispatchQueue.main.async { handler?(phase) }
    }

    deinit {
        bus.release(token)
    }
}
