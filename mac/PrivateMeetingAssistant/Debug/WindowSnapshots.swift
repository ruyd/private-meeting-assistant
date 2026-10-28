#if DEBUG
import AppKit
import ScreenCaptureKit

/// Debug builds only. Launched with `-previewSnapshots <folder>`, the app saves each of its visible
/// windows as `<folder>/<window number>.png` every second and lists them in `windows.json`
/// ([{"id", "title"}]), for the Claude desktop preview (mac/scripts/preview-server.py). The app
/// captures its own windows, so the preview needs no Screen Recording permission of its own.
@MainActor
enum WindowSnapshots {
    static func startIfRequested() {
        guard let path = UserDefaults.standard.string(forKey: "previewSnapshots"), !path.isEmpty else { return }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Task { @MainActor in
            while !Task.isCancelled {
                await write(to: folder)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private static func write(to folder: URL) async {
        let windows = NSApp.windows.filter { $0.isVisible && $0.level == .normal && $0.frame.width > 100 }
        // With Screen Recording allowed, exactly what's on screen; without it, the app draws the
        // windows itself, which leaves translucent areas such as the sidebar blank. Never prompts.
        let shareable = ScreenCapture.hasPermission
            ? try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            : nil
        var listed: [[String: Any]] = []
        for window in windows {
            let scWindow = shareable?.windows.first { $0.windowID == CGWindowID(window.windowNumber) }
            let png = if let scWindow { await captured(scWindow) } else { drawn(window) }
            guard let png else { continue }
            try? png.write(to: folder.appending(path: "\(window.windowNumber).png"), options: .atomic)
            listed.append(["id": window.windowNumber, "title": window.title])
        }
        if let json = try? JSONSerialization.data(withJSONObject: listed) {
            try? json.write(to: folder.appending(path: "windows.json"), options: .atomic)
        }
    }

    private static func captured(_ window: SCWindow) async -> Data? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = max(Int(window.frame.width * scale), 1)
        config.height = max(Int(window.frame.height * scale), 1)
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    private static func drawn(_ window: NSWindow) -> Data? {
        // The frame view includes the title bar and toolbar, not just the content.
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
#endif
