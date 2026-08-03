import Foundation
import MediaCore

/// Самопроверка звука на менеджерской странице.
///
/// Отдельным файлом по той же причине, что и административный режим: у этой
/// функции своя цель — дать человеку ответить на «меня слышно?» самому, — и
/// смешивать её с обработкой разговора незачем.
extension AppModel {

    /// Идёт ли проверка прямо сейчас.
    var isSelfTestRunning: Bool {
        switch selfTestPhase {
        case .recording, .playing: true
        case .idle, .finished, .failed: false
        }
    }

    /// Можно ли её начать.
    ///
    /// В разговоре нельзя: устройство занято трактом, и вторая попытка его
    /// открыть либо не удастся, либо отберёт микрофон у живого звонка.
    var canStartSelfTest: Bool { !isInCall && !isSelfTestRunning }

    /// Записать пять секунд и сразу их воспроизвести.
    func startVoiceSelfTest() {
        guard canStartSelfTest else { return }

        Task { @MainActor in
            guard await VoiceSelfTest.requestMicrophoneAccess() else {
                selfTestPhase = .failed("Нет доступа к микрофону. Разрешите его в «Защите и безопасности».")
                return
            }

            do {
                // Те же настройки, что у разговора: проверка обязана пройти
                // ровно тот путь, который потом сломается или не сломается.
                let test = try VoiceSelfTest(
                    configuration: VoiceAudioEngine.Configuration(
                        inputDeviceUID: settings.audio.inputDeviceUID,
                        outputDeviceUID: settings.audio.outputDeviceUID,
                        releasesDeviceWhenIdle: settings.audio.releasesDeviceWhenIdle,
                        automaticGainControl: settings.audio.automaticGainControl
                    )
                )
                test.onDiagnostic = { [weak self] text in
                    Task { @MainActor in self?.append(level: .debug, message: "самопроверка: \(text)") }
                }
                test.onPhase = { [weak self] phase in
                    Task { @MainActor in self?.selfTestPhase = phase }
                }
                selfTest = test
                append(level: .info, message: "самопроверка звука: запись \(VoiceSelfTest.recordingSeconds) с")
                test.start()
            } catch {
                selfTestPhase = .failed(error.localizedDescription)
                append(level: .error, message: "самопроверка звука не запустилась: \(error.localizedDescription)")
            }
        }
    }

    /// Остановить и забыть запись.
    func cancelVoiceSelfTest() {
        selfTest?.cancel()
        selfTest = nil
        selfTestPhase = .idle
    }

    /// Что показать под кнопкой.
    var selfTestStatus: String? {
        switch selfTestPhase {
        case .idle:
            nil
        case .recording(let remaining):
            "Говорите — запись, осталось \(remaining) с"
        case .playing:
            "Воспроизведение записанного"
        case .finished:
            "Проверка закончена. Если вы себя услышали — микрофон и наушники работают."
        case .failed(let reason):
            "Не удалось: \(reason)"
        }
    }

    // MARK: - Предпрослушивание рингтона

    /// Проиграть рингтон так, как он прозвучит на входящем.
    ///
    /// Через тот же `Ringtone` и те же настройки: смысл замены рингтона в том,
    /// чтобы услышать результат до звонка, а не после.
    func toggleRingtonePreview() {
        if isRingtonePreviewPlaying {
            stopRingtonePreview()
        } else {
            startRingtonePreview()
        }
    }
}
