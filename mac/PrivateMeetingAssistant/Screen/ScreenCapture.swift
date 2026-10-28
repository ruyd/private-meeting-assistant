import AppKit
import ImageIO
import ScreenCaptureKit

/// Screenshots during a meeting, via ScreenCaptureKit. Needs the Screen Recording permission, which
/// the first screenshot asks for.
enum ScreenCapture {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// A PNG of the app's main window, or of the main display (without this app's windows) when no app
    /// is given or it has no window on screen.
    static func screenshot(of bundleID: String?) async throws -> Data {
        guard hasPermission else {
            // Shows the system prompt the first time; after that the user has to allow it in System Settings.
            CGRequestScreenCaptureAccess()
            throw ScreenCaptureError.permission
        }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let image: CGImage
        if let bundleID, let window = mainWindow(of: bundleID, in: content) {
            image = try await capture(window)
        } else {
            image = try await captureDisplay(in: content)
        }
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ScreenCaptureError.encoding
        }
        return png
    }

    /// The app's largest normal window on screen.
    private static func mainWindow(of bundleID: String, in content: SCShareableContent) -> SCWindow? {
        content.windows
            .filter {
                $0.owningApplication?.bundleIdentifier == bundleID && $0.windowLayer == 0
                    && $0.frame.width >= 200 && $0.frame.height >= 150
            }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    private static func capture(_ window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return try await capture(filter, size: window.frame.size)
    }

    private static func captureDisplay(in content: SCShareableContent) async throws -> CGImage {
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw ScreenCaptureError.noDisplay
        }
        let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        return try await capture(filter, size: CGSize(width: display.width, height: display.height))
    }

    /// At full (Retina) resolution.
    private static func capture(_ filter: SCContentFilter, size: CGSize) async throws -> CGImage {
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
    case noDisplay
    case encoding

    var errorDescription: String? {
        switch self {
        case .permission: "Allow Screen Recording for Private Meeting Assistant in System Settings › Privacy & Security, then try again."
        case .noDisplay: "No display is available."
        case .encoding: "Couldn't save the image."
        }
    }
}

extension SystemAudioTarget {
    /// The app to screenshot, or nil for the whole screen.
    var bundleID: String? {
        if case .app(let id, _) = self { id } else { nil }
    }
}
