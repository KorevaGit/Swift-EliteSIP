import CoreAudio
import Foundation

/// Временное агрегатное устройство: чужой микрофон и чужие наушники, сведённые
/// в одно устройство для CoreAudio.
///
/// Существует ради ограничения, которое иначе не обойти. На macOS
/// `AVAudioEngine` держит **один** узел ввода-вывода на оба направления —
/// проверено, `inputNode.auAudioUnit === outputNode.auAudioUnit`. Значит, задать
/// микрофон и наушники по отдельности через движок нельзя: назначается ровно
/// одно устройство на обе стороны.
///
/// Сама macOS эту задачу решает точно так же: когда устройства по умолчанию
/// разные, она молча собирает своё агрегатное устройство `CADefaultDeviceAggregate`
/// — его видно в списке во время разговора. Мы делаем то же самое, только со
/// своим набором.
///
/// Устройство создаётся **приватным** (`kAudioAggregateDeviceIsPrivateKey`):
/// его не видно в «Звуке» и в списках других программ, и оно исчезает вместе с
/// процессом. Публичное осталось бы в системе навсегда после падения —
/// пользователь потом искал бы, откуда взялось «EliteSIP» в настройках звука.
public final class AggregateAudioDevice: @unchecked Sendable {

    public enum Error: Swift.Error, Sendable, LocalizedError {
        case deviceMissing(uid: String)
        case creationFailed(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .deviceMissing(let uid):
                "Устройство \(uid) недоступно."
            case .creationFailed(let status):
                "Не удалось собрать агрегатное устройство (CoreAudio вернул \(status))."
            }
        }
    }

    public private(set) var id: AudioDeviceID
    public let uid: String

    private var isDestroyed = false

    /// Собирает устройство из микрофона и наушников.
    ///
    /// `inputUID` задаёт ведущее устройство (master): по его часам идёт
    /// синхронизация, и выбирать надо именно вход. Причина в том, что вход
    /// нельзя ресемплировать незаметно — пропуск отсчёта с микрофона слышен
    /// собеседнику, а подстройка выхода прячется в буфере воспроизведения.
    public init(inputUID: String, outputUID: String, name: String = "EliteSIP") throws {
        guard AudioDeviceCatalog.device(uid: inputUID) != nil else {
            throw Error.deviceMissing(uid: inputUID)
        }
        guard AudioDeviceCatalog.device(uid: outputUID) != nil else {
            throw Error.deviceMissing(uid: outputUID)
        }

        // Уникальный идентификатор: два разговора одновременно — это M5 с тремя
        // линиями, и одинаковый uid там столкнул бы устройства друг с другом.
        let uid = "com.elite.EliteSIP.aggregate.\(UUID().uuidString)"
        self.uid = uid

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: name,
            kAudioAggregateDeviceUIDKey as String: uid,
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            // Не «стековое»: стековое устройство складывает каналы нескольких
            // выходов, а нам нужно обычное агрегатное с ведущими часами.
            kAudioAggregateDeviceIsStackedKey as String: 0,
            kAudioAggregateDeviceMainSubDeviceKey as String: inputUID,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: inputUID],
                [
                    kAudioSubDeviceUIDKey as String: outputUID,
                    // Компенсация расхождения часов — обязательна, а не
                    // украшение. У двух разных устройств кварцы свои, и за
                    // минуты разговора они расходятся на слышимую величину:
                    // без компенсации выход начинает то опустошаться, то
                    // переполняться, и это щелчки на ровном месте. Ставится на
                    // ведомое устройство; ведущее задаёт часы и подстраивать
                    // его не надо и нельзя.
                    kAudioSubDeviceDriftCompensationKey as String: 1,
                ],
            ],
        ]

        var created: AudioDeviceID = 0
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &created)
        guard status == noErr, created != kAudioObjectUnknown else {
            throw Error.creationFailed(status)
        }
        id = created
    }

    /// Разбирает устройство.
    ///
    /// Вызывать явно, не полагаясь на `deinit`: пока устройство живо, оно
    /// держит открытыми оба подчинённых, а значит и Bluetooth-гарнитуру в
    /// режиме связи.
    public func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        AudioHardwareDestroyAggregateDevice(id)
        id = kAudioObjectUnknown
    }

    deinit {
        destroy()
    }
}

public extension AudioDeviceCatalog {

    /// Нужно ли собирать агрегатное устройство для этой пары.
    ///
    /// Не нужно в двух случаях: когда обе стороны отданы системе (она соберёт
    /// сама) и когда выбрано одно и то же устройство на вход и выход — тогда
    /// достаточно назначить его движку напрямую.
    static func needsAggregate(inputUID: String?, outputUID: String?) -> Bool {
        guard let inputUID, let outputUID else { return false }
        return inputUID != outputUID
    }
}
