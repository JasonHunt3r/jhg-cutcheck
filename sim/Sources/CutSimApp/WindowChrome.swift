import SwiftUI
import AppKit

/// Sets the hosting window's title bar directly.
///
/// SwiftUI's navigationTitle and navigationDocument fight over the title
/// when both are used — navigationDocument wants the title to be the file
/// name. Reaching the NSWindow is deterministic: the proxy icon still comes
/// from representedURL, while the title text stays whatever we set.
struct WindowChrome: NSViewRepresentable {
    var title: String
    var subtitle: String = ""
    var url: URL? = nil
    /// Guard so a view that could be hosted anywhere does not retitle the
    /// document window by accident.
    var panelsOnly: Bool = false

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        let title = title, subtitle = subtitle, url = url, panelsOnly = panelsOnly
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if panelsOnly && !(window is PanelWindow) { return }
            if window.title != title { window.title = title }
            if window.subtitle != subtitle { window.subtitle = subtitle }
            if !panelsOnly, window.representedURL != url { window.representedURL = url }
        }
    }
}

extension View {
    /// Attach to a view to title the window that hosts it.
    func windowChrome(title: String, subtitle: String = "",
                      url: URL? = nil, panelsOnly: Bool = false) -> some View {
        background(
            WindowChrome(title: title, subtitle: subtitle,
                         url: url, panelsOnly: panelsOnly)
                .frame(width: 0, height: 0)
        )
    }
}
