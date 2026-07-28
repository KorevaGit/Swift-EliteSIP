import Testing
@testable import MediaCore

@Suite("Описание кодеков")
struct AudioCodecTests {

    @Test("Статические payload type по RFC 3551")
    func staticPayloadTypes() {
        #expect(AudioCodec.pcmu.payloadType == 0)
        #expect(AudioCodec.pcma.payloadType == 8)
        #expect(AudioCodec(staticPayloadType: 0) == .pcmu)
        #expect(AudioCodec(staticPayloadType: 8) == .pcma)
        #expect(AudioCodec(staticPayloadType: 101) == nil, "telephone-event — не аудиокодек")
    }

    @Test("Имена для SDP совпадают с ожиданиями Asterisk")
    func sdpNames() {
        #expect(AudioCodec.pcmu.sdpName == "PCMU")
        #expect(AudioCodec.pcma.sdpName == "PCMA")
        #expect(TelephoneEvent.sdpName == "telephone-event")
    }

    @Test("Раскладка пакета 20 мс")
    func packetGeometry() {
        for codec in AudioCodec.allCases {
            #expect(codec.rtpClockRate == 8000)
            #expect(codec.channelCount == 1)
            #expect(codec.timestampIncrement(forPacketTime: 20) == 160)
            #expect(codec.timestampIncrement(forPacketTime: 10) == 80)
            #expect(codec.byteCount(forPacketTime: 20) == 160)
        }
        #expect(AudioCodec.g722.sampleCount(forPacketTime: 20) == 320)
        #expect(AudioCodec.pcmu.sampleCount(forPacketTime: 20) == 160)
        #expect(defaultPacketTimeMilliseconds == 20)
    }

    @Test("Настройки telephone-event")
    func telephoneEventDefaults() {
        // 101 — то, что Asterisk ставит при dtmfmode=rfc2833.
        #expect(TelephoneEvent.defaultPayloadType == 101)
        #expect(TelephoneEvent.clockRate == 8000)
        #expect(TelephoneEvent.supportedEventRange == "0-16")
    }
}
