import SwiftUI

/// The archive: every meeting, newest first, and full-text search across transcripts, titles and summaries.
struct MeetingsView: View {
    @Environment(MeetingLibrary.self) private var library
    @State private var query = ""
    @State private var hits: [SearchHit] = []

    var body: some View {
        Group {
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                results
            } else if library.meetings.isEmpty {
                ContentUnavailableView(
                    "No meetings yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Meetings you record appear here, with their transcripts.")
                )
            } else {
                List(library.meetings) { meeting in
                    NavigationLink(value: MeetingRoute(meetingID: meeting.id)) {
                        MeetingRow(meeting: meeting)
                    }
                }
            }
        }
        .navigationTitle("Meetings")
        .searchable(text: $query, prompt: "Search transcripts, titles and summaries")
        .task(id: query) {
            // Debounce typing, then search.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            hits = (try? library.store?.search(query)) ?? []
        }
        .onAppear { library.refresh() }
        .overlay(alignment: .bottom) {
            if let error = library.error {
                Label(error, systemImage: "exclamationmark.triangle").padding().foregroundStyle(.orange)
            }
        }
    }

    private var results: some View {
        let groups = Dictionary(grouping: hits, by: \.meetingID)
        let order = hits.map(\.meetingID).reduce(into: [Int64]()) { if !$0.contains($1) { $0.append($1) } }
        return Group {
            if hits.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List {
                    ForEach(order, id: \.self) { id in
                        let meetingHits = groups[id] ?? []
                        Section {
                            ForEach(meetingHits) { hit in
                                NavigationLink(value: MeetingRoute(meetingID: hit.meetingID, focusSegmentID: hit.segmentID)) {
                                    SearchHitRow(hit: hit)
                                }
                            }
                        } header: {
                            Text("\(meetingHits[0].meetingTitle) · \(meetingHits[0].startedAt.formatted(date: .abbreviated, time: .shortened))")
                        }
                    }
                }
            }
        }
    }
}

private struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title).font(.headline)
            HStack(spacing: 8) {
                Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                Text(Duration.milliseconds(meeting.durationMs).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, zeroValueUnits: .show(length: 1))))
                Text("·")
                Text("^[\(meeting.segmentCount) line](inflect: true)")
                if meeting.summary != nil {
                    Label("Summary", systemImage: "text.alignleft").labelStyle(.iconOnly).help("Has a summary")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct SearchHitRow: View {
    let hit: SearchHit

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let source = hit.source, let start = hit.startMs {
                Text(TranscriptExport.timestamp(start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(source.speaker).font(.callout.bold()).foregroundStyle(source == .mic ? .blue : .orange)
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
