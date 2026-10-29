import AppKit
import ImageIO
import ScreenCaptureKit

/// Screenshots during a meeting, via ScreenCaptureKit: only ever of the app being recorded, never the
/// rest of the screen. Needs the Screen Recording permission, which the first screenshot asks for.
enum ScreenCapture {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// A PNG of `window` (the recorder picks which: `Recorder.captureWindow`).
    @MainActor static func screenshot(of window: SCWindow) async throws -> Data {
        let image = try await capture(window)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ScreenCaptureError.encoding
        }
        return png
    }

    /// The app's largest normal window on screen.
    static func mainWindow(of bundleID: String, in content: SCShareableContent) -> SCWindow? {
        windows(of: bundleID, in: content).max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// The app's ordinary windows (not menus, panels or tiny helpers).
    static func windows(of bundleID: String, in content: SCShareableContent) -> [SCWindow] {
        content.windows.filter {
            $0.owningApplication?.bundleIdentifier == bundleID && $0.windowLayer == 0
                && $0.frame.width >= 200 && $0.frame.height >= 150
        }
    }

    /// Titles of windows showing a call or a video: a browser window's title is its visible tab's.
    private static let videoTitles = [
        " - YouTube", "Meet - ", "Meet – ", "Google Meet", "Microsoft Teams", "Zoom Meeting", "Zoom Webinar",
        "Webex", "Whereby", "Vimeo", "Twitch", "Jitsi Meet", "Huddle",
    ]

    /// The one window whose title shows it has a call or a video in it; nil if none does, or several.
    static func videoWindow(among windows: [SCWindow]) -> SCWindow? {
        let matches = windows.filter { isVideoTitle($0.title ?? "") }
        return matches.count == 1 ? matches[0] : nil
    }

    static func isVideoTitle(_ title: String) -> Bool {
        videoTitles.contains { title.contains($0) }
    }

    /// How much of `window`'s height an inch is, on the display it's on (from the display's physical
    /// size; 100 points an inch if it doesn't say).
    static func inchShare(of window: SCWindow) -> Double {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(CGPoint(x: window.frame.midX, y: window.frame.midY), 1, &display, &count)
        let millimetres = count > 0 ? CGDisplayScreenSize(display).width : 0
        let points = count > 0 ? CGDisplayBounds(display).width : 0
        let perInch = millimetres > 0 && points > 0 ? points / (millimetres / 25.4) : 100
        return min(perInch / max(window.frame.height, 1), 0.5)
    }

    /// A small picture of a window, for choosing one.
    @MainActor static func preview(of window: SCWindow, width: CGFloat = 480) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(width)
        config.height = max(Int(width * window.frame.height / max(window.frame.width, 1)), 1)
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    @MainActor private static func capture(_ window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return try await capture(filter, size: window.frame.size)
    }

    /// At full (Retina) resolution.
    @MainActor private static func capture(_ filter: SCContentFilter, size: CGSize) async throws -> CGImage {
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = max(Int(size.width * scale), 1)
        config.height = max(Int(size.height * scale), 1)
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// A downscaled copy of an image file, for lists, without decoding the full picture.
    static func thumbnail(of url: URL, maxPixels: Int = 320) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The app's icon, for source tiles and chips.
    @MainActor static func icon(of bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}

enum ScreenCaptureError: LocalizedError {
    case permission
    case noWindow(String)
    case encoding

    var errorDescription: String? {
        switch self {
        case .permission: "Allow Screen Recording for Private Meeting Assistant in System Settings › Privacy & Security, then try again."
        case .noWindow(let app): "\(app) has no window on screen. Bring its meeting window into view (not minimized or in another Space), then try again."
        case .encoding: "Couldn't save the image."
        }
    }
}

extension SystemAudioTarget {
    /// The app to screenshot, or nil when recording all system audio (no screenshots then).
    var bundleID: String? {
        if case .app(let id, _) = self { id } else { nil }
    }
}
