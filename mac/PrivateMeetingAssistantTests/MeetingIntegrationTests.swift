import Foundation
import Testing
@testable import Private_Meeting_Assistant

struct MeetingLinkTests {
    @Test func parsesLinksAndIDs() {
        #expect(MeetingLink.parse("https://meet.google.com/abc-defg-hij?authuser=0") == .googleMeet(code: "abc-defg-hij"))
        #expect(MeetingLink.parse("meet.google.com/abc-defg-hij") == .googleMeet(code: "abc-defg-hij"))
        #expect(MeetingLink.parse(" ABCDEFGHIJ ") == .googleMeet(code: "abc-defg-hij"))
        #expect(MeetingLink.parse("https://acme.zoom.us/j/85012345678?pwd=xyz") == .zoom(id: "85012345678"))
        #expect(MeetingLink.parse("850 1234 5678") == .numeric("85012345678"))
        #expect(MeetingLink.parse("https://zoom.us/my/someone") == nil)
        let teams = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%7d"
        #expect(MeetingLink.parse(teams)?.platform == .teams)
        #expect(MeetingLink.parse("hello world") == nil)
        #expect(MeetingLink.parse("12345") == nil)
    }

    @Test func findsTheJoinLinkInText() throws {
        let text = "Room 4B\nJoin Zoom Meeting https://us02web.zoom.us/j/81234567890?pwd=abc\nhttps://example.com/agenda"
        let found = try #require(MeetingLink.find(in: text))
        #expect(found.link == .zoom(id: "81234567890"))
        #expect(MeetingLink.find(in: "see https://example.com") == nil)
    }
}

struct MeetingServiceParsingTests {
    @Test func googleEvents() throws {
        let json = """
        {"items": [
          {"id": "e1", "status": "confirmed", "summary": "Pricing sync",
           "start": {"dateTime": "2026-10-28T14:00:00-07:00"}, "end": {"dateTime": "2026-10-28T14:30:00-07:00"},
           "hangoutLink": "https://meet.google.com/abc-defg-hij",
           "organizer": {"email": "priya@acme.com", "displayName": "Priya Shah"},
           "attendees": [
             {"email": "priya@acme.com", "displayName": "Priya Shah", "organizer": true, "responseStatus": "accepted"},
             {"email": "me@acme.com", "self": true, "responseStatus": "accepted"},
             {"email": "bob@acme.com", "optional": true, "responseStatus": "declined"},
             {"email": "room-4b@resource.calendar.google.com", "resource": true}
           ]},
          {"id": "e2", "summary": "Holiday", "start": {"date": "2026-10-29"}, "end": {"date": "2026-10-30"}},
          {"id": "e3", "status": "cancelled", "start": {"dateTime": "2026-10-28T16:00:00Z"}},
          {"id": "e4", "summary": "Vendor call", "start": {"dateTime": "2026-10-28T18:00:00Z"},
           "location": "https://acme.zoom.us/j/81234567890"}
        ]}
        """
        let meetings = try GoogleCalendarService.parse(Data(json.utf8), me: "me@acme.com")
        #expect(meetings.map(\.externalID) == ["e1", "e4"])

        let m = meetings[0]
        #expect(m.title == "Pricing sync" && m.platform == .googleMeet)
        #expect(m.start == parseISODate("2026-10-28T21:00:00Z"))
        #expect(m.participants.count == 3)
        #expect(m.organizer?.displayName == "Priya Shah")
        #expect(m.participants.first { $0.isMe }?.email == "me@acme.com")
        let bob = try #require(m.participants.first { $0.email == "bob@acme.com" })
        #expect(bob.role == .optional && bob.response == .declined)
        #expect(m.others.map(\.displayName) == ["Priya Shah", "bob@acme.com"])

        #expect(meetings[1].platform == .zoom)
    }

    @Test func microsoftEvents() throws {
        let json = """
        {"value": [
          {"id": "m1", "subject": "Board prep", "isAllDay": false, "isCancelled": false,
           "start": {"dateTime": "2026-10-28T15:00:00.0000000", "timeZone": "UTC"},
           "end": {"dateTime": "2026-10-28T16:00:00.0000000", "timeZone": "UTC"},
           "organizer": {"emailAddress": {"name": "Ana Ruiz", "address": "ana@contoso.com"}},
           "attendees": [
             {"type": "required", "status": {"response": "accepted"}, "emailAddress": {"name": "Ana Ruiz", "address": "ana@contoso.com"}},
             {"type": "required", "status": {"response": "tentativelyAccepted"}, "emailAddress": {"name": "Me Myself", "address": "ME@contoso.com"}},
             {"type": "resource", "emailAddress": {"name": "Room", "address": "room@contoso.com"}}
           ],
           "onlineMeeting": {"joinUrl": "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0"}}
        ]}
        """
        let m = try #require(try MicrosoftGraphService.parseEvents(Data(json.utf8), me: "me@contoso.com").first)
        #expect(m.platform == .teams)
        #expect(m.start == parseISODate("2026-10-28T15:00:00Z"))
        #expect(m.participants.map(\.displayName) == ["Ana Ruiz", "Me Myself"])
        #expect(m.participants[0].role == .organizer)
        #expect(m.participants[1].isMe && m.participants[1].response == .tentative)
    }

    @Test func zoomMeeting() throws {
        let json = """
        {"id": 81234567890, "topic": "Vendor call", "start_time": "2026-10-28T18:00:00Z", "duration": 45,
         "join_url": "https://acme.zoom.us/j/81234567890", "host_email": "me@acme.com",
         "settings": {"meeting_invitees": [{"email": "vendor@supplier.com"}], "alternative_hosts": "lee@acme.com"}}
        """
        let m = try #require(try ZoomService.parseMeeting(Data(json.utf8), me: "me@acme.com"))
        #expect(m.end == parseISODate("2026-10-28T18:45:00Z"))
        #expect(m.participants.map(\.email) == ["me@acme.com", "vendor@supplier.com", "lee@acme.com"])
        #expect(m.participants[0].isMe && m.participants[0].role == .organizer)
    }

    @MainActor @Test func mergePrefersTheCalendarEntry() {
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        let url = URL(string: "https://acme.zoom.us/j/81234567890")!
        let zoom = MeetingDetails(provider: .zoom, externalID: "81234567890", title: "Vendor call", start: start, platform: .zoom, joinURL: url)
        let calendar = MeetingDetails(
            provider: .google, externalID: "e4", title: "Vendor call", start: start, platform: .zoom,
            joinURL: URL(string: "https://acme.zoom.us/j/81234567890?pwd=abc")!,
            participants: [MeetingParticipant(email: "vendor@supplier.com")]
        )
        let earlier = MeetingDetails(provider: .google, externalID: "e1", title: "Standup", start: start.addingTimeInterval(-600))
        let merged = MeetingAccounts.merge([zoom, earlier, calendar])
        #expect(merged.map(\.id) == ["google:e1", "google:e4"])
        #expect(MeetingAccounts.matches(calendar, .numeric("81234567890")))
    }
}

struct MeetingDetailsStorageTests {
    @Test func detailsAreSavedSearchableAndWritten() throws {
        let store = try MeetingStore.inMemory()
        let details = MeetingDetails(
            provider: .google, externalID: "e1", title: "Pricing sync", start: Date(), platform: .googleMeet,
            joinURL: URL(string: "https://meet.google.com/abc-defg-hij"),
            participants: [
                MeetingParticipant(name: "Priya Shah", email: "priya@acme.com", role: .organizer, response: .accepted),
                MeetingParticipant(email: "me@acme.com", isMe: true),
            ]
        )
        let id = try store.createMeeting(title: "Pricing sync", startedAt: Date(), folder: URL(fileURLWithPath: "/tmp/x"), details: details)
        let meeting = try #require(try store.meeting(id))
        #expect(meeting.details == details)
        #expect(try store.search("priya").contains { $0.meetingID == id })

        let md = MeetingFiles.transcriptMarkdown(meeting, [])
        #expect(md.contains("## Participants"))
        #expect(md.contains("- me@acme.com — Me\n- Priya Shah <priya@acme.com> — organizer"))
        #expect(md.contains("Google Meet: <https://meet.google.com/abc-defg-hij>"))

        try store.setDetails(id, nil)
        #expect(try store.meeting(id)?.details == nil)
        #expect(try store.search("priya").isEmpty)
    }

    @Test func summaryPromptNamesParticipants() {
        let note = Summarizer.participantsNote([
            MeetingParticipant(name: "Ruy", email: "me@acme.com", isMe: true),
            MeetingParticipant(name: "Priya Shah", role: .organizer),
            MeetingParticipant(name: "Bob", response: .declined),
        ])
        #expect(note.contains("\"Me\" is Ruy."))
        #expect(note.contains("Priya Shah") && !note.contains("Bob"))
        #expect(Summarizer.participantsNote([]).isEmpty)
    }
}
