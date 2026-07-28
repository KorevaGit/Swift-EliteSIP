import CoreAudio
import Foundation

/// Звуковое устройство в терминах CoreAudio HAL.
///
/// Своя структура, а не голый `AudioDeviceID`, по двум причинам. Первая: `id`
/// живёт только до перезагрузки и переподключения устройства, а в настройках
/// нужно хранить что-то постоянное — для этого есть `uid`. Вторая: тип
/// подключения нам не косметика, а поведение. Bluetooth-устройство при открытии
/// микрофона переводит всю гарнитуру в режим двусторонней связи, и знать об этом
/// заранее — единственный способ предупредить пользователя до того, как у него
/// упадёт качество звука в системе.
public struct AudioDevice: Sendable, Hashable, Identifiable {

    public enum Transport: Sendable, Hashable {
        case builtIn
        case bluetooth
        case usb
        case hdmi
        case displayPort
        case thunderbolt
        case airPlay
        case virtual
        case other(UInt32)

        init(rawValue: UInt32) {
            switch rawValue {
            case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
            case kAudioDeviceTransportTypeUSB: self = .usb
            case kAudioDeviceTransportTypeHDMI: self = .hdmi
            case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
            case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
            case kAudioDeviceTransportTypeAirPlay: self = .airPlay
            case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: self = .virtual
            default: self = .other(rawValue)
            }
        }

        /// Открытие микрофона на таком устройстве меняет режим всей гарнитуры.
        public var switchesToHeadsetModeWhenCapturing: Bool { self == .bluetooth }

        public var name: String {
            switch self {
            case .builtIn: "встроенное"
            case .bluetooth: "Bluetooth"
            case .usb: "USB"
            case .hdmi: "HDMI"
            case .displayPort: "DisplayPort"
            case .thunderbolt: "Thunderbolt"
            case .airPlay: "AirPlay"
            case .virtual: "виртуальное"
            case .other(let raw): "иное (\(Self.fourCharacterCode(raw)))"
            }
        }

        private static func fourCharacterCode(_ value: UInt32) -> String {
            let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
            let text = String(decoding: bytes, as: UTF8.self)
            return text.allSatisfy { $0.isASCII && !$0.isNewline } ? text : String(value)
        }
    }

    /// Идентификатор HAL. Действителен только в текущем сеансе.
    public var id: AudioDeviceID
    /// Постоянный идентификатор. Именно он хранится в настройках.
    public var uid: String
    public var name: String
    public var transport: Transport
    public var inputChannels: Int
    public var outputChannels: Int
    /// Частота, на которой устройство работает прямо сейчас.
    public var sampleRate: Double

    public init(
        id: AudioDeviceID,
        uid: String,
        name: String,
        transport: Transport,
        inputChannels: Int,
        outputChannels: Int,
        sampleRate: Double
    ) {
        self.id = id
        self.uid = uid
        self.name = name
        self.transport = transport
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.sampleRate = sampleRate
    }

    public var isInput: Bool { inputChannels > 0 }
    public var isOutput: Bool { outputChannels > 0 }

    /// Строка для журнала. Формат один и тот же в приложении и в `audioprobe`,
    /// чтобы отчёты можно было сравнивать глазами.
    public var summary: String {
        var parts = ["\(name) [\(transport.name)]"]
        if isInput { parts.append("вход \(inputChannels) кан.") }
        if isOutput { parts.append("выход \(outputChannels) кан.") }
        parts.append("\(Int(sampleRate)) Гц")
        return parts.joined(separator: ", ")
    }
}

// MARK: - Перечисление и наблюдение

/// Список устройств и слежение за сменой умолчаний.
///
/// Тонкая обёртка над HAL. Всё, что можно было бы написать на AVFoundation, там
/// на macOS попросту отсутствует: `AVAudioSession` — только iOS, а
/// `AVAudioEngine` умеет работать лишь с системным устройством по умолчанию,
/// пока ему явно не назначили другое через ту же HAL.
public enum AudioDeviceCatalog {

    // MARK: Перечисление

    public static func devices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else {
            return []
        }

        return ids.compactMap(device(for:))
    }

    public static func device(for id: AudioDeviceID) -> AudioDevice? {
        guard id != kAudioObjectUnknown else { return nil }
        guard let uid: String = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }

        let name: String = stringProperty(id, kAudioObjectPropertyName)
            ?? stringProperty(id, kAudioDevicePropertyDeviceNameCFString)
            ?? uid

        return AudioDevice(
            id: id,
            uid: uid,
            name: name,
            transport: AudioDevice.Transport(
                rawValue: numericProperty(id, kAudioDevicePropertyTransportType) ?? 0
            ),
            inputChannels: channelCount(id, scope: kAudioObjectPropertyScopeInput),
            outputChannels: channelCount(id, scope: kAudioObjectPropertyScopeOutput),
            sampleRate: sampleRate(of: id) ?? 0
        )
    }

    /// Устройство по постоянному идентификатору.
    ///
    /// Возвращает nil, если устройства сейчас нет — например, наушники
    /// отключены. Вызывающий в этом случае должен взять системное по умолчанию,
    /// а не отказываться от звонка.
    public static func device(uid: String) -> AudioDevice? {
        devices().first { $0.uid == uid }
    }

    public static var defaultInput: AudioDevice? {
        defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
    }

    public static var defaultOutput: AudioDevice? {
        defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDevice? {
        guard let id: AudioDeviceID = numericProperty(
            AudioObjectID(kAudioObjectSystemObject), selector
        ) else {
            return nil
        }
        return device(for: id)
    }

    /// Текущая частота устройства. Читается отдельно и по запросу: у Bluetooth
    /// она меняется на ходу, и закэшированное значение врёт ровно в тот момент,
    /// когда оно интересно.
    public static func sampleRate(of id: AudioDeviceID) -> Double? {
        numericProperty(id, kAudioDevicePropertyNominalSampleRate)
    }

    // MARK: Наблюдение

    /// Что именно изменилось в звуковом хозяйстве.
    public enum Change: Sendable, Hashable {
        case deviceListChanged
        case defaultInputChanged
        case defaultOutputChanged
        /// Устройство сменило частоту. Для Bluetooth это и есть переход в режим
        /// гарнитуры и обратно.
        case sampleRateChanged(AudioDeviceID)
    }

    /// Подписка на изменения. Живёт, пока жив возвращённый объект.
    ///
    /// Отписка в `deinit`, а не отдельным методом, намеренно: забытый слушатель
    /// HAL переживает объект, который его поставил, и стреляет по освобождённой
    /// памяти.
    public final class Observation: @unchecked Sendable {

        private let queue: DispatchQueue
        private var registered: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

        init(queue: DispatchQueue) {
            self.queue = queue
        }

        fileprivate func add(
            _ object: AudioObjectID,
            _ address: AudioObjectPropertyAddress,
            _ block: @escaping AudioObjectPropertyListenerBlock
        ) {
            var address = address
            guard AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else { return }
            registered.append((object, address, block))
        }

        deinit {
            for (object, address, block) in registered {
                var address = address
                AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
            }
        }
    }

    /// Следит за составом устройств, устройствами по умолчанию и частотой
    /// указанных устройств.
    ///
    /// `sampleRateWatchList` задаётся отдельно, потому что слушатель ставится на
    /// каждое устройство персонально: общего уведомления «кто-то сменил частоту»
    /// в HAL нет.
    public static func observe(
        sampleRatesOf sampleRateWatchList: [AudioDeviceID] = [],
        queue: DispatchQueue = DispatchQueue(label: "com.elite.EliteSIP.audio-devices"),
        onChange: @escaping @Sendable (Change) -> Void
    ) -> Observation {
        let observation = Observation(queue: queue)
        let system = AudioObjectID(kAudioObjectSystemObject)

        let systemSelectors: [(AudioObjectPropertySelector, Change)] = [
            (kAudioHardwarePropertyDevices, .deviceListChanged),
            (kAudioHardwarePropertyDefaultInputDevice, .defaultInputChanged),
            (kAudioHardwarePropertyDefaultOutputDevice, .defaultOutputChanged),
        ]

        for (selector, change) in systemSelectors {
            observation.add(
                system,
                AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                ),
                { _, _ in onChange(change) }
            )
        }

        for id in sampleRateWatchList {
            observation.add(
                id,
                AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyNominalSampleRate,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                ),
                { _, _ in onChange(.sampleRateChanged(id)) }
            )
        }

        return observation
    }

    // MARK: Чтение свойств

    private static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }

        // AudioBufferList — структура переменной длины, поэтому под неё нужен
        // сырой блок ровно того размера, который назвал HAL.
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }

        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(
        _ id: AudioDeviceID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // Через сырой указатель, а не через `var value: CFString?`: HAL отдаёт
        // строку с уже увеличенным счётчиком ссылок, и владение надо забрать
        // явно, иначе она течёт при каждом перечислении устройств.
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var box: Unmanaged<CFString>?
        let status = withUnsafeMutableBytes(of: &box) { bytes in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, bytes.baseAddress!)
        }
        guard status == noErr, let box else { return nil }
        return box.takeRetainedValue() as String
    }

    private static func numericProperty<Value: Numeric>(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> Value? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<Value>.size)
        var value: Value = .zero
        let status = withUnsafeMutableBytes(of: &value) { bytes in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, bytes.baseAddress!)
        }
        guard status == noErr else { return nil }
        return value
    }
}
