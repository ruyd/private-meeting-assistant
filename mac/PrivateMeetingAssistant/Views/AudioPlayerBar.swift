import AVFoundation
import SwiftUI

/// The meeting's audio (audio.m4a), played in place: play/pause, the time, and a slider to jump
/// anywhere in the recording. Its times are the transcript's, since the file follows the meeting.
struct AudioPlayerBar: View {
    let url: URL
    /// Owned by the page, so the transcript can follow it.
    let player: InlineAudioPlayer
    /// Remembered across launches; 110% to start, as recordings tend to be quiet.
    @AppStorage("playbackVolume") private var volume = 1.1

    var body: some View {
        HStack(spacing: 10) {
            Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                player.toggle()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 18)
            .help(player.isPlaying ? "Pause" : "Play the meeting's audio")

            Text(TranscriptExport.timestamp(Int(player.currentTime * 1000)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 36, alignment: .trailing)

            Slider(
                value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                in: 0...max(player.duration, 0.1)
            ) { editing in
                player.isScrubbing = editing
            }
            .controlSize(.small)
            .frame(minWidth: 160, maxWidth: 360)
            .accessibilityLabel("Position in the audio")

            Text(TranscriptExport.timestamp(Int(player.duration * 1000)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Divider().frame(height: 14)

            VolumeSlider(volume: $volume)
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .frame(height: 30)
        .background(Theme.surface, in: .capsule)
        .overlay(Capsule().strokeBorder(Theme.stroke))
        .task(id: url) { player.load(url) }
        .onAppear { player.volume = Float(volume) }
        .onChange(of: volume) { player.volume = Float(volume) }
        .onDisappear { player.stop() }
    }
}

/// Plays one file, publishing its position for the slider. Through AVAudioEngine rather than
/// AVAudioPlayer, whose volume stops at 100%: the volume (`volume`, 0–1.5) is a gain, so quiet
/// recordings can be turned up.
@MainActor @Observable
final class InlineAudioPlayer {
    private(set) var isPlaying = false
    private(set) var duration: TimeInterval = 0
    private(set) var currentTime: TimeInterval = 0
    /// While the slider is dragged, the position follows the slider, not playback.
    var isScrubbing = false
    /// 1 is the recording as it is; up to 1.5 (+3.5 dB).
    var volume: Float = 1 {
        didSet { applyVolume() }
    }

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let node = AVAudioPlayerNode()
    @ObservationIgnored private let gain = AVAudioUnitEQ(numberOfBands: 0)
    @ObservationIgnored private var file: AVAudioFile?
    /// Where the scheduled stretch starts in the file, in frames.
    @ObservationIgnored private var startFrame: AVAudioFramePosition = 0
    /// Bumped on every reschedule, so a stretch stopped to seek doesn't count as playing to the end.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var ticker: Task<Void, Never>?

    init() {
        engine.attach(node)
        engine.attach(gain)
        applyVolume()
    }

    func load(_ url: URL) {
        stop()
        guard let file = try? AVAudioFile(forReading: url) else {
            self.file = nil
            duration = 0
            return
        }
        self.file = file
        engine.disconnectNodeOutput(node)
        engine.disconnectNodeOutput(gain)
        engine.connect(node, to: gain, format: file.processingFormat)
        engine.connect(gain, to: engine.mainMixerNode, format: file.processingFormat)
        duration = Double(file.length) / file.processingFormat.sampleRate
        currentTime = 0
        startFrame = 0
    }

    func toggle() {
        guard file != nil else { return }
        if isPlaying {
            currentTime = playedTime
            node.pause()
            setPlaying(false)
        } else {
            if currentTime >= duration - 0.05 { currentTime = 0 }
            start(at: currentTime)
        }
    }

    func seek(to time: TimeInterval) {
        currentTime = min(max(time, 0), duration)
        if isPlaying { start(at: currentTime) }
    }

    /// Plays from a point in the recording (clicking a line's time).
    func play(from time: TimeInterval) {
        currentTime = min(max(time, 0), duration)
        start(at: currentTime)
    }

    func stop() {
        generation += 1
        node.stop()
        engine.pause()
        setPlaying(false)
    }

    /// Schedules the file from `time` to its end and plays it.
    private func start(at time: TimeInterval) {
        guard let file else { return }
        generation += 1
        let mine = generation
        node.stop()
        let rate = file.processingFormat.sampleRate
        startFrame = min(AVAudioFramePosition(time * rate), file.length)
        let frames = AVAudioFrameCount(max(file.length - startFrame, 0))
        guard frames > 0 else {
            setPlaying(false)
            return
        }
        node.scheduleSegment(file, startingFrame: startFrame, frameCount: frames, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == mine else { return }
                self.setPlaying(false)
                self.currentTime = self.duration
            }
        }
        do {
            if !engine.isRunning { try engine.start() }
            node.play()
            setPlaying(true)
        } catch {
            setPlaying(false)
        }
    }

    /// The position playback has reached.
    private var playedTime: TimeInterval {
        guard let file, let nodeTime = node.lastRenderTime, let playerTime = node.playerTime(forNodeTime: nodeTime) else { return currentTime }
        let rate = file.processingFormat.sampleRate
        return min(Double(startFrame + playerTime.sampleTime) / rate, duration)
    }

    /// Up to 100% by the mixer's volume (down to silence); above it, by the gain stage.
    private func applyVolume() {
        let v = max(min(volume, 1.5), 0)
        engine.mainMixerNode.outputVolume = min(v, 1)
        gain.globalGain = v > 1 ? 20 * log10(v) : 0
    }

    private func setPlaying(_ playing: Bool) {
        isPlaying = playing
        ticker?.cancel()
        ticker = nil
        guard playing else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.isScrubbing { self.currentTime = self.playedTime }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

/// Playback volume from 0 to 150%, with 100% in the middle (marked |): the left half goes to 100%,
/// the right half on to 150%. Snaps to 100% close by.
struct VolumeSlider: View {
    @Binding var volume: Double

    static let range = 0.0...1.5

    /// The slider's position (0…1) for a volume, and back.
    static func position(_ volume: Double) -> Double { volume <= 1 ? volume / 2 : 0.5 + (volume - 1) }
    static func volume(_ position: Double) -> Double {
        let v = position <= 0.5 ? position * 2 : 1 + (position - 0.5)
        return abs(v - 1) < 0.03 ? 1 : min(max(v, range.lowerBound), range.upperBound)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: volume == 0 ? "speaker.slash.fill" : volume < 0.5 ? "speaker.wave.1.fill" : volume <= 1 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Slider(value: Binding(get: { Self.position(volume) }, set: { volume = Self.volume($0) }), in: 0...1)
                .controlSize(.mini)
                .frame(width: 90)
                .overlay {
                    // 100%, in the middle: taller than the knob, so it shows when the knob is near.
                    Capsule().fill(.primary.opacity(0.55)).frame(width: 1.5, height: 18).allowsHitTesting(false)
                }
                .accessibilityLabel("Volume")
                .accessibilityValue("\(Int((volume * 100).rounded())) percent")
            Text("\(Int((volume * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
        }
        .help("Volume: 100% is the recording as it is; up to 150% to turn quiet ones up")
    }
}
