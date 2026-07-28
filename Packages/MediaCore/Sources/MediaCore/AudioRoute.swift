import Foundation

/// Куда сейчас идёт звук разговора и в каком режиме.
///
/// Существует ради одной вещи, которую пользователь замечает сразу, а объяснить
/// её нечем: при звонке через AirPods музыка и системные звуки становятся
/// заметно глуше. Это не наш баг и не баг macOS — это Bluetooth: пока микрофон
/// гарнитуры открыт, канал работает в двустороннем режиме, и на воспроизведение
/// остаётся вдвое меньше полосы. Показать это словами дешевле, чем отвечать на
/// вопрос «почему испортился звук».
public struct AudioRoute: Sendable, Hashable {

    public var input: AudioDevice?
    public var output: AudioDevice?

    public init(input: AudioDevice?, output: AudioDevice?) {
        self.input = input
        self.output = output
    }

    /// Снимок текущего маршрута по системным устройствам по умолчанию.
    public static func current() -> AudioRoute {
        AudioRoute(input: AudioDeviceCatalog.defaultInput, output: AudioDeviceCatalog.defaultOutput)
    }

    /// Гарнитура переведена в режим двусторонней связи.
    public var isHeadsetMode: Bool {
        output.map(Self.isInHeadsetMode) ?? false
    }

    /// Признак режима гарнитуры по одному устройству вывода.
    ///
    /// Выделено отдельно, потому что признак неочевиден и его надо было
    /// нащупать замерами. Идея: у Bluetooth-наушников в обычном режиме
    /// устройство вывода имеет только выходные каналы. Как только система
    /// поднимает двусторонний канал, то же самое устройство вывода обзаводится
    /// входными каналами, а его частота падает (у AirPods Pro на macOS 26 —
    /// с 48 000 до 24 000 Гц). Смотреть на частоту одну — ненадёжно: у разных
    /// моделей она разная. Смотреть на появление входа — надёжно.
    public static func isInHeadsetMode(_ device: AudioDevice) -> Bool {
        device.transport == .bluetooth && device.isOutput && device.isInput
    }

    /// Строка для журнала и для панели.
    public var summary: String {
        var text = "вход \(input?.name ?? "нет") → выход \(output?.name ?? "нет")"
        if isHeadsetMode {
            text += " (режим гарнитуры: звук системы стал глуше — это Bluetooth, не мы)"
        }
        return text
    }
}
