import CoreAudio
import Foundation
import Testing
@testable import MediaCore

@Suite("Маршрут звука")
struct AudioRouteTests {

    private func device(
        name: String = "устройство",
        transport: AudioDevice.Transport,
        input: Int,
        output: Int,
        rate: Double = 48000
    ) -> AudioDevice {
        AudioDevice(
            id: 1,
            uid: "uid-\(name)",
            name: name,
            transport: transport,
            inputChannels: input,
            outputChannels: output,
            sampleRate: rate
        )
    }

    /// Признак режима гарнитуры нащупан замерами на AirPods Pro, и подмена его
    /// на «частота упала» — самая вероятная будущая правка. Тест существует,
    /// чтобы такая правка провалилась: у разных моделей частота разная, а вот
    /// появление входных каналов у устройства вывода — общее.
    @Test("AirPods в двустороннем режиме опознаются по входу у устройства вывода")
    func detectsHeadsetMode() {
        let idle = device(name: "AirPods", transport: .bluetooth, input: 0, output: 2, rate: 48000)
        let duplex = device(name: "AirPods", transport: .bluetooth, input: 2, output: 2, rate: 24000)

        #expect(!AudioRoute.isInHeadsetMode(idle))
        #expect(AudioRoute.isInHeadsetMode(duplex))
    }

    @Test("Проводная гарнитура с микрофоном режимом гарнитуры не считается")
    func ignoresWiredDuplexDevices() {
        // У USB-гарнитуры вход и выход в одном устройстве всегда, и полосу это
        // ни у кого не отнимает — предупреждать не о чем.
        let usb = device(name: "USB-гарнитура", transport: .usb, input: 1, output: 2)
        #expect(!AudioRoute.isInHeadsetMode(usb))

        let aggregate = device(name: "Агрегат", transport: .virtual, input: 2, output: 2)
        #expect(!AudioRoute.isInHeadsetMode(aggregate))
    }

    @Test("Маршрут берёт режим гарнитуры со стороны вывода")
    func routeReflectsOutputSide() {
        let microphone = device(name: "AirPods", transport: .bluetooth, input: 1, output: 0, rate: 24000)
        let speaker = device(name: "AirPods", transport: .bluetooth, input: 2, output: 2, rate: 24000)

        #expect(AudioRoute(input: microphone, output: speaker).isHeadsetMode)
        #expect(!AudioRoute(input: microphone, output: nil).isHeadsetMode)
    }

    @Test("Сводка называет устройства и предупреждает о режиме гарнитуры")
    func summaryMentionsBothEnds() {
        let route = AudioRoute(
            input: device(name: "AirPods", transport: .bluetooth, input: 1, output: 0),
            output: device(name: "AirPods", transport: .bluetooth, input: 2, output: 2)
        )

        #expect(route.summary.contains("AirPods"))
        #expect(route.summary.contains("режим гарнитуры"))
    }

    @Test("Тип подключения разбирается из кода CoreAudio")
    func decodesTransportType() {
        #expect(AudioDevice.Transport(rawValue: kAudioDeviceTransportTypeBluetooth) == .bluetooth)
        #expect(AudioDevice.Transport(rawValue: kAudioDeviceTransportTypeBluetoothLE) == .bluetooth)
        #expect(AudioDevice.Transport(rawValue: kAudioDeviceTransportTypeBuiltIn) == .builtIn)
        #expect(AudioDevice.Transport(rawValue: kAudioDeviceTransportTypeAggregate) == .virtual)

        // Незнакомый код не должен теряться: по нему и опознаётся, что за
        // устройство притащил очередной выпуск macOS. Например, ccwd —
        // микрофон iPhone через Continuity Camera.
        let continuity = AudioDevice.Transport(rawValue: 0x63637764)
        #expect(continuity == .other(0x63637764))
        #expect(continuity.name.contains("ccwd"))
    }

    @Test("Только Bluetooth уходит в режим гарнитуры при захвате")
    func onlyBluetoothSwitchesMode() {
        #expect(AudioDevice.Transport.bluetooth.switchesToHeadsetModeWhenCapturing)
        #expect(!AudioDevice.Transport.builtIn.switchesToHeadsetModeWhenCapturing)
        #expect(!AudioDevice.Transport.usb.switchesToHeadsetModeWhenCapturing)
    }
}
