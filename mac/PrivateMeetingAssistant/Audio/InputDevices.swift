import CoreAudio

/// A microphone or other audio input, identified by its Core Audio UID (stable across reconnects).
struct InputDevice: Hashable, Identifiable, Sendable {
    let uid: String
    let name: String
    let transportType: UInt32

    var id: String { uid }
    var isBuiltIn: Bool { transportType == kAudioDeviceTransportTypeBuiltIn }
    /// An iPhone used as a microphone through Continuity.
    var isContinuity: Bool {
        transportType == kAudioDeviceTransportTypeContinuityCaptureWired
            || transportType == kAudioDeviceTransportTypeContinuityCaptureWireless
    }
}

enum InputDevices {
    static func all() -> [InputDevice] {
        let devices = (try? AudioHardwareSystem.shared.devices) ?? []
        return devices.compactMap { device in
            guard (try? device.isHidden) != true,
                  !isPrivateAggregate(device),
                  let streams = try? device.streams,
                  streams.contains(where: { (try? $0.direction) == .input }),
                  let uid = try? device.uid,
                  let name = try? device.name
            else { return nil }
            return InputDevice(uid: uid, name: name, transportType: (try? device.transportType) ?? 0)
        }
    }

    /// Aggregate devices private to this process, like the one AVAudioEngine builds around a chosen
    /// input or our own system-audio tap. Aggregates the user made in Audio MIDI Setup stay listed.
    private static func isPrivateAggregate(_ device: AudioHardwareDevice) -> Bool {
        guard (try? device.transportType) == kAudioDeviceTransportTypeAggregate else { return false }
        let composition = (try? AudioHardwareAggregateDevice(id: device.id).composition) ?? [:]
        return (composition[kAudioAggregateDeviceIsPrivateKey] as? Int) == 1
    }

    static func systemDefault(among devices: [InputDevice]) -> InputDevice? {
        guard let uid = try? AudioHardwareSystem.shared.defaultInputDevice?.uid else { return nil }
        return devices.first { $0.uid == uid }
    }

    /// The device capture will actually use: the chosen one if it's connected, else the system default.
    static func effective(chosenUID: String?, among devices: [InputDevice]) -> InputDevice? {
        devices.first { $0.uid == chosenUID } ?? systemDefault(among: devices)
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        (try? AudioHardwareSystem.shared.device(forUID: uid))?.id
    }

    /// The best other microphone to suggest: external mics and headsets before an iPhone.
    static func alternative(to device: InputDevice?, among devices: [InputDevice]) -> InputDevice? {
        devices
            .filter { !$0.isBuiltIn && $0.uid != device?.uid }
            .sorted { ($0.isContinuity ? 1 : 0, $0.name) < ($1.isContinuity ? 1 : 0, $1.name) }
            .first
    }
}
