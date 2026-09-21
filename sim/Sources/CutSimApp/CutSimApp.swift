import SwiftUI
import UniformTypeIdentifiers

@main
struct CutSimApp: App {
    @State private var document = CutDocument()

    var body: some Scene {
        WindowGroup {
            ContentView(document: document)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { openFile() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("View") {
                Toggle("Wireframe", isOn: Binding(
                    get: { document.wireframe },
                    set: { document.wireframe = $0 }))
                    .keyboardShortcut("w", modifiers: [.command, .shift])
            }
        }
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
