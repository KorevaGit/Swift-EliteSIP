import AVFoundation
import MediaCore

/// Звонок входящего вызова.
///
/// Синтезируется, а не проигрывается из файла, и на то две причины. Первая —
/// файл пришлось бы либо рисовать самим, либо тащить чужой с его лицензией.
/// Вторая важнее: рингтон обязан звучать до того, как поднимется тракт
/// разговора, и обязан замолчать раньше него. Со своим генератором это
/// два вызова, а не переговоры с системным проигрывателем.
///
/// Свой `AVAudioEngine`, отдельный от разговорного: у того включён
/// `VoiceProcessingIO`, и любой звук через него уводит AirPods в режим
/// гарнитуры — то есть приглушает всю систему ещё до того, как оператор
/// решил ответить.
@MainActor
final class Ringtone {

    /// Цикл: два коротких тона и пауза. Пауза длинная намеренно — рингтон
    /// звучит на фоне работы в CRM, и непрерывная трель мешает думать.
    private static let toneDuration = 0.4
    private static let gapDuration = 0.2
    private static let silenceDuration = 2.0

    /// Две гармоники вместо одной: чистая синусоида на колонках ноутбука
    /// звучит как неисправность, а не как звонок.
    private static let partials: [(frequency: Double, amplitude: Double)] = [
        (587.33, 0.6),  // ре пятой октавы
        (880.00, 0.4),  // ля пятой октавы
    ]

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?

    var isPlaying: Bool { player?.isPlaying ?? false }

    /// Начинает звонить. Повторный вызов ничего не меняет.
    ///
    /// Ошибки не выбрасываются наверх: беззвучный рингтон — досадно, но окно
    /// входящего видно и без него, а звонок ронять из-за звуковой карты нельзя.
    func start(settings: AppSettings.RingtoneSettings, outputDeviceUID: String?) {
        guard settings.isEnabled, engine == nil else { return }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()

        // Устройство выбирается до того, как граф собран: смена устройства на
        // запущенном движке требует полной пересборки (см. audio.md).
        if !settings.usesSystemOutput,
           let uid = outputDeviceUID,
           let device = AudioDeviceCatalog.device(uid: uid) {
            try? engine.outputNode.auAudioUnit.setDeviceID(device.id)
        }

        let format = engine.outputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let buffer = makeCycleBuffer(format: format) else { return }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
        engine.mainMixerNode.outputVolume = Float(min(max(settings.volume, 0), 1))

        do {
            try engine.start()
        } catch {
            return
        }

        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()

        self.engine = engine
        self.player = player
    }

    func stop() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
    }

    /// Один полный цикл звонка одним буфером.
    ///
    /// Целиком, а не по кусочкам с планировщиком: зацикленный буфер играет
    /// ровно, а цепочка запланированных отрезков рано или поздно даёт щелчок
    /// на стыке.
    private func makeCycleBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let cycle = Self.toneDuration * 2 + Self.gapDuration + Self.silenceDuration
        let frameCount = AVAudioFrameCount(cycle * sampleRate)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channels = buffer.floatChannelData
        else { return nil }

        buffer.frameLength = frameCount

        let toneFrames = Int(Self.toneDuration * sampleRate)
        let gapFrames = Int(Self.gapDuration * sampleRate)
        // Скос по краям тона: обрыв синусоиды на ненулевой фазе слышен как
        // щелчок, и на цикле в две секунды он раздражает сильнее самого звонка.
        let fadeFrames = max(1, Int(0.012 * sampleRate))

        for frame in 0..<Int(frameCount) {
            let positionInTone: Int?
            switch frame {
            case 0..<toneFrames:
                positionInTone = frame
            case (toneFrames + gapFrames)..<(toneFrames * 2 + gapFrames):
                positionInTone = frame - toneFrames - gapFrames
            default:
                positionInTone = nil
            }

            var value = 0.0
            if let positionInTone {
                let time = Double(positionInTone) / sampleRate
                for partial in Self.partials {
                    value += partial.amplitude * sin(2 * .pi * partial.frequency * time)
                }

                let fadeIn = min(1.0, Double(positionInTone) / Double(fadeFrames))
                let fadeOut = min(1.0, Double(toneFrames - positionInTone) / Double(fadeFrames))
                value *= fadeIn * fadeOut * 0.5
            }

            for channel in 0..<Int(format.channelCount) {
                channels[channel][frame] = Float(value)
            }
        }

        return buffer
    }
}
