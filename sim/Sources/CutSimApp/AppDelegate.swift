import AppKit

/// Keeps the document window with its panels when the app is activated.
///
/// The panels sit at `.floating` level, so they rise above every other app
/// automatically. The main window does not: it is an ordinary window, and
/// activating via Cmd-Tab left it wherever it sat in the global order —
/// behind whatever had been in front. So the panels arrived and the part
/// did not.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidBecomeActive(_ notification: Notification) {
        raiseDocumentWindows()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        raiseDocumentWindows()
        return true
    }

    /// Ordering front, not making key: panels keep focus if one had it, and
    /// they stay on top regardless because of their window level.
    private func raiseDocumentWindows() {
        for window in NSApp.windows
        where !(window is PanelWindow) && window.isVisible && !window.isMiniaturized {
            window.orderFront(nil)
        }
    }
}
