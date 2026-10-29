import AppKit
import SwiftUI

/// A finished meeting's transcript as one block of text: selection and copy work across any number
/// of lines (separate views per line can't), and long meetings stay fast. Each line is the time
/// (click it to play from there), the speaker and the text; screenshots and videos sit where they
/// were taken. The line being played is highlighted and, while it plays, kept in view.
struct TranscriptTextView: NSViewRepresentable {
    let segments: [Segment]
    var screenshots: [MeetingScreenshot] = []
    var videos: [MeetingScreenshot] = []
    let fontSize: CGFloat
    /// The line the audio is at, if it's been played.
    var playing: Int64?
    /// Scroll the playing line into view when it changes (while the audio plays).
    var follow = false
    /// A line to show and mark, from search.
    var focused: Int64?
    /// Clicking a line's time: play from that many milliseconds.
    var seek: (Int) -> Void = { _ in }

    static let seekScheme = "pma-seek"

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = true
        view.textContainerInset = NSSize(width: 0, height: 4)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        let c = context.coordinator
        c.seek = seek
        let signature = Signature(
            lines: segments.map { "\($0.id)\u{1}\($0.speaker)\u{1}\($0.text)" },
            media: (screenshots + videos).map(\.url.path), fontSize: fontSize
        )
        if signature != c.signature {
            c.signature = signature
            let (text, ranges) = build()
            view.textStorage?.setAttributedString(text)
            c.ranges = ranges
            c.marked = [:]
            view.invalidateIntrinsicContentSize()
        }
        c.mark(focused, color: NSColor.systemYellow.withAlphaComponent(0.3), key: "focused", in: view)
        c.mark(playing, color: NSColor.controlAccentColor.withAlphaComponent(0.22), key: "playing", in: view)
        if let focused, c.scrolledToFocus != focused {
            c.scrolledToFocus = focused
            DispatchQueue.main.async { c.scroll(to: focused, in: view, onlyIfHidden: false) }
        }
        if follow, let playing, c.followed != playing {
            c.followed = playing
            c.scroll(to: playing, in: view, onlyIfHidden: true)
        }
    }

    /// The height at a width SwiftUI proposes, measured on a copy of the text: SwiftUI also asks about
    /// widths it won't use, and laying out the view itself at those left its text wrapped too narrow.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite, let text = view.textStorage else { return nil }
        let c = context.coordinator
        if let cached = c.heights[width], c.measured == c.signature { return CGSize(width: width, height: cached) }
        if c.measured != c.signature { c.heights = [:] }
        c.measured = c.signature
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let height = ceil(layout.usedRect(for: container).height) + view.textContainerInset.height * 2
        c.heights[width] = height
        return CGSize(width: width, height: height)
    }

    // MARK: Building the text

    private struct Item {
        let ms: Int
        let segment: Segment?
        let media: MeetingScreenshot?
        let isVideo: Bool
    }

    /// The transcript, and each line's range in it.
    func build() -> (NSAttributedString, [Int64: NSRange]) {
        let size = fontSize
        let hasParticipants = segments.contains { $0.participant != nil }
        let timeColumn = ceil(size * 4)
        let speakerColumn = timeColumn + ceil(size * (hasParticipants ? 8 : 3.6))
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: timeColumn), NSTextTab(textAlignment: .left, location: speakerColumn)]
        paragraph.headIndent = speakerColumn
        paragraph.paragraphSpacing = size * 0.65
        paragraph.lineSpacing = size * 0.15

        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        let secondary: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size * 0.82, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
        ]

        // Lines and media in meeting order; media taken during a line come before it, as in transcript.md.
        var items = segments.map { Item(ms: $0.startMs, segment: $0, media: nil, isVideo: false) }
        items += screenshots.map { Item(ms: $0.atMs, segment: nil, media: $0, isVideo: false) }
        items += videos.map { Item(ms: $0.atMs, segment: nil, media: $0, isVideo: true) }
        items.sort { ($0.ms, $0.segment == nil ? 0 : 1) < ($1.ms, $1.segment == nil ? 0 : 1) }

        let out = NSMutableAttributedString()
        var ranges: [Int64: NSRange] = [:]
        for item in items {
            let start = out.length
            var time = secondary
            time[.link] = URL(string: "\(Self.seekScheme):\(item.ms)")
            out.append(NSAttributedString(string: TranscriptExport.timestamp(item.ms), attributes: time))
            out.append(NSAttributedString(string: "\t", attributes: body))
            if let segment = item.segment {
                var speaker = body
                speaker[.font] = NSFont.boldSystemFont(ofSize: size)
                speaker[.foregroundColor] = NSColor(SpeakerStyle.color(segment.source, participant: segment.participant))
                out.append(NSAttributedString(string: segment.speaker.isEmpty ? segment.source.speaker : segment.speaker, attributes: speaker))
                out.append(NSAttributedString(string: "\t", attributes: body))
                out.append(NSAttributedString(string: segment.text, attributes: body))
                out.append(NSAttributedString(string: "\n", attributes: body))
                ranges[segment.id] = NSRange(location: start, length: out.length - start)
            } else if let media = item.media {
                var link = body
                link[.link] = media.url
                link[.foregroundColor] = NSColor.secondaryLabelColor
                out.append(NSAttributedString(string: "\t", attributes: body))
                let still = item.isVideo
                    ? ScreenCapture.thumbnail(of: VideoThumbnail.url(for: media.url), maxPixels: 480)
                    : ScreenCapture.thumbnail(of: media.url, maxPixels: 480)
                if let image = still {
                    let width = min(CGFloat(image.width) / 2, 240)
                    let thumbnail = item.isVideo
                        ? VideoThumbnail.withPlayBadge(image, width: width)
                        : NSImage(cgImage: image, size: NSSize(width: width, height: width * CGFloat(image.height) / CGFloat(image.width)))
                    let attachment = NSTextAttachment()
                    attachment.attachmentCell = NSTextAttachmentCell(imageCell: thumbnail)
                    let picture = NSMutableAttributedString(attachment: attachment)
                    picture.addAttributes(link, range: NSRange(location: 0, length: picture.length))
                    out.append(picture)
                    out.append(NSAttributedString(string: item.isVideo ? "  Video" : "  Screenshot", attributes: link))
                } else {
                    out.append(NSAttributedString(string: item.isVideo ? "▶︎ Video" : "Screenshot", attributes: link))
                }
                out.append(NSAttributedString(string: "\n", attributes: body))
            }
        }
        return (out, ranges)
    }

    struct Signature: Equatable {
        let lines: [String]
        let media: [String]
        let fontSize: CGFloat
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var signature: Signature?
        var ranges: [Int64: NSRange] = [:]
        var seek: (Int) -> Void = { _ in }
        /// Which line each kind of mark is on.
        var marked: [String: Int64] = [:]
        var followed: Int64?
        var scrolledToFocus: Int64?
        /// Measured heights by width, for the text `measured` was built from.
        var heights: [CGFloat: CGFloat] = [:]
        var measured: Signature?

        /// Marks one line with a background (a temporary attribute: it isn't part of the text, so
        /// copying is unaffected), moving the mark from the line it was on.
        func mark(_ id: Int64?, color: NSColor, key: String, in view: NSTextView) {
            guard marked[key] != id, let layout = view.layoutManager else { return }
            if let old = marked[key], let range = ranges[old] {
                layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
                // Restore the other mark if it shares the line.
                for (other, line) in marked where other != key && line == old {
                    layout.addTemporaryAttribute(.backgroundColor, value: other == "focused" ? NSColor.systemYellow.withAlphaComponent(0.3) : NSColor.controlAccentColor.withAlphaComponent(0.22), forCharacterRange: range)
                }
            }
            marked[key] = id
            if let id, let range = ranges[id] {
                layout.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range)
            }
        }

        /// Scrolls the line into the middle of the view, or only if it's out of sight.
        func scroll(to id: Int64, in view: NSTextView, onlyIfHidden: Bool) {
            guard let range = ranges[id], let layout = view.layoutManager, let container = view.textContainer else { return }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.y += view.textContainerOrigin.y
            if onlyIfHidden, view.visibleRect.insetBy(dx: 0, dy: 40).contains(rect) { return }
            let visible = view.visibleRect.height
            rect = rect.insetBy(dx: 0, dy: -max((visible - rect.height) / 2, 0))
            view.scrollToVisible(rect)
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, url.scheme == TranscriptTextView.seekScheme, let ms = Int(url.absoluteString.split(separator: ":").last ?? "") else {
                return false // files open in their app
            }
            seek(ms)
            return true
        }
    }
}
