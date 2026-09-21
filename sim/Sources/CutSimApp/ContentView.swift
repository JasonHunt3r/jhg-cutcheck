import SwiftUI
import UniformTypeIdentifiers

/// Three columns with draggable dividers: sections on the left, the
/// viewport and transport in the middle, inspector over move list on the
/// right. AppKit's split views handle the dragging, so the placement is
/// yours rather than baked in.
struct ContentView: View {
    @Bindable var document: CutDocument

    var body: some View {
        Group {
            if document.field != nil {
                HSplitView {
                    SectionSidebar(document: document)
                        .frame(minWidth: 130, idealWidth: 185, maxWidth: 340)

                    VStack(spacing: 0) {
                        viewport
                        Divider()
                        TransportBar(document: document)
                    }
                    .frame(minWidth: 360)
                    .layoutPriority(1)

                    VSplitView {
                        InspectorPanel(document: document)
                            .frame(minHeight: 90, idealHeight: 210)
                        MoveListView(document: document)
                            .frame(minHeight: 100)
                    }
                    .frame(minWidth: 160, idealWidth: 235, maxWidth: 420)
                }
            } else {
                viewport
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .navigationTitle(document.url?.lastPathComponent ?? "cutsim")
        .task {
            if document.field == nil,
               let path = CommandLine.arguments.dropFirst().first(where: {
                   !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0)
               }) {
                document.open(url: URL(fileURLWithPath: path))
            }
        }
    }

    private var viewport: some View {
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
    }
}

// MARK: - left column

private struct SectionSidebar: View {
    @Bindable var document: CutDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader("Sections")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(document.landmarks) { lm in
                        let isCurrent = document.currentSectionName == lm.name
                        Button {
                            document.seek(to: lm.firstMove)
                        } label: {
                            HStack(spacing: 6) {
                                Rectangle()
                                    .fill(isCurrent ? Color.accentColor : .clear)
                                    .frame(width: 2)
                                Text(lm.name)
                                    .font(.system(size: 11))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 3)
                            .padding(.trailing, 6)
                            .background(isCurrent ? Color.accentColor.opacity(0.18) : .clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("move \(lm.firstMove)")
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(.ultraThinMaterial)
    }
}

// MARK: - right column, upper

private struct InspectorPanel: View {
    @Bindable var document: CutDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader("Inspector")
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Group {
                        InspectorGroup("Detail") {
                            Picker("", selection: $document.quality) {
                                ForEach(CutDocument.Quality.allCases) { q in
                                    Text("\(q.label)  \(q.detail)").tag(q)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .disabled(document.busy)

                            if document.detailCell > 0 {
                                Label(String(format: "zoom detail %.3gmm", document.detailCell),
                                      systemImage: "sparkle.magnifyingglass")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tint)
                            }
                        }

                        InspectorGroup("Display") {
                            Toggle("Wireframe", isOn: $document.wireframe)
                            Toggle("Move list", isOn: $document.showMoveList)
                        }

                        InspectorGroup("Program") {
                            InfoRow("moves", "\(document.moveCount)")
                            InfoRow("sections", "\(document.landmarks.count)")
                            InfoRow("at", document.currentSectionName)
                        }
                    }
                    .font(.system(size: 11))
                }
                .padding(8)
            }
        }
        .background(.ultraThinMaterial)
    }
}

private struct InspectorGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @State private var open = true

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 5) { content }
                .padding(.top, 4)
                .padding(.leading, 2)
        } label: {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .kerning(0.6)
        }
    }
}

private struct InfoRow: View {
    let k: String, v: String
    init(_ k: String, _ v: String) { self.k = k; self.v = v }
    var body: some View {
        HStack(spacing: 6) {
            Text(k).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(v).font(.system(size: 10, design: .monospaced)).lineLimit(1)
        }
    }
}

private struct PanelHeader: View {
    let title: String
    init(_ t: String) { title = t }
    var body: some View {
        VStack(spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            Divider()
        }
    }
}

// MARK: - transport

private struct TransportBar: View {
    @Bindable var document: CutDocument

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    document.togglePlay()
                } label: {
                    Image(systemName: document.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 14)
                }
                .keyboardShortcut(.space, modifiers: [])
                .help(document.isPlaying ? "Pause" : "Play")

                Slider(value: Binding(
                    get: { Double(document.currentMove) },
                    set: { document.seek(to: Int($0)) }
                ), in: 0...Double(max(document.moveCount - 1, 1)))

                Text("\(document.currentMove) / \(document.moveCount - 1)")
                    .font(.system(size: 10, design: .monospaced))
                    .frame(width: 104, alignment: .trailing)
            }

            HStack(spacing: 7) {
                Image(systemName: "tortoise.fill")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                // Log scale: most of the useful range is at the slow end.
                Slider(value: Binding(
                    get: { log10(document.playSpeed) },
                    set: { document.playSpeed = pow(10, $0) }
                ), in: log10(20.0)...log10(20000.0))
                .frame(width: 150)
                Image(systemName: "hare.fill")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                Text("\(Int(document.playSpeed))/s")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .leading)
                Spacer()
                Text(document.status)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
