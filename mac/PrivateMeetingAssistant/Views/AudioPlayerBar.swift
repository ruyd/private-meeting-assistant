import AVFoundation
import SwiftUI

/// The meeting's audio (audio.m4a), played in place: play/pause, the time, and a slider to jump
/// anywhere in the recording. Its times are the transcript's, since the file follows the meeting.
struct AudioPlayerBar: View {
    let url: URL
    /// Owned by the page, so the transcript can follow it.
    let player: InlineAudioPlayer

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
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .frame(height: 30)
        .background(Theme.surface, in: .capsule)
        .overlay(Capsule().strokeBorder(Theme.stroke))
        .task(id: url) { player.load(url) }
        .onDisappear { player.stop() }
    }
}

/// Plays one file, publishing its position for the slider.
@MainActor @Observable
final class InlineAudioPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var isPlaying = false
    private(set) var duration: TimeInterval = 0
    private(set) var currentTime: TimeInterval = 0
    /// While the slider is dragged, the position follows the slider, not playback.
    var isScrubbing = false

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    func load(_ url: URL) {
        stop()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.delegate = self
        player?.prepareToPlay()
        duration = player?.duration ?? 0
        currentTime = 0
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            setPlaying(false)
        } else {
            if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }
            player.play()
            setPlaying(true)
        }
    }

    func seek(to time: TimeInterval) {
        currentTime = min(max(time, 0), duration)
        player?.currentTime = currentTime
    }

    /// Plays from a point in the recording (clicking a line's time).
    func play(from time: TimeInterval) {
        seek(to: time)
        if player?.isPlaying != true { toggle() }
    }

    func stop() {
        player?.stop()
        setPlaying(false)
    }

    private func setPlaying(_ playing: Bool) {
        isPlaying = playing
        ticker?.cancel()
        ticker = nil
        guard playing else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.player else { return }
                if !self.isScrubbing { self.currentTime = player.currentTime }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.setPlaying(false)
            self.currentTime = self.duration
        }
    }
}
