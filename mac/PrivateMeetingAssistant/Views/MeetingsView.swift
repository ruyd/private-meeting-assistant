import SwiftUI

/// The left half of the window: a "New Recording" (or "Now recording") row, then every meeting newest
/// first as cards, and full-text search across transcripts, titles and summaries.
struct MeetingsView: View {
    let recorder: Recorder
    @Environment(MeetingLibrary.self) private var library
    @Environment(AppNavigation.self) private var navigation
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @FocusState private var searchFocused: Bool

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        @Bindable var navigation = navigation
        List(selection: $navigation.selection) {
            Section {
                RecorderRow(recorder: recorder)
                    .tag(AppNavigation.Selection.recorder)
            } header: {
                sectionTitle("Now")
            }
            if isSearching {
                results
            } else {
                ForEach(groups, id: \.label) { group in
                    Section {
                        ForEach(group.meetings) { meeting in
                            MeetingCard(meeting: meeting)
                                .tag(AppNavigation.Selection.meeting(MeetingRoute(meetingID: meeting.id)))
                        }
                    } header: {
                        sectionTitle(group.label)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebar)
        .overlay {
            if isSearching && hits.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if !isSearching && pastMeetings.isEmpty {
                ContentUnavailableView(
                    "No meetings yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Meetings you record appear here, with their summaries and transcripts.")
                )
            }
        }
        .navigationTitle("Meetings")
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .task(id: query) {
            // Debounce typing, then search.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            hits = (try? library.store?.search(query)) ?? []
        }
        .onAppear { library.refresh() }
        .safeAreaInset(edge: .bottom) {
            if let error = library.error {
                Label(error, systemImage: "exclamationmark.triangle").padding().foregroundStyle(.orange)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Meetings").font(.system(size: 18, weight: .semibold))
                Spacer()
                Text("^[\(pastMeetings.count) recording](inflect: true) · stored locally")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            searchField
        }
        .padding(.top, 4)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $query, prompt: Text("Search titles, summaries, transcripts"))
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onExitCommand { query = "" }
            if query.isEmpty {
                Text("⌘F")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
                    .accessibilityHidden(true)
            } else {
                Button("Clear Search", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Theme.surface, in: .rect(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(searchFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(Theme.stroke), lineWidth: searchFocused ? 1.5 : 1)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .background {
            // ⌘F jumps to the search field from anywhere in the window.
            Button("Search Meetings") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
    }

    /// Everything but the meeting being recorded, which has the row at the top.
    private var pastMeetings: [Meeting] {
        let live = recorder.phase == .idle ? nil : recorder.meetingID
        return library.meetings.filter { $0.id != live }
    }

    private func sectionTitle(_ label: String) -> some View {
        Text(label.uppercased()).font(.caption2.weight(.semibold)).tracking(0.6)
    }

    /// Today, Yesterday, Last Week (the five days before), then Older.
    private var groups: [(label: String, meetings: [Meeting])] {
        let calendar = Calendar.current
        var result: [(label: String, meetings: [Meeting])] = []
        for meeting in pastMeetings {
            let date = meeting.startedAt
            let label = if calendar.isDateInToday(date) {
                "Today"
            } else if calendar.isDateInYesterday(date) {
                "Yesterday"
            } else if let weekAgo = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: .now)), date >= weekAgo {
                "Last Week"
            } else {
                "Older"
            }
            if result.last?.label == label {
                result[result.count - 1].meetings.append(meeting)
            } else {
                result.append((label, [meeting]))
            }
        }
        return result
    }

    @ViewBuilder private var results: some View {
        let groups = Dictionary(grouping: hits, by: \.meetingID)
        let order = hits.map(\.meetingID).reduce(into: [Int64]()) { if !$0.contains($1) { $0.append($1) } }
        ForEach(order, id: \.self) { id in
            let meetingHits = groups[id] ?? []
            Section {
                ForEach(meetingHits) { hit in
                    SearchHitRow(hit: hit)
                        .tag(AppNavigation.Selection.meeting(MeetingRoute(meetingID: hit.meetingID, focusSegmentID: hit.segmentID)))
                }
            } header: {
                Text("\(meetingHits[0].meetingTitle) · \(meetingHits[0].startedAt.formatted(date: .abbreviated, time: .shortened))")
            }
        }
    }
}

/// The first row: "New Recording", or the meeting being recorded with its running time.
private struct RecorderRow: View {
    let recorder: Recorder
    @Environment(MeetingLibrary.self) private var library

    var body: some View {
        HStack(spacing: 12) {
            if let startedAt = recorder.startedAt {
                Image(systemName: "record.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(library.meetings.first { $0.id == recorder.meetingID }?.title ?? "Recording")
                        .font(.headline)
                        .lineLimit(1)
                    Text(recorder.phase == .finishing ? "Finishing the transcript…" : "Recording")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ElapsedTime(since: startedAt)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.red)
            } else {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Recording").font(.headline)
                    Text("Pick a microphone and the apps to listen to").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

/// One meeting: a screenshot from it (or the tiled placeholder), the subject, the start of its summary,
/// duration and time.
private struct MeetingCard: View {
    let meeting: Meeting
    @State private var thumbnail: CGImage?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            preview
                .frame(width: 96, height: 60)
                .clipShape(.rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.stroke))

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(meeting.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(TranscriptExport.timestamp(meeting.durationMs))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(summaryLine)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .lineSpacing(1)
                Text(whenLine)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
        .task(id: meeting.folder) {
            let folder = meeting.folder
            thumbnail = await Task.detached {
                if let shot = MeetingFiles.screenshots(in: folder).first { return ScreenCapture.thumbnail(of: shot.url, maxPixels: 240) }
                // Else the first video's still.
                guard let video = MeetingFiles.videos(in: folder).first, let still = await VideoThumbnail.ensure(for: video.url) else { return nil }
                return ScreenCapture.thumbnail(of: still, maxPixels: 240)
            }.value
        }
    }

    @ViewBuilder private var preview: some View {
        if let thumbnail {
            Image(decorative: thumbnail, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            // No screenshots: nothing to show of it but that it was heard.
            ZStack {
                Rectangle().fill(Theme.raised)
                Image(systemName: "mic").font(.system(size: 18)).foregroundStyle(.secondary)
            }
        }
    }

    private var whenLine: String {
        meeting.startedAt.formatted(date: .omitted, time: .shortened)
    }

    private var summaryLine: String {
        if let summary = meeting.summary { return summary.summary }
        if meeting.summaryStatus == "running" { return "Writing the summary…" }
        if meeting.segmentCount == 0 { return "Nothing was transcribed." }
        return meeting.summaryStatus.hasPrefix("error: ")
            ? "The summary couldn't be written."
            : "No summary yet · \(meeting.segmentCount) lines"
    }
}

/// "14:32", counting up once a second.
struct ElapsedTime: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text(TranscriptExport.timestamp(Int(context.date.timeIntervalSince(since) * 1000)))
        }
    }
}

private struct SearchHitRow: View {
    let hit: SearchHit

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let source = hit.source, let start = hit.startMs {
                Text(TranscriptExport.timestamp(start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(hit.speaker ?? source.speaker).font(.callout.bold())
                    .foregroundStyle(SpeakerStyle.color(source, participant: hit.participant))
            } else {
                Text("Title / summary").font(.caption).foregroundStyle(.secondary)
            }
            Text(Self.highlighted(hit.snippet)).lineLimit(2)
        }
    }

    /// The snippet with its matches in bold on a highlight.
    static func highlighted(_ snippet: String) -> AttributedString {
        var result = AttributedString()
        var rest = Substring(snippet)
        while let open = rest.range(of: MeetingStore.highlightStart) {
            result += AttributedString(String(rest[..<open.lowerBound]))
            rest = rest[open.upperBound...]
            let close = rest.range(of: MeetingStore.highlightEnd) ?? rest.endIndex..<rest.endIndex
            var match = AttributedString(String(rest[..<close.lowerBound]))
            match.inlinePresentationIntent = .stronglyEmphasized
            match.backgroundColor = .yellow.opacity(0.35)
            result += match
            rest = rest[close.upperBound...]
        }
        return result + AttributedString(String(rest))
    }
}
