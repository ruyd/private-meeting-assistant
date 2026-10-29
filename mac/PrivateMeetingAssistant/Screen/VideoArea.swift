import AVFoundation
import CoreGraphics

/// Finds the part of a recorded window where the video is (a YouTube player, a Meet call's tiles),
/// for "Record video (cut size)": ScreenCaptureKit only sees the window's pixels, so this looks
/// for where they keep changing. The browser's tabs and toolbar and the rest of the page stay still
/// and are left out.
///
/// Samples a small frame every half second and marks the cells of a grid that change at all in a
/// tenth of them. Big changes alone find only the people: a newsroom backdrop or a still part of a
/// call barely moves. But a playing video's pixels always shift a little (compression, lighting),
/// while a page's are redrawn identical, so the faintest change marks the video. The area is the
/// box around every sizeable block of such cells (a call's tiles can be apart); small ones, like the
/// cursor or a hovered thumbnail, are left out. Nil when nothing clearly stands out (a still screen,
/// or change everywhere), and the whole window is kept.
///
/// Measured on three YouTube recordings in Edge (2406×2166): each came out as the player, without
/// the tabs, toolbar, title, description and comments.
enum VideoArea {
    /// Sampled frames are this wide (and as tall as the window's shape makes them).
    private static let sampleWidth = 240
    private static let cell = 4
    private static let interval = 0.5
    private static let maxSamples = 240
    /// A pixel changes when its brightness moves by more than this (of 255) between samples…
    private static let pixelChange = 1
    /// …a cell is active when it changed between at least this share of sample pairs…
    private static let activeShare = 0.1
    /// …and blocks of active cells smaller than this share of the window are left out.
    private static let minBlock = 0.02
    /// …and the area is used only if it's at least this much of the window and leaves out at
    /// least this much.
    private static let minShare = 0.04
    private static let maxShare = 0.9

    /// What cut size keeps: the full width, and from the top of the moving area (but never more
    /// than `topLimit` off the top: about an inch, the browser's tabs and toolbar) down to its bottom.
    /// With nothing moving (a covered window that stopped drawing), only the top `topLimit` goes.
    /// Fractions of the frame, origin at the top left.
    static func verticalCut(detected: CGRect?, topLimit: Double) -> CGRect {
        let top = min(detected.map { Double($0.minY) } ?? topLimit, topLimit)
        let bottom = max(detected.map { Double($0.maxY) } ?? 1, top + 0.1)
        return CGRect(x: 0, y: top, width: 1, height: min(bottom, 1) - top)
    }

    /// The video's rectangle in the frame, as fractions of its width and height, with the origin at
    /// the top left.
    static func detect(in video: URL) async -> CGRect? {
        let asset = AVURLAsset(url: video)
        guard let duration = try? await asset.load(.duration).seconds, duration > 1 else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: sampleWidth, height: sampleWidth * 4)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: interval / 2, preferredTimescale: 600)

        let count = min(Int(duration / interval), maxSamples)
        var previous: [UInt8]?
        var width = 0, height = 0
        var changes: [Int] = []
        var pairs = 0
        for i in 0..<count {
            let at = CMTime(seconds: duration * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
            guard let image = try? await generator.image(at: at).image, let gray = grayscale(image) else { continue }
            if width == 0 {
                width = image.width
                height = image.height
                changes = [Int](repeating: 0, count: (width / cell) * (height / cell))
            }
            guard image.width == width, image.height == height else { continue }
            if let previous { tally(&changes, between: previous, and: gray, width: width, height: height) }
            previous = gray
            pairs += 1
        }
        guard pairs > 3 else { return nil }
        if ProcessInfo.processInfo.environment["VIDEO_AREA_TRACE"] != nil {
            let columns = width / cell
            for y in 0..<(height / cell) {
                print("area: " + (0..<columns).map { x in let c = changes[y * columns + x]; return c == 0 ? "." : Double(c) >= activeShare * Double(pairs - 1) ? "#" : "+" }.joined())
            }
        }
        return area(changes: changes, columns: width / cell, rows: height / cell, pairs: pairs - 1)
    }

    /// The area from per-cell change counts (exposed for tests).
    static func area(changes: [Int], columns: Int, rows: Int, pairs: Int) -> CGRect? {
        guard columns > 0, rows > 0 else { return nil }
        let active = changes.map { Double($0) >= activeShare * Double(pairs) }
        // Close small holes (a still part of the picture) before looking for the block.
        let filled = (0..<(columns * rows)).map { i -> Bool in
            if active[i] { return true }
            let x = i % columns, y = i / columns
            var around = 0
            for dy in -2...2 {
                for dx in -2...2 where (0..<columns).contains(x + dx) && (0..<rows).contains(y + dy) && active[(y + dy) * columns + x + dx] {
                    around += 1
                }
            }
            return around >= 13
        }
        // The box around every sizeable 4-connected block of active cells.
        var seen = [Bool](repeating: false, count: filled.count)
        var best: (count: Int, minX: Int, minY: Int, maxX: Int, maxY: Int) = (0, columns, rows, -1, -1)
        for start in filled.indices where filled[start] && !seen[start] {
            var stack = [start]
            seen[start] = true
            var block = (count: 0, minX: columns, minY: rows, maxX: 0, maxY: 0)
            while let i = stack.popLast() {
                let x = i % columns, y = i / columns
                block.count += 1
                block.minX = min(block.minX, x); block.maxX = max(block.maxX, x)
                block.minY = min(block.minY, y); block.maxY = max(block.maxY, y)
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                where (0..<columns).contains(nx) && (0..<rows).contains(ny) && filled[ny * columns + nx] && !seen[ny * columns + nx] {
                    seen[ny * columns + nx] = true
                    stack.append(ny * columns + nx)
                }
            }
            if Double(block.count) >= minBlock * Double(columns * rows) {
                best = (best.count + block.count, min(best.minX, block.minX), min(best.minY, block.minY), max(best.maxX, block.maxX), max(best.maxY, block.maxY))
            }
        }
        guard best.count > 0 else { return nil }
        let rect = CGRect(
            x: Double(best.minX) / Double(columns), y: Double(best.minY) / Double(rows),
            width: Double(best.maxX - best.minX + 1) / Double(columns), height: Double(best.maxY - best.minY + 1) / Double(rows)
        )
        let share = rect.width * rect.height
        return share >= minShare && share <= maxShare ? rect : nil
    }

    private static func tally(_ changes: inout [Int], between a: [UInt8], and b: [UInt8], width: Int, height: Int) {
        let columns = width / cell
        for cy in 0..<(height / cell) {
            for cx in 0..<columns {
                var changed = 0
                for y in (cy * cell)..<(cy * cell + cell) {
                    for x in (cx * cell)..<(cx * cell + cell) where abs(Int(a[y * width + x]) - Int(b[y * width + x])) > pixelChange {
                        changed += 1
                    }
                }
                if changed * 4 >= cell * cell { changes[cy * columns + cx] += 1 }
            }
        }
    }

    private static func grayscale(_ image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? pixels : nil
    }
}
