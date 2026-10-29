import AVFoundation
import SwiftUI

/// "Who spoke?": each voice told apart in a meeting, with a clip to listen to and something they
/// said, and a name to give it (typed, or picked from the calendar's invitees). Shown when a
/// recording with voices stops, and from the meeting page.
struct SpeakerNamingView: View {
    let meetingID: Int64
    let done: () -> Void
    @Environment(MeetingLibrary.self) private var library
    @State private var speakers: [MeetingSpeaker] = []
    @State private var names: [Int: String] = [:]
    @State private var quotes: [Int: String] = [:]
    @State private var invitees: [String] = []
    @State private var folder: URL?
    @State private var player = ClipPlayer()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModalHeader(
                title: "Who spoke?",
                subtitle: "These voices were told apart in the recording. Name them to use the names in the transcript and summary.",
                closeHelp: "Skip naming (Esc)"
            ) { finish(saving: false) }
            .padding(20)
            Divider()
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(speakers) { row($0) }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Text("Names stay on this Mac, with the meeting.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Save Names") { finish(saving: true) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 620, height: min(CGFloat(220 + speakers.count * 112), 640))
        .background(Theme.canvas)
        .task { load() }
        .onDisappear { player.stop() }
    }

    private func row(_ speaker: MeetingSpeaker) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(speaker.number)")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(SpeakerStyle.color(.system, participant: speaker.number), in: .circle)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Participant \(speaker.number)").font(.headline)
                    Text(Duration.milliseconds(speaker.speechMs).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let url = clip(speaker), FileManager.default.fileExists(atPath: url.path) {
                        Button(player.playing == url ? "Stop" : "Listen", systemImage: player.playing == url ? "stop.fill" : "play.fill") {
                            player.toggle(url)
                        }
                        .controlSize(.small)
                        .help("Play a few seconds of this voice")
                    }
                }
                if let quote = quotes[speaker.number] {
                    Text("“\(quote)”").italic().foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 6) {
                    TextField("Name", text: binding(speaker.number), prompt: Text("Participant \(speaker.number)"))
                        .textFieldStyle(.roundedBorder)
                    Menu {
                        Button("Me") { names[speaker.number] = "Me" }
                        if !invitees.isEmpty {
                            Divider()
                            ForEach(invitees, id: \.self) { name in Button(name) { names[speaker.number] = name } }
                        }
                    } label: {
                        Image(systemName: "person.crop.circle.badge.plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(invitees.isEmpty ? "Mark as you" : "Pick from the meeting's invitees")
                }
            }
        }
        .padding(14)
        .background(Theme.surface, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
    }

    private func binding(_ number: Int) -> Binding<String> {
        Binding(get: { names[number] ?? "" }, set: { names[number] = $0 })
    }

    private func clip(_ speaker: MeetingSpeaker) -> URL? {
        folder.map { MeetingFiles.voiceClip(speaker.number, in: $0) }
    }

    private func load() {
        guard let store = library.store else { return }
        let meeting = try? store.meeting(meetingID)
        folder = meeting?.folder
        speakers = (try? store.speakers(of: meetingID)) ?? []
        for s in speakers { names[s.number] = s.name ?? "" }
        // What each said: the sample line if it was transcribed, else their longest line.
        let segments = (try? store.segments(of: meetingID)) ?? []
        for s in speakers {
            let own = segments.filter { $0.participant == s.number }
            let sample = own.first { $0.startMs >= s.sampleStartMs && $0.endMs <= s.sampleEndMs + 500 }
            quotes[s.number] = (sample ?? own.max { $0.text.count < $1.text.count })?.text
        }
        invitees = meeting?.details?.others.filter { $0.response != .declined }.map(\.displayName) ?? []
    }

    private func finish(saving: Bool) {
        player.stop()
        let changes: [Int: String?] = saving
            ? Dictionary(uniqueKeysWithValues: speakers.map { ($0.number, names[$0.number]?.nilIfBlank) })
            : [:]
        library.nameSpeakers(meetingID, changes)
        done()
    }
}

/// Plays one voice clip at a time.
@MainActor @Observable
final class ClipPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var playing: URL?
    @ObservationIgnored private var player: AVAudioPlayer?

    func toggle(_ url: URL) {
        if playing == url { return stop() }
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.delegate = self
        player.play()
        self.player = player
        playing = url
    }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
