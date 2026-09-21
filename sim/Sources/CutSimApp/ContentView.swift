import SwiftUI
import UniformTypeIdentifiers

/// The main window: the part, and the transport under it. Everything else
/// lives in its own panel.
struct ContentView: View {
    @Bindable var document: CutDocument
    var panels: PanelManager

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(red: 0.09, green: 0.09, blue: 0.11)
                if document.field != nil {
                    CutView(document: document)
                } else {
                    VStack(spacing: 10) {
                        Text("Open an NC file").font(.title2)
                        Text("File ▸ Open…  (⌘O)").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if document.field != nil {
                Divider()
                TransportBar(document: document)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        // Mac convention: the title is the document, not the app. The app
        // name is already in the menu bar. navigationDocument adds the
        // proxy icon, so Cmd-clicking the title shows the full path --
        // which matters here, because several NC files in this archive
        // share a basename across directories.
        .navigationTitle(document.url?.lastPathComponent ?? "CutSim")
        .navigationSubtitle(document.windowSubtitle)
        .modifier(DocumentProxy(url: document.url))
        .task {
            if document.field == nil,
               let path = CommandLine.arguments.dropFirst().first(where: {
                   !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0)
               }) {
                document.open(url: URL(fileURLWithPath: path))
            }
            panels.attach(document)
        }
    }
}


/// Attaches the file to the window so the title bar gets a proxy icon and
/// a path menu. Only applied once a file is open.
private struct DocumentProxy: ViewModifier {
    let url: URL?
    func body(content: Content) -> some View {
        if let url {
            content.navigationDocument(url)
        } else {
            content
        }
    }
}
