import AppKit
import SwiftUI

/// The app's own surface colours: near-black in dark mode, as in the design, and the system's
/// usual light greys in light mode.
enum Theme {
    /// Behind the right half of the window.
    static let canvas = adaptive(dark: 0x121317, light: .windowBackgroundColor)
    /// Behind the meeting list.
    static let sidebar = adaptive(dark: 0x16171C, light: .underPageBackgroundColor)
    /// Cards, fields and tiles.
    static let surface = adaptive(dark: 0x1C1E24, light: NSColor.black.withAlphaComponent(0.04))
    /// A step up from `surface`: tile previews, chips that are on.
    static let raised = adaptive(dark: 0x23262D, light: NSColor.black.withAlphaComponent(0.07))
    /// Hairline borders around cards and fields.
    static let stroke = adaptive(dark: 0x2C2F37, light: NSColor.black.withAlphaComponent(0.1))

    private static func adaptive(dark hex: UInt32, light: NSColor) -> Color {
        let dark = NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1
        )
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}
