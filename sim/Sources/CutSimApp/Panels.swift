import SwiftUI

// Panel contents. Each of these is hosted either in the main window or in
// its own floating utility panel, so none of them assume a surrounding
// layout.

// MARK: - left column

struct SectionSidebar: View {
    @Bindable var document: CutDocument

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(document.landmarks) { lm in
                    SectionRow(
                        name: lm.name,
                        move: lm.firstMove,
                        isCurrent: document.currentSectionName == lm.name
                    ) {
                        document.seek(to: lm.firstMove)
                    }
                }
            }
        }
        .background(.ultraThinMaterial)
    }
}

/// A row that reads as a control rather than a line of prose: a rule beneath
/// it, a hover state, and the move it jumps to sitting on the right.
private struct SectionRow: View {
    let name: String
    let move: Int
    let isCurrent: Bool
    let action: () -> Void

    @State private var hovering = false

    private var background: Color {
        if isCurrent { return Color.accentColor.opacity(0.22) }
        return hovering ? Color.primary.opacity(0.07) : .clear
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Rectangle()
                        .fill(isCurrent ? Color.accentColor : .clear)
                        .frame(width: 2)
                    Text(name)
                        .font(.system(size: 11))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 6)
                    Text("\(move)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(isCurrent ? .secondary : .tertiary)
                }
                .padding(.vertical, 5)
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(background)

                Divider().opacity(0.6)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("jump to move \(move)")
    }
}


// MARK: - right column, upper

struct InspectorPanel: View {
    @Bindable var document: CutDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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

                        InspectorGroup("View") {
                            Button {
                                document.resetView()
                            } label: {
                                Label("Reset to Top", systemImage: "arrow.counterclockwise")
                                    .font(.system(size: 11))
                            }
                            .controlSize(.small)
                            Text("drag spins · ⌥drag slides · scroll zooms")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }

                        InspectorGroup("Toolpath") {
                            Toggle("Cut paths", isOn: $document.pathOptions.cuts)
                            Toggle("Plunge points", isOn: $document.pathOptions.plunges)
                            Toggle("Travel at depth", isOn: $document.pathOptions.travelAtDepth)
                            Toggle("Travel above stock", isOn: $document.pathOptions.travelAbove)
                            Divider().padding(.vertical, 2)
                            Toggle("Colour by section", isOn: $document.pathOptions.colorBySection)
                            Toggle("Follow scrub", isOn: $document.pathOptions.followScrub)
                            Text("red = travelling at cutting depth")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
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

struct InspectorGroup<Content: View>: View {
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

struct InfoRow: View {
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

struct PanelHeader: View {
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

struct TransportBar: View {
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
