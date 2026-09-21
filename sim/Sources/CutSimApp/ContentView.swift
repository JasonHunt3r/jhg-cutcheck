import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var document: CutDocument

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

            if document.field != nil {
                Divider()
                timeline
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.bar)
            }
        }
        .frame(minWidth: 820, minHeight: 620)
        .navigationTitle(document.url?.lastPathComponent ?? "cutsim")
        .task {
            // Allow `open -a CutSim.app file.nc --args file.nc` and plain
            // `CutSim file.nc` during development.
            if document.field == nil,
               let path = CommandLine.arguments.dropFirst().first(where: {
                   !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0)
               }) {
                document.open(url: URL(fileURLWithPath: path))
            }
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(document.landmarks) { lm in
                        Button(lm.name) { document.seek(to: lm.firstMove) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Jump to move \(lm.firstMove)")
                    }
                }
            }

            HStack(spacing: 12) {
                Slider(
                    value: Binding(
                        get: { Double(document.currentMove) },
                        set: { document.seek(to: Int($0)) }
                    ),
                    in: 0...Double(max(document.moveCount - 1, 1))
                )
                Text("\(document.currentMove) / \(document.moveCount - 1)")
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 110, alignment: .trailing)
            }

            HStack {
                Text(document.currentSectionName)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(document.status)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
