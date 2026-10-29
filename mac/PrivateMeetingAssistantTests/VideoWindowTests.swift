import Testing
@testable import Private_Meeting_Assistant

struct VideoWindowTests {
    /// A browser window's title is its visible tab's, plus the browser's own suffix.
    @Test func recognisesCallAndVideoTitles() {
        let video = [
            "(179) Investors Eye AI Payoff in Microsoft, Alphabet Earnings - YouTube and 8 more pages - Personal - Microsoft Edge",
            "Meet – abc-defg-hij - Google Chrome",
            "Meet - Weekly sync and 2 more pages - Personal - Microsoft Edge",
            "Chat | Product team | Microsoft Teams",
            "Zoom Meeting",
        ]
        let other = [
            "How to zoom in on a photo - The Verge - Personal - Microsoft Edge",
            "Inbox (49,237) - ruy@example.com - Gmail",
            "Zoom Workplace",
            "Google Docs",
        ]
        for title in video { #expect(ScreenCapture.isVideoTitle(title), "\(title)") }
        for title in other { #expect(!ScreenCapture.isVideoTitle(title), "\(title)") }
    }
}
