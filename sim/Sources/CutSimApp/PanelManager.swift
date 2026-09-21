import AppKit
import SwiftUI
import Observation

/// Owns the floating panels: creating them, remembering which were open, and
/// arranging them into presets.
///
/// Frames persist through `setFrameAutosaveName`, which macOS handles on its
/// own, so only the open/closed state needs storing.
@Observable
@MainActor
final class PanelManager {

    enum Kind: String, CaseIterable, Identifiable {
        case sections, inspector, moves

        var id: String { rawValue }
        var title: String {
            switch self {
            case .sections:  return "Sections"
            case .inspector: return "Inspector"
            case .moves:     return "Moves"
            }
        }
        var defaultSize: NSSize {
            switch self {
            case .sections:  return NSSize(width: 210, height: 420)
            case .inspector: return NSSize(width: 250, height: 330)
            case .moves:     return NSSize(width: 230, height: 520)
            }
        }
    }

    enum Preset: String, CaseIterable, Identifiable {
        case inspect, review, present
        var id: String { rawValue }
        var title: String {
            switch self {
            case .inspect: return "Inspect"
            case .review:  return "Review"
            case .present: return "Present"
            }
        }
    }

    private var windows: [Kind: PanelWindow] = [:]
    private weak var document: CutDocument?
    private let openKey = "openPanels"

    func attach(_ doc: CutDocument) {
        guard document == nil else { return }
        document = doc
        let saved = UserDefaults.standard.stringArray(forKey: openKey)
            ?? [Kind.inspector.rawValue, Kind.moves.rawValue]
        for raw in saved {
            if let k = Kind(rawValue: raw) { show(k) }
        }
    }

    func isOpen(_ kind: Kind) -> Bool { windows[kind]?.isVisible ?? false }

    func toggle(_ kind: Kind) { isOpen(kind) ? hide(kind) : show(kind) }

    func show(_ kind: Kind) {
        guard let document else { return }
        if let w = windows[kind] {
            w.makeKeyAndOrderFront(nil)
            rememberOpen()
            return
        }

        let panel = PanelWindow(
            contentRect: NSRect(origin: .zero, size: kind.defaultSize),
            // .utilityWindow is the thin title bar; it is a real system
            // style rather than custom chrome.
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false)
        panel.title = kind.title
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.titlebarAppearsTransparent = false
        panel.animationBehavior = .utilityWindow
        panel.contentView = NSHostingView(rootView: content(for: kind, document: document))
        panel.neighbours = { [weak self] in self?.otherFrames(excluding: kind) ?? [] }

        // macOS persists the frame itself under this name.
        panel.setFrameAutosaveName("panel.\(kind.rawValue)")
        if panel.frame.origin == .zero { placeDefault(panel, kind) }

        windows[kind] = panel
        panel.makeKeyAndOrderFront(nil)
        rememberOpen()
    }

    func hide(_ kind: Kind) {
        windows[kind]?.orderOut(nil)
        rememberOpen()
    }

    @ViewBuilder
    private func content(for kind: Kind, document: CutDocument) -> some View {
        switch kind {
        case .sections:  SectionSidebar(document: document)
        case .inspector: InspectorPanel(document: document)
        case .moves:     MoveListView(document: document)
        }
    }

    private func otherFrames(excluding kind: Kind) -> [NSRect] {
        var out = windows.filter { $0.key != kind && $0.value.isVisible }
            .map(\.value.frame)
        if let main = NSApp.windows.first(where: { !($0 is PanelWindow) && $0.isVisible }) {
            out.append(main.frame)
        }
        return out
    }

    private func rememberOpen() {
        let open = Kind.allCases.filter { isOpen($0) }.map(\.rawValue)
        UserDefaults.standard.set(open, forKey: openKey)
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first { !($0 is PanelWindow) && $0.isVisible }
    }

    private func placeDefault(_ panel: PanelWindow, _ kind: Kind) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let vis = screen.visibleFrame
        let size = kind.defaultSize
        let right = (mainWindow?.frame.maxX ?? vis.minX + vis.width * 0.7) + 8
        switch kind {
        case .sections:
            panel.setFrame(NSRect(x: vis.minX + 12, y: vis.maxY - size.height - 12,
                                  width: size.width, height: size.height), display: false)
        case .inspector:
            panel.setFrame(NSRect(x: min(right, vis.maxX - size.width - 12),
                                  y: vis.maxY - size.height - 12,
                                  width: size.width, height: size.height), display: false)
        case .moves:
            panel.setFrame(NSRect(x: min(right, vis.maxX - size.width - 12),
                                  y: vis.maxY - size.height - 360,
                                  width: size.width, height: size.height), display: false)
        }
    }

    // MARK: - presets

    func apply(_ preset: Preset) {
        guard let screen = NSScreen.main else { return }
        let vis = screen.visibleFrame

        switch preset {
        case .present:
            Kind.allCases.forEach { hide($0) }
            mainWindow?.setFrame(vis.insetBy(dx: 40, dy: 40), display: true, animate: true)

        case .inspect:
            // Viewport wide; a narrow right-hand stack of Inspector over Moves.
            let colW: CGFloat = 250
            let colX = vis.maxX - colW - 12
            show(.inspector); show(.moves); hide(.sections)
            let inspectorH: CGFloat = 300
            windows[.inspector]?.setFrame(
                NSRect(x: colX, y: vis.maxY - inspectorH - 12,
                       width: colW, height: inspectorH), display: true, animate: true)
            windows[.moves]?.setFrame(
                NSRect(x: colX, y: vis.minY + 12,
                       width: colW, height: vis.height - inspectorH - 36),
                display: true, animate: true)
            mainWindow?.setFrame(
                NSRect(x: vis.minX + 12, y: vis.minY + 12,
                       width: colX - vis.minX - 24, height: vis.height - 24),
                display: true, animate: true)

        case .review:
            // Moves wide enough to read the program alongside the part.
            let colW: CGFloat = 380
            let colX = vis.maxX - colW - 12
            show(.moves); show(.sections); hide(.inspector)
            windows[.moves]?.setFrame(
                NSRect(x: colX, y: vis.minY + 12, width: colW, height: vis.height - 24),
                display: true, animate: true)
            let secW: CGFloat = 210
            windows[.sections]?.setFrame(
                NSRect(x: vis.minX + 12, y: vis.minY + 12,
                       width: secW, height: vis.height - 24),
                display: true, animate: true)
            mainWindow?.setFrame(
                NSRect(x: vis.minX + secW + 24, y: vis.minY + 12,
                       width: colX - vis.minX - secW - 36, height: vis.height - 24),
                display: true, animate: true)
        }
        rememberOpen()
    }
}
