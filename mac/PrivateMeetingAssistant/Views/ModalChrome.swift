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
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
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

/// A sheet's top: its title (and a line under it) on the left, the ✕ on the right.
struct ModalHeader: View {
    let title: String
    var subtitle: String?
    var closeHelp = "Close (Esc)"
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.weight(.semibold))
                if let subtitle {
                    Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            CloseButton(help: closeHelp, action: close)
        }
    }
}

/// Gives the Settings window the sheets' look: no traffic lights, the ✕ at the right of the tab bar.
struct SettingsWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Hook() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Hook: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !window.titlebarAccessoryViewControllers.contains(where: { $0.identifier?.rawValue == "close" }) else { return }
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = true
            }
            let accessory = NSTitlebarAccessoryViewController()
            accessory.identifier = NSUserInterfaceItemIdentifier("close")
            accessory.layoutAttribute = .trailing
            let host = NSHostingView(rootView: CloseButton { [weak window] in window?.performClose(nil) }.padding(.trailing, 14))
            host.frame.size = host.fittingSize
            accessory.view = host
            window.addTitlebarAccessoryViewController(accessory)
        }
    }
}
