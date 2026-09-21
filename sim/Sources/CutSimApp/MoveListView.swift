import SwiftUI
import CutSimCore

/// Every move in the program, with the one currently on screen highlighted.
/// Clicking a row cuts the block up to that move.
struct MoveListView: View {
    @Bindable var document: CutDocument

    var body: some View {
        ScrollViewReader { proxy in
            List(0..<max(document.moveCount, 0), id: \.self) { i in
                MoveRow(move: document.program.moves[i],
                        index: i,
                        isCurrent: i == document.currentMove)
                    .id(i)
                    .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                    .contentShape(Rectangle())
                    .onTapGesture { document.seek(to: i) }
            }
            .listStyle(.plain)
            .font(.system(size: 10, design: .monospaced))
            .onChange(of: document.currentMove) { _, new in
                // Playback can change this 600 times a second; following it
                // every time would spend the whole frame budget scrolling.
                guard document.shouldFollowList() else { return }
                withAnimation(.linear(duration: 0.08)) {
                    proxy.scrollTo(new, anchor: .center)
                }
            }
        }
        .frame(minWidth: 280, idealWidth: 320)
    }
}

private struct MoveRow: View {
    let move: Move
    let index: Int
    let isCurrent: Bool

    private var glyph: String {
        switch move.kind {
        case .rapid:  return "rapid"
        case .linear: return "line "
        case .arcCW:  return "arc cw"
        case .arcCCW: return "arc ccw"
        }
    }

    private var tint: Color {
        if move.isRapid { return move.minZ < 0 ? .orange : .secondary }
        return move.isArc ? .teal : .primary
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("\(index)")
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
            Text("L\(move.lineNo)")
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .trailing)
            Text(glyph)
                .foregroundStyle(tint)
                .frame(width: 50, alignment: .leading)
            Text(String(format: "%8.2f %8.2f %7.2f", move.end.x, move.end.y, move.end.z))
                .foregroundStyle(move.minZ < 0 ? .primary : .secondary)
            Spacer(minLength: 0)
            Text(String(format: "%.1f", move.xyLength))
                .foregroundStyle(.tertiary)
                .frame(width: 46, alignment: .trailing)
        }
        .padding(.vertical, 1)
        .background(isCurrent ? Color.accentColor.opacity(0.30) : .clear)
        .overlay(alignment: .leading) {
            if isCurrent {
                Rectangle().fill(Color.accentColor).frame(width: 2)
            }
        }
    }
}
