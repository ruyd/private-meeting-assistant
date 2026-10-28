import AppKit
import SwiftUI

/// One meeting: title, summary (if it has one) and transcript, with copy, export and delete.
struct MeetingView: View {
    let route: MeetingRoute
    @Environment(MeetingLibrary.self) private var library
    @Environment(AppNavigation.self) private var navigation
    @State private var meeting: Meeting?
    @State private var segments: [Segment] = []
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
                    copy(TranscriptExport.plainText(segments.map { ($0.source, $0.startMs, $0.text) }))
                }
                .help("Copy the transcript as text")
                Button("Show in Finder", systemImage: "folder") { library.showInFinder(route.meetingID) }
                    .help("Open the meeting's folder (transcript.md, summary.md)")
                    .disabled(meeting?.folder == nil && MeetingFiles.root == nil)
                Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    .help("Delete this meeting")
            }
        }
        .disabled(meeting == nil)
        .confirmationDialog("Delete “\(meeting?.title ?? "")”?", isPresented: $confirmDelete) {
            Button("Delete Meeting", role: .destructive) {
                library.delete(route.meetingID)
                navigation.meetingPath.removeAll()
            }
        } message: {
            Text(meeting?.folder == nil
                ? "It's removed from your meetings."
                : "It's removed from your meetings, and its folder (transcript and summary) moves to the Trash.")
        }
        .task(id: route) { load() }
    }

    private func content(_ meeting: Meeting) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("Title", text: $title)
                        .textFieldStyle(.plain)
                        .font(.title2.bold())
                        .onSubmit { rename() }
                    Text("\(meeting.startedAt.formatted(date: .complete, time: .shortened)) · \(TranscriptExport.timestamp(meeting.durationMs))")
                        .foregroundStyle(.secondary)
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    if let summary = meeting.summary {
                        SummaryView(summary: summary)
                    }
                    Text("Transcript").font(.headline)
                    if segments.isEmpty {
                        Text("Nothing was transcribed.").foregroundStyle(.secondary)
                    }
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(segments) { segment in
                            TranscriptRow(
                                source: segment.source, startMs: segment.startMs, text: segment.text,
                                isFocused: segment.id == route.focusSegmentID
                            )
                            .id(segment.id)
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

    private func load() {
        guard let store = library.store else { return }
        do {
            meeting = try store.meeting(route.meetingID)
            segments = try store.segments(of: route.meetingID)
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

private struct SummaryView: View {
    let summary: MeetingSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Summary").font(.headline)
            Text(summary.summary).textSelection(.enabled)
            if !summary.decisions.isEmpty {
                Text("Decisions").font(.subheadline.bold())
                ForEach(summary.decisions, id: \.self) { Label($0, systemImage: "checkmark.seal").textSelection(.enabled) }
            }
            if !summary.actionItems.isEmpty {
                Text("Action items").font(.subheadline.bold())
                ForEach(summary.actionItems, id: \.self) { item in
                    Label {
                        Text(item.text) + Text(item.owner.map { " — \($0)" } ?? "").foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: item.done ? "checkmark.square" : "square")
                    }
                    .textSelection(.enabled)
                }
            }
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
    }
}
