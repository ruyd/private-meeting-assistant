#if !APPSTORE
import AppKit
import Foundation
import Observation
import OSLog
import Security

private let log = Logger(subsystem: "dev.ruy.private-meeting-assistant", category: "updates")

/// A version published on GitHub Releases.
struct AppRelease: Equatable, Sendable {
    let version: String
    /// The release's notes (its CHANGELOG.md section, in Markdown).
    let notes: String
    let page: URL
    /// The notarized DMG.
    let download: URL
}

/// Keeps the Developer ID build up to date from the repository's GitHub Releases (the App Store
/// version is updated by the App Store, and has none of this). Once a day it asks GitHub for the latest
/// release, and offers it if it's newer. Installing downloads the DMG, checks the app inside is signed
/// by the same developer as this one, puts it in place of this copy and relaunches.
///
/// The check is a plain HTTPS request to api.github.com: it sends nothing about the user or their
/// meetings.
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    nonisolated static let repository = "ruyd/private-meeting-assistant"
    static let autoCheckKey = "checkForUpdates"
    private static let lastCheckKey = "lastUpdateCheck"
    private static let skippedKey = "skippedUpdateVersion"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppRelease)
        case downloading(AppRelease, fraction: Double)
        case installing(AppRelease)
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var lastChecked: Date?
    /// The version offered and put off ("Later") in this session: not offered again until relaunch.
    @ObservationIgnored private var putOff: String?
    @ObservationIgnored private var timer: Timer?

    nonisolated static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    var releasesPage: URL { URL(string: "https://github.com/\(Self.repository)/releases/latest")! }

    /// Starts the daily check (Release builds only; Debug builds check when asked).
    func start() {
        UserDefaults.standard.register(defaults: [Self.autoCheckKey: true])
        lastChecked = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
        #if DEBUG
        // For trying the updater from the command line: -checkForUpdatesAtLaunch YES.
        if UserDefaults.standard.bool(forKey: "checkForUpdatesAtLaunch") {
            Task { await check(userInitiated: true) }
        }
        #else
        // Hourly, so an update found during a recording is offered soon after it ends; GitHub is
        // asked only once a day.
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            Task { @MainActor in Updater.shared.checkIfDue() }
        }
        Task {
            try? await Task.sleep(for: .seconds(15))
            checkIfDue()
        }
        #endif
    }

    private func checkIfDue() {
        guard UserDefaults.standard.bool(forKey: Self.autoCheckKey) else { return }
        switch status {
        case .available(let release):
            if release.version != putOff { offer(release) }
        case .idle, .upToDate, .failed:
            if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.checkInterval { return }
            Task { await check(userInitiated: false) }
        case .checking, .downloading, .installing:
            break
        }
    }

    /// Asks GitHub for the latest release. `userInitiated` (Check for Updates…): offers it even if it
    /// was skipped, and says so when there's nothing newer.
    func check(userInitiated: Bool) async {
        switch status {
        case .checking, .downloading, .installing: return
        default: break
        }
        status = .checking
        do {
            let latest = try await Self.latestRelease()
            lastChecked = .now
            UserDefaults.standard.set(lastChecked, forKey: Self.lastCheckKey)
            guard let latest, Self.isNewer(latest.version, than: Self.currentVersion) else {
                status = .upToDate
                if userInitiated { announceUpToDate() }
                return
            }
            log.info("Version \(latest.version, privacy: .public) is available")
            status = .available(latest)
            let skipped = UserDefaults.standard.string(forKey: Self.skippedKey)
            if userInitiated || (latest.version != skipped && latest.version != putOff) {
                offer(latest)
            }
        } catch {
            log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            status = .failed("Couldn't check for updates: \(error.localizedDescription)")
            if userInitiated { announce(status) }
        }
    }

    // MARK: - Asking

    /// Shows the release and its notes, with Install and Relaunch, Later and Skip This Version.
    /// Waits while something is being recorded: installing relaunches the app.
    func offer(_ release: AppRelease) {
        guard !RecordingActivity.shared.isRecording else { return }
        putOff = release.version
        let alert = NSAlert()
        alert.messageText = "Private Meeting Assistant \(release.version) is available"
        alert.informativeText = "You have \(Self.currentVersion). Installing replaces this copy of the app and relaunches it; your meetings and settings stay as they are."
        alert.accessoryView = Self.notesView(release.notes)
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { await install(release) }
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(release.version, forKey: Self.skippedKey)
        default:
            break
        }
    }

    private func announceUpToDate() {
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "Private Meeting Assistant \(Self.currentVersion) is the newest version."
        NSApp.activate()
        alert.runModal()
    }

    private func announce(_ status: Status) {
        guard case .failed(let message) = status else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't update"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open GitHub")
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(releasesPage) }
    }

    private static func notesView(_ markdown: String) -> NSView {
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 440, height: 200)
        scroll.borderType = .bezelBorder
        guard let text = scroll.documentView as? NSTextView else { return scroll }
        text.isEditable = false
        text.textContainerInset = NSSize(width: 6, height: 6)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let notes = markdown.isEmpty ? "No release notes." : markdown
        // Markdown only to drop its markers (**, `, links' brackets); shown as plain text.
        let plain = (try? AttributedString(markdown: notes, options: options)).map { String($0.characters) } ?? notes
        text.textStorage?.setAttributedString(NSAttributedString(string: plain, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.textColor,
        ]))
        return scroll
    }

    // MARK: - Installing

    /// Downloads the release, checks it and puts it in place of this copy, then relaunches.
    func install(_ release: AppRelease) async {
        guard !RecordingActivity.shared.isRecording else {
            status = .failed("Stop the recording first: installing relaunches the app.")
            return
        }
        let target = Bundle.main.bundleURL
        do {
            try Installer.checkReplaceable(target)
            status = .downloading(release, fraction: 0)
            let dmg = try await Download.file(from: release.download) { fraction in
                Task { @MainActor in
                    if case .downloading(let release, _) = Updater.shared.status {
                        Updater.shared.status = .downloading(release, fraction: fraction)
                    }
                }
            }
            status = .installing(release)
            let version = release.version
            try await Task.detached {
                defer { try? FileManager.default.removeItem(at: dmg) }
                let staged = try Installer.stage(dmg: dmg, replacing: target)
                defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
                try Installer.verify(staged, version: version)
                try Installer.replace(target, with: staged)
            }.value
            log.info("Installed \(version, privacy: .public); relaunching")
            try Installer.relaunch(target)
            NSApp.terminate(nil)
        } catch {
            log.error("Update failed: \(error.localizedDescription, privacy: .public)")
            status = .failed(error.localizedDescription)
            announce(status)
            status = .available(release)
        }
    }

    // MARK: - GitHub

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let body: String?
        let html_url: URL
        let assets: [Asset]
    }

    /// The latest published release (GitHub leaves out drafts and pre-releases), or nil if there's
    /// none yet or it has no DMG.
    nonisolated static func latestRelease() async throws -> AppRelease? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        #if DEBUG
        // For trying the updater: a JSON file shaped like GitHub's answer (defaults write … updateFeedURL).
        if let feed = UserDefaults.standard.string(forKey: "updateFeedURL").flatMap(URL.init(string:)) { request.url = feed }
        #endif
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("PrivateMeetingAssistant/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil }
        guard code == 200 else { throw UpdateError("GitHub answered \(code).") }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let dmg = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else { return nil }
        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        return AppRelease(version: version, notes: release.body ?? "", page: release.html_url, download: dmg.browser_download_url)
    }

    /// Whether version `a` (1.2.10) is newer than `b` (1.2.9).
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Download

/// Downloads a file with progress, to a temporary file of its own.
private final class Download: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private let progress: @Sendable (Double) -> Void

    private init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    static func file(from url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let download = Download(progress: progress)
        // Its own delegate queue (serial), so the continuation is only touched there.
        let session = URLSession(configuration: .ephemeral, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            session.delegateQueue.addOperation {
                download.continuation = continuation
                session.downloadTask(with: url).resume()
            }
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { return finish(.failure(UpdateError("The download failed (\(code))."))) }
        // The file at `location` is deleted when this returns.
        let file = FileManager.default.temporaryDirectory.appending(path: "PrivateMeetingAssistant-update-\(UUID().uuidString).dmg")
        do {
            try FileManager.default.moveItem(at: location, to: file)
            finish(.success(file))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}

// MARK: - Installer

/// The steps of putting a downloaded version in place. Everything but `relaunch` runs off the main actor.
enum Installer {
    /// Fails unless this copy of the app can be replaced: not run from the DMG or a quarantined
    /// download (App Translocation), and in a folder this user can write to.
    nonisolated static func checkReplaceable(_ app: URL) throws {
        let moveIt = "Move Private Meeting Assistant to your Applications folder, open it from there, then update."
        if app.path.contains("/AppTranslocation/") { throw UpdateError("This copy runs from a temporary location. \(moveIt)") }
        let values = try? app.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        if values?.volumeIsReadOnly == true { throw UpdateError("This copy runs from a read-only disk. \(moveIt)") }
        let folder = app.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw UpdateError("You can't change apps in \(folder.path). Download the new version from GitHub and replace the app yourself, or ask an administrator.")
        }
    }

    /// Mounts the DMG and copies its app next to `replacing` (same volume, so the swap is a rename).
    /// Returns the copy, alone in a folder of its own that the caller removes.
    nonisolated static func stage(dmg: URL, replacing app: URL) throws -> URL {
        let fm = FileManager.default
        let mount = fm.temporaryDirectory.appending(path: "PrivateMeetingAssistant-mount-\(UUID().uuidString)")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: mount) }
        try run("/usr/bin/hdiutil", "attach", dmg.path, "-nobrowse", "-noautoopen", "-readonly", "-mountpoint", mount.path)
        defer { _ = try? run("/usr/bin/hdiutil", "detach", mount.path, "-force") }

        let apps = try fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil).filter { $0.pathExtension == "app" }
        guard let source = apps.first(where: { $0.lastPathComponent == app.lastPathComponent }) ?? apps.first else {
            throw UpdateError("The download has no app in it.")
        }
        let folder = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        let staged = folder.appending(path: app.lastPathComponent)
        // ditto keeps the code signature, extended attributes and the notarization ticket.
        try run("/usr/bin/ditto", source.path, staged.path)
        return staged
    }

    /// Fails unless `app` is validly signed, by the same developer and with the same identifier as the
    /// running app (its designated requirement), and is `version`.
    nonisolated static func verify(_ app: URL, version: String) throws {
        var me: SecCode?
        var myStatic: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &myStatic) == errSecSuccess, let myStatic,
              SecCodeCopyDesignatedRequirement(myStatic, [], &requirement) == errSecSuccess, let requirement
        else { throw UpdateError("Couldn't read this app's signature, so the download can't be checked.") }

        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError("The downloaded app isn't signed.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        var error: Unmanaged<CFError>?
        guard SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &error) == errSecSuccess else {
            let reason = (error?.takeRetainedValue()).map { CFErrorCopyDescription($0) as String } ?? "unknown reason"
            throw UpdateError("The downloaded app isn't signed by this app's developer, so it wasn't installed (\(reason)).")
        }
        let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist"))
        let found = info?["CFBundleShortVersionString"] as? String
        guard found == version else {
            throw UpdateError("The download is version \(found ?? "unknown"), not \(version).")
        }
    }

    /// Swaps the new copy in place of the old one. The running app keeps working from the files it has
    /// open until it relaunches.
    nonisolated static func replace(_ app: URL, with staged: URL) throws {
        _ = try FileManager.default.replaceItemAt(app, withItemAt: staged)
    }

    /// Opens `app` again once this process has quit.
    @MainActor static func relaunch(_ app: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                            "sh", String(pid), app.path]
        try waiter.run()
    }

    @discardableResult
    private nonisolated static func run(_ tool: String, _ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw UpdateError("\((tool as NSString).lastPathComponent) failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return text
    }
}
#endif
