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
        .navigationTitle(document.url?.lastPathComponent ?? "cutsim")
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
