import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// A still of each video for the transcript, kept beside it as a hidden JPEG
/// (video/.00.13.21.jpg for video/00.13.21.mp4), taken a second in: the very first frame is often
/// black or half-drawn.
enum VideoThumbnail {
    private static let maxPixels = 640

    static func url(for video: URL) -> URL {
        video.deletingLastPathComponent().appending(path: "." + video.deletingPathExtension().lastPathComponent + ".jpg")
    }

    /// The thumbnail, made first if it's missing or older than the video (one with the mic mixed in
    /// is rewritten). Nil if the video has no picture yet.
    @discardableResult
    static func ensure(for video: URL) async -> URL? {
        let thumbnail = url(for: video)
        let modified = { (url: URL) in (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
        if let made = modified(thumbnail), let changed = modified(video), made >= changed { return thumbnail }
        guard let image = await still(of: video),
              let destination = CGImageDestinationCreateWithURL(thumbnail as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? thumbnail : nil
    }

    private static func still(of video: URL) async -> CGImage? {
        let asset = AVURLAsset(url: video)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let at = CMTime(seconds: min(1, duration / 2), preferredTimescale: 600)
        return try? await generator.image(at: at).image
    }

    /// The still with a play button in the middle, for the transcript.
    static func withPlayBadge(_ still: CGImage, width: CGFloat) -> NSImage {
        let size = NSSize(width: width, height: width * CGFloat(still.height) / CGFloat(still.width))
        return NSImage(size: size, flipped: false) { rect in
            NSImage(cgImage: still, size: size).draw(in: rect)
            let side = min(rect.width, rect.height) * 0.32
            let badge = NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
            NSColor.black.withAlphaComponent(0.45).setFill()
            NSBezierPath(ovalIn: badge).fill()
            let triangle = NSBezierPath()
            triangle.move(to: NSPoint(x: badge.minX + side * 0.38, y: badge.minY + side * 0.27))
            triangle.line(to: NSPoint(x: badge.minX + side * 0.38, y: badge.maxY - side * 0.27))
            triangle.line(to: NSPoint(x: badge.maxX - side * 0.26, y: badge.midY))
            triangle.close()
            NSColor.white.setFill()
            triangle.fill()
            return true
        }
    }
}
