import Foundation
import MediaCore

/// Живые уровни в разделе «Звук»: микрофон отвечает на голос, наушники — на
/// проверочный звук. Разбор — у `VoiceLevelMonitor`.
///
/// Монитор живёт, пока раздел на экране и тракт никому больше не нужен.
/// Звонок и самопроверка вытесняют его, а по их окончании он возвращается сам:
/// решение принимается в одном месте, `refreshLevelMonitor`, по трём фактам —
/// раздел открыт, линий нет, самопроверка не идёт.
extension AppModel {

    /// Раздел «Звук» появился или ушёл с экрана.
    func setAudioSettingsVisible(_ visible: Bool) {
        guard isAudioSettingsVisible != visible else { return }
        isAudioSettingsVisible = visible
        refreshLevelMonitor()
    }

    /// Показывать ли полоски уровня: есть чем мерить.
    var showsAudioLevels: Bool { isInCall || isSelfTestRunning || isLevelMonitorRunning }

    func refreshLevelMonitor() {
        let wanted = isAudioSettingsVisible && !isInCall && !isSelfTestRunning
        if wanted, levelMonitor == nil, !isLevelMonitorStarting {
            startLevelMonitor()
        } else if !wanted {
            stopLevelMonitor()
        }
    }

    /// Устройство или обработка сменились — тракт надо собрать заново.
    func restartLevelMonitorIfRunning() {
        guard levelMonitor != nil else { return }
        stopLevelMonitor()
        refreshLevelMonitor()
    }

    func playTestSound() {
        guard let levelMonitor else { return }
        levelMonitor.playTestSound()
        isTestSoundPlaying = true
    }

    private func startLevelMonitor() {
        isLevelMonitorStarting = true
        Task { @MainActor in
            defer { isLevelMonitorStarting = false }
            guard await VoiceSelfTest.requestMicrophoneAccess() else {
                levelMonitorProblem = NSLocalizedString(
                    "Нет доступа к микрофону. Разрешите его в «Защите и безопасности».",
                    comment: "индикатор уровня в настройках звука"
                )
                return
            }
            // Пока спрашивали доступ, раздел могли закрыть или начаться звонок.
            guard isAudioSettingsVisible, !isInCall, !isSelfTestRunning, levelMonitor == nil else { return }
            do {
                let monitor = VoiceLevelMonitor(
                    bus: try voiceBus(),
                    configuration: VoiceAudioEngine.Configuration(
                        inputDeviceUID: settings.audio.inputDeviceUID,
                        outputDeviceUID: settings.audio.outputDeviceUID,
                        releasesDeviceWhenIdle: settings.audio.releasesDeviceWhenIdle,
                        automaticGainControl: settings.audio.automaticGainControl,
                        microphoneGain: Float(settings.audio.microphoneGain),
                        playbackVolume: Float(settings.audio.playbackVolume)
                    )
                )
                monitor.onDiagnostic = { [weak self] text in
                    Task { @MainActor in self?.append(level: .debug, message: "индикатор: \(text)") }
                }
                monitor.onTestSoundFinished = { [weak self] in
                    Task { @MainActor in self?.isTestSoundPlaying = false }
                }
                try monitor.start()
                levelMonitor = monitor
                levelMonitorProblem = nil
                isLevelMonitorRunning = true
                startLevelMonitorPolling(of: monitor)
            } catch {
                levelMonitorProblem = String(
                    format: NSLocalizedString("Индикатор не запустился: %@", comment: "индикатор уровня в настройках звука"),
                    error.localizedDescription
                )
                append(level: .warning, message: "индикатор уровня не запустился: \(error.localizedDescription)")
            }
        }
    }

    private func stopLevelMonitor() {
        levelMonitorTask?.cancel()
        levelMonitorTask = nil
        isTestSoundPlaying = false
        guard let monitor = levelMonitor else { return }
        levelMonitor = nil
        isLevelMonitorRunning = false
        monitor.stop()
        // Сброс только если уровни не перешли к звонку или самопроверке:
        // их опрос пишет туда же, и обнулять чужие значения незачем.
        if !isInCall, !isSelfTestRunning { audioLevels.reset() }
    }

    /// Тот же шаг в 50 мс, что у разговора и самопроверки: индикатор один.
    private func startLevelMonitorPolling(of monitor: VoiceLevelMonitor) {
        levelMonitorTask?.cancel()
        levelMonitorTask = Task { [weak self, weak monitor] in
            while !Task.isCancelled {
                try? await Task.sleep(.milliseconds(50))
                guard let self, let monitor else { return }
                guard monitor.isActive else {
                    // Тракт забрали мимо нас — звонок пришёл раньше, чем
                    // `lines` успел смениться. Забрать его обратно решит
                    // `refreshLevelMonitor`, когда звонок кончится.
                    continue
                }
                audioLevels.update(input: monitor.inputLevel, output: monitor.outputLevel)
            }
        }
    }
}
