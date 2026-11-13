import Foundation
import Testing
@testable import Private_Meeting_Assistant

struct UpdaterTests {
    @Test func comparesVersionsNumerically() {
        #expect(Updater.isNewer("1.0.1", than: "1.0.0"))
        #expect(Updater.isNewer("1.2.10", than: "1.2.9"))
        #expect(Updater.isNewer("2.0", than: "1.9.9"))
        #expect(Updater.isNewer("1.1", than: "1.0.9"))
        #expect(!Updater.isNewer("1.0.0", than: "1.0.0"))
        #expect(!Updater.isNewer("1.0", than: "1.0.0"))
        #expect(!Updater.isNewer("0.9.9", than: "1.0.0"))
    }

    /// An app not signed by this app's developer (here, the system's Calculator) is refused.
    @Test func refusesAnAppFromAnotherDeveloper() {
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        #expect(throws: UpdateError.self) { try Installer.verify(calculator, version: "1.0") }
    }
}
