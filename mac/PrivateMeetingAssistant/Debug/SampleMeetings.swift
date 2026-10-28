import Foundation

/// Made-up meetings shown in the list for working on its look, in debug builds launched with
/// `-sampleMeetings YES`. They're never saved, and opening one shows "Meeting not found".
enum SampleMeetings {
    /// The app a sample was recorded from (nil: voice only).
    static func app(of id: Int64) -> String? { apps[id] }

    static func isVoiceOnly(_ id: Int64) -> Bool { voiceOnly.contains(id) }

    static var all: [Meeting] {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "sampleMeetings") else { return [] }
        return samples
        #else
        return []
        #endif
    }

    private static let apps: [Int64: String] = [-1: "Zoom", -3: "Google Meet", -4: "Teams", -5: "Slack huddle", -6: "FaceTime"]
    private static let voiceOnly: Set<Int64> = [-2, -7]

    private static var samples: [Meeting] {
        let calendar = Calendar.current
        func at(daysAgo: Int, _ hour: Int, _ minute: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        func meeting(_ id: Int64, _ title: String, _ start: Date, _ ms: Int, _ summary: String?) -> Meeting {
            Meeting(
                id: id, title: title, startedAt: start, endedAt: start.addingTimeInterval(Double(ms) / 1000),
                summary: summary.map { MeetingSummary(summary: $0) }, summaryStatus: summary == nil ? "none" : "done",
                segmentCount: ms / 9000, durationMs: ms, folder: URL(fileURLWithPath: "/nonexistent/sample\(id)")
            )
        }
        return [
            meeting(-1, "Q4 roadmap review", at(daysAgo: 0, 10, 30), 3_134_000,
                    "Agreed to ship offline summaries before the sync feature. Open question on storage format for screenshots; Ana to draft a proposal by Friday."),
            meeting(-2, "1:1 with Priya", at(daysAgo: 0, 9, 0), 1_720_000,
                    "Talked through onboarding feedback and next steps for the setup flow. Priya will pair on the permissions screen next week."),
            meeting(-3, "Design crit — recording panel", at(daysAgo: 1, 16, 0), 2_702_000,
                    "Split layout preferred over tabs. Sources should show live thumbnails when screen permission is granted, app icons otherwise."),
            meeting(-4, "Customer call — Northwind", at(daysAgo: 1, 13, 15), 2_335_000,
                    "They need exportable transcripts with speaker labels. Asked about on-prem model options and retention controls."),
            meeting(-5, "Standup", at(daysAgo: 1, 9, 30), 727_000, nil),
            meeting(-6, "Hiring sync", at(daysAgo: 5, 15, 0), 1_880_000,
                    "Two candidates to onsite. Rubric updated for the Swift role; interview loop shortened to four sessions."),
            meeting(-7, "Voice memo — ideas", at(daysAgo: 7, 18, 10), 401_000,
                    "Bookmarks during recording, auto-chapters from slide changes, and a quick share-as-Markdown action."),
        ]
    }
}
