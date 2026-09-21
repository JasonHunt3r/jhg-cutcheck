import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var document: CutDocument

    var body: some View {
        HStack(spacing: 0) {
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
        if document.field != nil && document.showMoveList {
            Divider()
            MoveListView(document: document)
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
                Button {
                    document.togglePlay()
                } label: {
                    Image(systemName: document.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 16)
                }
                .keyboardShortcut(.space, modifiers: [])
                .help(document.isPlaying ? "Pause" : "Play")

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

            HStack(spacing: 8) {
                Image(systemName: "tortoise.fill")
                    .font(.caption2).foregroundStyle(.secondary)
                // Log scale: most of the useful range is at the slow end.
                Slider(value: Binding(
                    get: { log10(document.playSpeed) },
                    set: { document.playSpeed = pow(10, $0) }
                ), in: log10(20.0)...log10(20000.0))
                .frame(width: 180)
                Image(systemName: "hare.fill")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("\(Int(document.playSpeed)) moves/s")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)
                Spacer()
            }

            HStack(spacing: 12) {
                Text(document.currentSectionName)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Detail", selection: $document.quality) {
                    ForEach(CutDocument.Quality.allCases) { q in
                        Text("\(q.label)  \(q.detail)").tag(q)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 150)
                .disabled(document.busy)
                if document.detailCell > 0 {
                    Text(String(format: "detail %.3gmm", document.detailCell))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tint)
                }
                Text(document.status)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
