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
        .sheet(isPresented: $showNaming, onDismiss: load) {
            SpeakerNamingView(meetingID: route.meetingID) { showNaming = false }
        }
        // Picks up a summary written in the background, renames and action-item changes.
        .onChange(of: library.meetings) { meeting = library.meetings.first { $0.id == route.meetingID } ?? meeting }
    }

    private func content(_ meeting: Meeting) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("Title", text: $title)
                        .textFieldStyle(.plain)
                        .font(.title2.bold())
                        .onSubmit { rename() }
                    HStack(spacing: 12) {
                        Text("\(meeting.startedAt.formatted(date: .complete, time: .shortened)) · \(TranscriptExport.timestamp(meeting.durationMs))")
                            .foregroundStyle(.secondary)
                        if let audio {
                            Button("Play Audio", systemImage: "waveform") { NSWorkspace.shared.open(audio) }
                                .controlSize(.small)
                                .help("Open the meeting's audio recording (audio.m4a)")
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
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(segments) { segment in
                            ForEach(screenshots(before: segment)) { ScreenshotRow(shot: $0, leadingInset: 62) }
                            ForEach(media(videos, before: segment)) { VideoRow(video: $0, leadingInset: 62) }
                            TranscriptRow(
                                segment: segment, speakerWidth: speakerWidth,
                                isFocused: segment.id == route.focusSegmentID
                            )
                            .id(segment.id)
                        }
                        ForEach(screenshots.filter { $0.atMs > (segments.last?.startMs ?? -1) }) {
                            ScreenshotRow(shot: $0, leadingInset: 62)
                        }
                        ForEach(videos.filter { $0.atMs > (segments.last?.startMs ?? -1) }) {
                            VideoRow(video: $0, leadingInset: 62)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onAppear {
                if let focus = route.focusSegmentID {
                    DispatchQueue.main.async { proxy.scrollTo(focus, anchor: .center) }
                }
            }
        }
        .onDisappear { rename() }
    }

    private var speakerWidth: CGFloat { segments.contains { $0.participant != nil } ? 110 : 44 }

    /// Screenshots taken after the previous line started and up to this one.
    private func screenshots(before segment: Segment) -> [MeetingScreenshot] { media(screenshots, before: segment) }

    /// Screenshots or videos from after the previous line started and up to this one.
    private func media(_ items: [MeetingScreenshot], before segment: Segment) -> [MeetingScreenshot] {
        guard let index = segments.firstIndex(of: segment) else { return [] }
        let after = index == 0 ? -1 : segments[index - 1].startMs
        return items.filter { $0.atMs > after && $0.atMs <= segment.startMs }
    }

    private func load() {
        guard let store = library.store else { return }
        do {
            meeting = try store.meeting(route.meetingID)
            segments = try store.segments(of: route.meetingID)
            screenshots = meeting.map { MeetingFiles.screenshots(in: $0.folder) } ?? []
            videos = meeting.map { MeetingFiles.videos(in: $0.folder) } ?? []
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Summary").font(.headline)
                Spacer()
                if meeting.summaryStatus == "running" {
                    ProgressView().controlSize(.small)
                    Text("Writing with \(MeetingLibrary.summaryModel)…").foregroundStyle(.secondary)
                } else if hasTranscript {
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
            } else if meeting.summaryStatus == "none" && hasTranscript {
                Text("Summarize to get the main points, decisions and action items, written by a model on this Mac.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
    }
}
