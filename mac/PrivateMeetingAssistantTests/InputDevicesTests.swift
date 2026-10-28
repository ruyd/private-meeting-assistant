import CoreAudio
import Testing
@testable import Private_Meeting_Assistant

struct InputDevicesTests {
    let builtIn = InputDevice(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", transportType: kAudioDeviceTransportTypeBuiltIn)
    let iPhone = InputDevice(uid: "iphone", name: "iPhone Microphone", transportType: kAudioDeviceTransportTypeContinuityCaptureWireless)
    let usb = InputDevice(uid: "usb", name: "Insta360 Link", transportType: kAudioDeviceTransportTypeUSB)

    @Test func suggestsExternalMicBeforeIPhone() {
        #expect(InputDevices.alternative(to: builtIn, among: [iPhone, builtIn, usb]) == usb)
    }

    @Test func fallsBackToIPhoneWhenItsTheOnlyOther() {
        #expect(InputDevices.alternative(to: builtIn, among: [builtIn, iPhone]) == iPhone)
    }

    @Test func neverSuggestsTheCurrentOrBuiltInMic() {
        #expect(InputDevices.alternative(to: usb, among: [builtIn, usb]) == nil)
    }

    @Test func choiceFallsBackToDefaultWhenUnplugged() {
        // "usb" is chosen but not connected; the system default (if any) is used instead.
        let effective = InputDevices.effective(chosenUID: "usb", among: [builtIn])
        #expect(effective?.uid != "usb")
    }
}
