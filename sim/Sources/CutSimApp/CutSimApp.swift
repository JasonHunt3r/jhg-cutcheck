import SwiftUI
import UniformTypeIdentifiers

@main
struct CutSimApp: App {
    @State private var document = CutDocument()
    @State private var panels = PanelManager()

    var body: some Scene {
        WindowGroup {
            ContentView(document: document, panels: panels)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { openFile() }
                    .keyboardShortcut("o", modifiers: .command)
            }

            CommandMenu("View") {
                Button("Reset to Top") { document.resetView() }
                    .keyboardShortcut("0", modifiers: [.option, .command])
                Toggle("Wireframe", isOn: Binding(
                    get: { document.wireframe },
                    set: { document.wireframe = $0 }))
                    .keyboardShortcut("w", modifiers: [.command, .shift])

                Divider()

                Picker("Detail", selection: Binding(
                    get: { document.quality },
                    set: { document.quality = $0 })) {
                    ForEach(CutDocument.Quality.allCases) { q in
                        Text("\(q.label)  \(q.detail)").tag(q)
                    }
                }

                Divider()

                Menu("Layout") {
                    ForEach(PanelManager.Preset.allCases) { preset in
                        Button(preset.title) { panels.apply(preset) }
                    }
                }
            }

            // Panel toggles belong in the Window menu, where macOS users
            // look for them.
            CommandGroup(after: .windowArrangement) {
                Divider()
                Button(panelLabel(.inspector)) { panels.toggle(.inspector) }
                    .keyboardShortcut("i", modifiers: [.option, .command])
                Button(panelLabel(.sections)) { panels.toggle(.sections) }
                    .keyboardShortcut("1", modifiers: [.option, .command])
                Button(panelLabel(.moves)) { panels.toggle(.moves) }
                    .keyboardShortcut("2", modifiers: [.option, .command])
            }
        }
    }

    private func panelLabel(_ kind: PanelManager.Kind) -> String {
        (panels.isOpen(kind) ? "Hide " : "Show ") + kind.title
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "nc") ?? .plainText,
                                     .plainText, .data]
        if panel.runModal() == .OK, let url = panel.url {
            document.open(url: url)
        }
    }
}
