import IOKit

/// Explains a microphone that can't hear anything, and suggests one that can.
struct MicIssue: Equatable {
    let message: String
    /// Another connected microphone to switch to, if there is one.
    let suggestion: InputDevice?

    /// The built-in mic of a MacBook with its lid closed is physically disconnected.
    static func lidClosed(using device: InputDevice?, among devices: [InputDevice]) -> MicIssue? {
        guard device?.isBuiltIn == true, InputDiagnostics.isLidClosed else { return nil }
        let alternative = InputDevices.alternative(to: device, among: devices)
        return MicIssue(
            message: alternative == nil
                ? "The MacBook lid is closed, which disconnects its built-in microphone. Open the lid, or connect a headset or external microphone."
                : "The MacBook lid is closed, which disconnects its built-in microphone.",
            suggestion: alternative
        )
    }

    /// The mic delivered nothing but exact zeros: disconnected, muted in hardware, or blocked.
    static func silent(using device: InputDevice?, among devices: [InputDevice]) -> MicIssue {
        lidClosed(using: device, among: devices) ?? MicIssue(
            message: "\(device?.name ?? "The microphone") is sending only silence. Check that it's connected and not muted.",
            suggestion: InputDevices.alternative(to: device, among: devices)
        )
    }
}

enum InputDiagnostics {
    /// True when a MacBook's lid is closed.
    static var isLidClosed: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? Bool) ?? false
    }
}
