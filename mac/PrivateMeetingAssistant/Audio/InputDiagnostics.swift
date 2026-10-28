import CoreAudio
import IOKit

/// Explains a microphone that delivers nothing but digital silence.
enum InputDiagnostics {
    /// True when a MacBook's lid is closed, which physically disconnects the built-in microphone.
    static var isLidClosed: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? Bool) ?? false
    }

    static var defaultInputIsBuiltIn: Bool {
        guard let device = try? AudioHardwareSystem.shared.defaultInputDevice else { return false }
        return (try? device.transportType) == kAudioDeviceTransportTypeBuiltIn
    }

    static func silentMicMessage() -> String {
        if isLidClosed && defaultInputIsBuiltIn {
            return "The MacBook lid is closed, which disconnects its built-in microphone. Open the lid, or use a headset or external microphone."
        }
        return "The microphone is sending only silence. Check the input device in System Settings › Sound."
    }
}
