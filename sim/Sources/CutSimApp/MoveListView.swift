import SwiftUI
import CutSimCore

/// A narrow column of every move, with the one currently drawn highlighted.
/// Deliberately thin and dense: this is a ribbon alongside the viewport, not
/// a second half of the window.
struct MoveListView: View {
    @Bindable var document: CutDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
        Text("MOVES")
            .font(.system(size: 9, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        Divider()
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<max(document.moveCount, 0), id: \.self) { i in
                        MoveRow(move: document.program.moves[i],
                                index: i,
                                isCurrent: i == document.currentMove)
                            .id(i)
                            .contentShape(Rectangle())
                            .onTapGesture { document.seek(to: i) }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollContentBackground(.hidden)
            .onChange(of: document.currentMove) { _, new in
                // Playback can change this 600 times a second; following
                // every change would spend the frame budget scrolling.
                guard document.shouldFollowList() else { return }
                withAnimation(.linear(duration: 0.08)) {
                    proxy.scrollTo(new, anchor: .center)
                }
            }
        }
        }
        .background(.ultraThinMaterial)
    }
}

private struct MoveRow: View {
    let move: Move
    let index: Int
    let isCurrent: Bool

    /// One character each, so the column stays narrow.
    private var glyph: String {
        switch move.kind {
        case .rapid:  return "\u{2192}"   // →
        case .linear: return "\u{2014}"   // —
        case .arcCW:  return "\u{21BB}"   // ↻
        case .arcCCW: return "\u{21BA}"   // ↺
        }
    }

    private var tint: Color {
        if move.isRapid { return move.minZ < 0 ? .orange : .secondary }
        return move.isArc ? .teal : .primary
    }

    var body: some View {
        HStack(spacing: 5) {
            Text("\(index)")
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .frame(width: 42, alignment: .trailing)
            Text(glyph)
                .foregroundStyle(tint)
                .frame(width: 10)
            Text(String(format: "%6.2f", move.end.z))
                .foregroundStyle(move.minZ < 0 ? .primary : .tertiary)
            Text(String(format: "%6.1f", move.xyLength))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .font(.system(size: 9.5, design: .monospaced))
        .padding(.horizontal, 6)
        .padding(.vertical, 0.5)
        .background(isCurrent ? Color.accentColor.opacity(0.35) : .clear)
        .overlay(alignment: .leading) {
            if isCurrent { Rectangle().fill(Color.accentColor).frame(width: 2) }
        }
        .help("move \(index) · line \(move.lineNo) · "
              + String(format: "X %.3f  Y %.3f  Z %.3f", move.end.x, move.end.y, move.end.z)
              + (move.feed.map { String(format: "  F%.0f", $0) } ?? ""))
    }
}
