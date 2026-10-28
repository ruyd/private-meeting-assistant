import AppKit
import AVFoundation
import CoreAudio

/// Whose audio counts as "Them".
enum SystemAudioTarget: Hashable, Sendable {
    /// Everything the Mac plays, except this app.
    case allExceptThisApp
    /// One app (and its helper processes), e.g. Zoom.
    case app(bundleID: String, name: String)

    var label: String {
        switch self {
        case .allExceptThisApp: "All system audio"
        case .app(_, let name): name
        }
    }
}

/// System audio through a Core Audio process tap (macOS 14.2+). Needs only the
/// "System Audio Recording Only" permission, not screen recording.
final class SystemAudioCapture: @unchecked Sendable {
    private let target: SystemAudioTarget
    private let onChunk: @Sendable (AudioChunk) -> Void
    /// Receives the tap's IO callbacks; conversion happens here, off the real-time thread.
    private let ioQueue = DispatchQueue(label: "system-audio.io", qos: .userInitiated)
    /// Serializes building and tearing down the tap.
    private let controlQueue = DispatchQueue(label: "system-audio.control")
    private var tap: AudioHardwareTap?
    private var aggregate: AudioHardwareAggregateDevice?
    private var ioProcID: AudioDeviceIOProcID?
    private var outputListener: AudioObjectPropertyListenerBlock?

    private static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init(target: SystemAudioTarget, onChunk: @escaping @Sendable (AudioChunk) -> Void) {
        self.target = target
        self.onChunk = onChunk
    }

    func start() throws {
        try controlQueue.sync { try build() }
        // The aggregate device is clocked by the current output device, so rebuild when it changes
        // (e.g. switching from speakers to AirPods).
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.controlQueue.async {
                self.teardown()
                try? self.build()
            }
        }
        outputListener = listener
        var address = Self.defaultOutputAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, listener)
    }

    func stop() {
        if let outputListener {
            var address = Self.defaultOutputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, outputListener)
        }
        outputListener = nil
        controlQueue.sync { teardown() }
    }

    private func build() throws {
        let system = AudioHardwareSystem.shared
        let description: CATapDescription
        switch target {
        case .allExceptThisApp:
            let own = (try? system.process(for: getpid()))?.map { [$0.id] } ?? []
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: own)
        case .app(let bundleID, _):
            description = CATapDescription(stereoMixdownOfProcesses: [])
            description.bundleIDs = Self.processBundleIDs(forApp: bundleID)
            // Keep tapping the app if it quits and relaunches mid-meeting.
            description.isProcessRestoreEnabled = true
        }
        description.name = "Private Meeting Assistant"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        guard let tap = try system.makeProcessTap(description: description) else {
            throw CaptureError.tapFailed("the tap couldn't be created")
        }
        self.tap = tap
        var streamDescription = try tap.format
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw CaptureError.unsupportedFormat("tap format")
        }
        guard let output = try system.defaultOutputDevice else { throw CaptureError.noOutputDevice }
        let outputUID = try output.uid

        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Private Meeting Assistant Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: try tap.uid]],
        ]
        guard let aggregate = try system.makeAggregateDevice(description: composition) else {
            throw CaptureError.tapFailed("the aggregate device couldn't be created")
        }
        self.aggregate = aggregate

        let resampler = MonoResampler()
        let onChunk = onChunk
        let tapFormat = format
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate.id, ioQueue) { _, inputData, inputTime, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: inputData, deallocator: nil),
                  let samples = try? resampler.convert(buffer), !samples.isEmpty
            else { return }
            let time = inputTime.pointee
            let hostTime = time.mFlags.contains(.hostTimeValid) ? time.mHostTime : mach_absolute_time()
            onChunk(AudioChunk(source: .system, samples: samples, hostTime: hostTime))
        }
        guard status == noErr, let procID else { throw CaptureError.tapFailed("IO proc error \(status)") }
        ioProcID = procID
        try aggregate.start(IOProcID: procID)
    }

    private func teardown() {
        let system = AudioHardwareSystem.shared
        if let aggregate {
            if let ioProcID {
                try? aggregate.stop(IOProcID: ioProcID)
                AudioDeviceDestroyIOProcID(aggregate.id, ioProcID)
            }
            try? system.destroyAggregateDevice(aggregate)
        }
        if let tap { try? system.destroyProcessTap(tap) }
        // Let any callback already queued finish before its resampler is released.
        ioQueue.sync {}
        ioProcID = nil
        aggregate = nil
        tap = nil
    }

    /// The app's bundle ID plus those of its helper processes that play audio
    /// (e.g. "com.google.Chrome.helper").
    static func processBundleIDs(forApp bundleID: String) -> [String] {
        var ids: Set<String> = [bundleID]
        for process in (try? AudioHardwareSystem.shared.processes) ?? [] {
            if let id = try? process.bundleID, id.hasPrefix(bundleID + ".") { ids.insert(id) }
        }
        // Safari plays web audio from WebKit's shared GPU process.
        if bundleID == "com.apple.Safari" { ids.insert("com.apple.WebKit.GPU") }
        return Array(ids)
    }

    /// Running apps that have an audio process, for the source picker. Apps playing sound come first.
    static func audioApps() -> [(target: SystemAudioTarget, isPlaying: Bool)] {
        let ownBundleID = Bundle.main.bundleIdentifier
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var playing: [String: Bool] = [:]
        for process in (try? AudioHardwareSystem.shared.processes) ?? [] {
            guard let id = try? process.bundleID,
                  let app = running.first(where: { app in
                      guard let appID = app.bundleIdentifier else { return false }
                      return id == appID || id.hasPrefix(appID + ".")
                          || (appID == "com.apple.Safari" && id == "com.apple.WebKit.GPU")
                  }),
                  let appID = app.bundleIdentifier, appID != ownBundleID
            else { continue }
            playing[appID] = (playing[appID] ?? false) || ((try? process.isRunningOutput) ?? false)
        }
        return running
            .compactMap { app -> (SystemAudioTarget, Bool)? in
                guard let id = app.bundleIdentifier, let isPlaying = playing[id] else { return nil }
                return (.app(bundleID: id, name: app.localizedName ?? id), isPlaying)
            }
            .sorted { ($0.1 ? 0 : 1, $0.0.label) < ($1.1 ? 0 : 1, $1.0.label) }
            .map { (target: $0.0, isPlaying: $0.1) }
    }
}
