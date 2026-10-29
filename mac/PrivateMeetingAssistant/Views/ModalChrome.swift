import AppKit
import SwiftUI

/// The round ✕ that closes a sheet or the Settings window, at the top right, as in Claude. Escape
/// does the same.
struct CloseButton: View {
    var help = "Close (Esc)"
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: ModalChrome.closeSize, height: ModalChrome.closeSize)
                .background(hovering ? Theme.raised : Theme.surface, in: .circle)
                .overlay(Circle().strokeBorder(Theme.stroke))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel("Close")
    }
}

/// How far the ✕ sits from the top and right edges of a sheet or the Settings window.
enum ModalChrome {
    static let closeInset: CGFloat = 12
    static let closeSize: CGFloat = 27.3
}

/// A sheet's top: its title (and a line under it), leaving room on the right for the ✕
/// (`modalCloseButton`).
struct ModalHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title3.weight(.semibold))
            if let subtitle {
                Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, ModalChrome.closeSize + ModalChrome.closeInset)
    }
}

extension View {
    /// The ✕ in the sheet's top right corner, the same distance from both edges.
    func modalCloseButton(help: String = "Close (Esc)", action: @escaping () -> Void) -> some View {
        overlay(alignment: .topTrailing) {
            CloseButton(help: help, action: action).padding(ModalChrome.closeInset)
        }
    }
}

/// Gives the Settings window the sheets' look: no traffic lights, the ✕ in the top right corner.
struct SettingsWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Hook() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Hook: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // The title bar's view, which spans the title and the tabs and is drawn over the rest.
            guard let window, let frame = window.standardWindowButton(.closeButton)?.superview,
                  !frame.subviews.contains(where: { $0.identifier?.rawValue == "close" })
            else { return }
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = true
            }
            let host = NSHostingView(rootView: CloseButton { [weak window] in window?.performClose(nil) })
            host.identifier = NSUserInterfaceItemIdentifier("close")
            host.translatesAutoresizingMaskIntoConstraints = false
            frame.addSubview(host)
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: frame.topAnchor, constant: ModalChrome.closeInset),
                host.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -ModalChrome.closeInset),
            ])
        }
    }
}
