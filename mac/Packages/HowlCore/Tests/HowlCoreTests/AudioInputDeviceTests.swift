import CoreAudio
import Testing
@testable import HowlCore

// Settings flags Bluetooth mics because they start slowly: AirPods
// measured 2–4 s from key press to first real audio when idle, versus
// a few hundred ms for built-in and USB mics.

@Test(arguments: [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE])
func bluetoothTransportsAreFlagged(transport: UInt32) {
    let dev = AudioInputDevice(id: "x", name: "AirPods", transportType: transport)
    #expect(dev.isBluetooth)
}

@Test(arguments: [kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeVirtual])
func wiredAndBuiltInTransportsAreNotFlagged(transport: UInt32) {
    let dev = AudioInputDevice(id: "x", name: "Mic", transportType: transport)
    #expect(!dev.isBluetooth)
}

@Test func unknownTransportIsNotFlagged() {
    #expect(!AudioInputDevice(id: "x", name: "Mic").isBluetooth)
}
