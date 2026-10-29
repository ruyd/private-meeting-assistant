import AppKit
import SwiftUI

/// One meeting: title, summary (if it has one) and transcript, with copy, export and delete.
struct MeetingView: View {
    let route: MeetingRoute
    @Environment(MeetingLibrary.self) private var library
    @Environment(AppNavigation.self) private var navigation
    @State private var meeting: Meeting?
    @State private var segments: [Segment] = []
    @State private var screenshots: [MeetingScreenshot] = []
    @State private var videos: [MeetingScreenshot] = []
    @State private var audio: URL?
    @State private var speakers: [MeetingSpeaker] = []
    @State private var showNaming = false
    @State private var title = ""
    @State private var confirmDelete = false
    @State private var error: String?
    @State private var player = InlineAudioPlayer()
    @AppStorage(TranscriptFont.key) private var fontSize = TranscriptFont.standard
    @FocusState private var editingTitle: Bool

    var body: some View {
        Group {
            if let meeting {
                content(meeting)
            } else {
                ContentUnavailableView("Meeting not found", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle(meeting?.title ?? "Meeting")
        .toolbar {
            ToolbarItemGroup {
                TranscriptFontButtons()
                Button("Copy Transcript", systemImage: "doc.on.doc") {
                    copy(TranscriptExport.plainText(segments.map { ($0.speaker, $0.startMs, $0.text) }))
                }
                .help("Copy the transcript as text")
                Button("Show in Finder", systemImage: "folder") { library.showInFinder(route.meetingID) }
                    .help("Open the meeting's folder (transcript.md, summary.md)")
                Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    .help("Delete this meeting")
            }
        }
        .disabled(meeting == nil)
        .confirmationDialog("Delete “\(meeting?.title ?? "")”?", isPresented: $confirmDelete) {
            Button("Delete Meeting", role: .destructive) {
                library.delete(route.meetingID)
                navigation.showRecorder()
            }
        } message: {
            Text("It's removed from your meetings, and its folder (transcript, summary and screenshots) moves to the Trash.")
        }
        .task(id: route) { load() }
        // Right after a recording with voices, ask who they were.
        .onChange(of: library.namingRequest?.meetingID, initial: true) { _, id in
            if id == route.meetingID { showNaming = true }
        }
        .sheet(isPresented: $showNaming, onDismiss: {
            // Closed without Save or Skip (Escape): counts as Skip, so a summary waiting for names starts.
            if library.namingRequest?.meetingID == route.meetingID { library.nameSpeakers(route.meetingID, [:]) }
            load()
        }) {
            SpeakerNamingView(meetingID: route.meetingID) { showNaming = false }
        }
        // Picks up a summary written in the background, renames and action-item changes.
        .onChange(of: library.meetings) { meeting = library.meetings.first { $0.id == route.meetingID } ?? meeting }
    }

    private func content(_ meeting: Meeting) -> some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        TextField("Title", text: $title)
                            .textFieldStyle(.plain)
                            .font(.title2.bold())
                            .focused($editingTitle)
                            .onSubmit { rename() }
                            .onChange(of: editingTitle) { if !editingTitle { rename() } }
                            .fixedSize()
                            .editingOutline(editingTitle)
                        Button("Rename", systemImage: "pencil") { editingTitle = true }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .opacity(editingTitle ? 0 : 1)
                            .help("Rename the meeting (its folder is renamed too)")
                    }
                    HStack(spacing: 12) {
                        Text("\(meeting.startedAt.formatted(date: .complete, time: .shortened)) · \(TranscriptExport.timestamp(meeting.durationMs))")
                            .foregroundStyle(.secondary)
                        if let audio {
                            AudioPlayerBar(url: audio, player: player)
                        }
                    }
                    if !speakers.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Voices").font(.headline)
                                Text("· told apart in the recording").foregroundStyle(.secondary)
                                Spacer()
                                Button("Name Speakers…") { showNaming = true }
                                    .help("Listen to each voice and give it a name")
                            }
                            FlowLayout(spacing: 8) {
                                ForEach(speakers) { s in
                                    Label {
                                        Text(s.label)
                                    } icon: {
                                        Circle().fill(SpeakerStyle.color(.system, participant: s.number)).frame(width: 10, height: 10)
                                    }
                                    .padding(.horizontal, 10)
                                    .frame(height: 26)
                                    .background(Theme.surface, in: .capsule)
                                    .overlay(Capsule().strokeBorder(Theme.stroke))
                                }
                            }
                        }
                    }
                    if let details = meeting.details, !details.participants.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Text("Participants").font(.headline)
                                if let platform = details.platform {
                                    Text("· \(platform.name)").foregroundStyle(.secondary)
                                }
                            }
                            ParticipantsList(details: details)
                        }
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    SummarySection(meeting: meeting, hasTranscript: !segments.isEmpty)
                    Text("Transcript").font(.headline)
                    if segments.isEmpty {
                        Text("Nothing was transcribed.").foregroundStyle(.secondary)
                    }
                    TranscriptTextView(
                        segments: segments, screenshots: screenshots, videos: videos, fontSize: fontSize,
                        playing: playingSegment, follow: player.isPlaying, focused: route.focusSegmentID,
                        seek: { ms in
                            if audio != nil { player.play(from: Double(ms) / 1000) }
                        }
                    )
                    Text("Notes").font(.headline).padding(.top, 8)
                    NotesEditor(meetingID: meeting.id, initial: meeting.notes)
                }
                .padding()
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .onDisappear { rename() }
    }

    /// The line the audio is at: the last one starting at or before it, once it's been played.
    private var playingSegment: Int64? {
        guard audio != nil, player.isPlaying || player.currentTime > 0 else { return nil }
        let ms = Int(player.currentTime * 1000)
        return segments.last { $0.startMs <= ms }?.id
    }

    private func load() {
        guard let store = library.store else { return }
        do {
            meeting = try store.meeting(route.meetingID)
            segments = try store.segments(of: route.meetingID)
            screenshots = meeting.map { MeetingFiles.screenshots(in: $0.folder) } ?? []
            let found = meeting.map { MeetingFiles.videos(in: $0.folder) } ?? []
            if found.isEmpty {
                videos = []
            } else {
                // Shown once their thumbnails are made (only the first time a video is seen).
                Task {
                    for video in found { await VideoThumbnail.ensure(for: video.url) }
                    videos = found
                }
            }
            audio = meeting.map { $0.folder.appending(path: MeetingFiles.audioFile) }
                .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            speakers = try store.speakers(of: route.meetingID)
            title = meeting?.title ?? ""
        } catch {
            self.error = "Couldn't load the meeting: \(error.localizedDescription)"
        }
    }

    private func rename() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let meeting, !trimmed.isEmpty, trimmed != meeting.title else { return }
        library.rename(meeting.id, to: trimmed)
        self.meeting?.title = trimmed
    }
}

/// The summary, or what's happening with it: a Summarize button, progress while it's written, or why
/// it failed.
private struct SummarySection: View {
    let meeting: Meeting
    let hasTranscript: Bool
    @Environment(MeetingLibrary.self) private var library
    /// Briefly shows a checkmark after copying.
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Summary").font(.headline)
                Spacer()
                if meeting.summaryStatus == "running" {
                    ProgressView().controlSize(.small)
                    Text(library.summarizingWith[meeting.id].map { "Writing with \($0)…" } ?? "Writing…").foregroundStyle(.secondary)
                } else if hasTranscript {
                    if let summary = meeting.summary {
                        Button(copied ? "Copied" : "Copy Summary", systemImage: copied ? "checkmark" : "doc.on.doc") {
                            copy(MeetingFiles.summarySections(summary).trimmingCharacters(in: .whitespacesAndNewlines))
                            copied = true
                            Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                copied = false
                            }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .contentTransition(.symbolEffect(.replace))
                        .help("Copy the summary, decisions and action items")
                    }
                    Button(meeting.summary == nil ? "Summarize" : "Regenerate") {
                        Task { await library.summarize(meeting.id) }
                    }
                }
            }
            if meeting.summaryStatus.hasPrefix("error: ") {
                Label(String(meeting.summaryStatus.dropFirst(7)), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if let summary = meeting.summary {
                Text(summary.summary).textSelection(.enabled)
                if !summary.decisions.isEmpty {
                    Text("Decisions").font(.subheadline.bold())
                    ForEach(summary.decisions, id: \.self) { Label($0, systemImage: "checkmark.seal").textSelection(.enabled) }
                }
                if !summary.actionItems.isEmpty {
                    Text("Action items").font(.subheadline.bold())
                    ForEach(Array(summary.actionItems.enumerated()), id: \.offset) { index, item in
                        Toggle(isOn: Binding(
                            get: { item.done },
                            set: { library.setActionItem(meeting.id, index: index, done: $0) }
                        )) {
                            Text(item.text) + Text(item.owner.map { " — \($0)" } ?? "").foregroundStyle(.secondary)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                if let writtenBy = summary.writtenBy {
                    Text("Written by \(writtenBy)").font(.caption).foregroundStyle(.tertiary)
                }
            } else if meeting.summaryStatus == "none" && hasTranscript {
                Text("Summarize to get the main points, decisions and action items, written by a model on this Mac.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
    }
}
