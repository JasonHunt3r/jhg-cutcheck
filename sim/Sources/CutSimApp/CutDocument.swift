import Foundation
import CutSimCore
import Observation

/// One loaded NC file: its program, the stock it cuts, and the machinery
/// for showing the block at any moment in the program.
///
/// Scrubbing does not store every frame. Keyframes are kept at intervals
/// and any moment is reached by restoring the nearest earlier keyframe and
/// replaying forward, which keeps memory flat and backward jumps cheap.
@Observable
@MainActor
final class CutDocument {

    struct Landmark: Identifiable {
        let id: Int
        let name: String
        let firstMove: Int
        /// Short label for a button, e.g. "ROUGH: BODY OUTLINE" -> "Rough"
        var short: String {
            let head = name.split(separator: ":").first.map(String.init) ?? name
            return head.capitalized
        }
    }

    private(set) var url: URL?
    private(set) var program = Program()
    private(set) var field: HeightField?
    private(set) var landmarks: [Landmark] = []
    private(set) var status = "No file open"
    private(set) var busy = false
    var wireframe = false

    var moveCount: Int { program.moves.count }
    var currentMove: Int = 0

    private var keyframes: [(index: Int, heights: [Float])] = []
    /// Last move index actually cut into `field`; -1 means untouched stock.
    private var applied = -1
    private var radius: Double = 3.175

    /// Grid cell size. Every cut wall is quantised to this, so it is the
    /// single biggest lever on how smooth the result looks.
    enum Quality: Double, CaseIterable, Identifiable {
        case coarse = 0.6
        case fine = 0.3
        case finer = 0.2
        case finest = 0.12

        public var id: Double { rawValue }
        var label: String {
            switch self {
            case .coarse: return "Coarse"
            case .fine:   return "Fine"
            case .finer:  return "Finer"
            case .finest: return "Finest"
            }
        }
        var detail: String { String(format: "%.2fmm", rawValue) }
    }

    var quality: Quality = .fine {
        didSet { if quality != oldValue { reload() } }
    }
    private var resolution: Double { quality.rawValue }

    /// Keyframes are full copies of the grid, so their count has to fall as
    /// the grid gets finer or a fine setting would eat gigabytes.
    private static let keyframeBudgetBytes = 192 << 20

    // MARK: - loading

    func open(url: URL, restoringMove: Int? = nil) {
        busy = true
        defer { busy = false }
        do {
            var prog = try NCParser.parse(path: url.path)
            prog.source = url.path
            guard !prog.moves.isEmpty else { status = "No moves in \(url.lastPathComponent)"; return }

            self.url = url
            self.program = prog
            self.radius = prog.bitRadius ?? 3.175

            var loX = Double.greatestFiniteMagnitude, loY = Double.greatestFiniteMagnitude
            var hiX = -Double.greatestFiniteMagnitude, hiY = -Double.greatestFiniteMagnitude
            var zlo = 0.0
            for m in prog.moves {
                loX = min(loX, m.start.x, m.end.x); hiX = max(hiX, m.start.x, m.end.x)
                loY = min(loY, m.start.y, m.end.y); hiY = max(hiY, m.start.y, m.end.y)
                zlo = min(zlo, m.minZ)
            }
            let margin = 5.0
            let thickness = prog.depthTotal ?? abs(zlo)

            let f = HeightField(xmin: loX - margin, xmax: hiX + margin,
                                ymin: loY - margin, ymax: hiY + margin,
                                top: 0, bottom: -thickness, resolution: resolution)
            self.field = f
            self.applied = -1

            // A heading printed before the first motion line is file
            // metadata (title block, PARAMETERS, MACHINE SETUP). Anything
            // after it is somewhere you can stand, even if the heading
            // itself spans no moves.
            let firstLine = prog.moves.first?.lineNo ?? 0
            landmarks = prog.sections.enumerated().compactMap { i, s in
                guard s.lastMove > s.firstMove || s.lineNo > firstLine else { return nil }
                return Landmark(id: i, name: s.name, firstMove: s.firstMove)
            }

            buildKeyframes()
            let target = min(restoringMove ?? (prog.moves.count - 1), prog.moves.count - 1)
            currentMove = target
            seek(to: target)
            status = "\(url.lastPathComponent) — \(prog.moves.count) moves, "
                + "\(landmarks.count) sections, \(f.nx)x\(f.ny) @ \(quality.detail)"
        } catch {
            status = "Could not read \(url.lastPathComponent)"
        }
    }

    /// Re-run at the current quality, holding position in the program.
    private func reload() {
        guard let u = url else { return }
        let keepMove = currentMove
        open(url: u, restoringMove: keepMove)
    }

    private func buildKeyframes() {
        guard let f = field else { return }
        keyframes.removeAll()
        let n = program.moves.count
        guard n > 0 else { return }

        let gridBytes = f.nx * f.ny * MemoryLayout<Float>.size
        let affordable = max(2, min(24, Self.keyframeBudgetBytes / max(gridBytes, 1)))
        let stride = max(1, n / affordable)

        // Reset, then walk forward recording snapshots.
        let fresh = HeightField(xmin: f.xmin, xmax: f.xmax, ymin: f.ymin, ymax: f.ymax,
                                top: f.top, bottom: f.bottom, resolution: f.resolution)
        keyframes.append((index: -1, heights: fresh.h))
        applied = -1
        var i = 0
        while i < n {
            let upto = min(i + stride - 1, n - 1)
            Simulator.run(program: program, into: fresh, radius: radius,
                          from: i, through: upto)
            keyframes.append((index: upto, heights: fresh.h))
            i = upto + 1
        }
    }

    /// Show the block as it stands after `move` has been executed.
    func seek(to move: Int) {
        guard let f = field, !program.moves.isEmpty else { return }
        let target = max(-1, min(move, program.moves.count - 1))
        currentMove = max(0, target)

        invalidateDetail()
        if target > applied {
            // Moving forward: just keep cutting. No rewind needed.
            Simulator.run(program: program, into: f, radius: radius,
                          from: applied + 1, through: target)
        } else if target < applied {
            var base = keyframes.first!
            for k in keyframes where k.index <= target { base = k }
            f.replace(heights: base.heights)
            if base.index < target {
                Simulator.run(program: program, into: f, radius: radius,
                              from: base.index + 1, through: target)
            }
        }
        applied = target
        generation &+= 1
    }

    /// Bumped whenever the height data changes, so the view knows to re-upload.
    private(set) var generation: UInt64 = 0

    // MARK: - playback

    private(set) var isPlaying = false
    /// Moves per second.
    var playSpeed: Double = 600
    private var playTask: Task<Void, Never>?

    func togglePlay() { isPlaying ? stop() : play() }

    var showMoveList = true
    private var lastListFollow = Date.distantPast

    /// Throttle the move list's auto-scroll; playback outruns any animation.
    func shouldFollowList() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastListFollow) > 0.1 else { return false }
        lastListFollow = now
        return true
    }

    /// Step by `delta` moves, clamped. Used by the arrow keys.
    func step(_ delta: Int) {
        stop()
        seek(to: max(0, min(currentMove + delta, moveCount - 1)))
    }

    /// Jump to the start of the previous or next section.
    func stepSection(_ dir: Int) {
        stop()
        guard !landmarks.isEmpty else { return }
        let starts = landmarks.map(\.firstMove)
        if dir > 0 {
            seek(to: starts.first(where: { $0 > currentMove }) ?? (moveCount - 1))
        } else {
            seek(to: starts.last(where: { $0 < currentMove }) ?? 0)
        }
    }

    func play() {
        guard !program.moves.isEmpty else { return }
        if currentMove >= program.moves.count - 1 { seek(to: 0) }
        isPlaying = true
        playTask?.cancel()
        playTask = Task { [weak self] in
            var carry = 0.0
            let tick = 1.0 / 60.0
            while !Task.isCancelled {
                guard let self, self.isPlaying else { return }
                carry += self.playSpeed * tick
                let step = Int(carry)
                if step > 0 {
                    carry -= Double(step)
                    let next = self.currentMove + step
                    if next >= self.moveCount - 1 {
                        self.seek(to: self.moveCount - 1)
                        self.stop()
                        return
                    }
                    self.seek(to: next)
                }
                try? await Task.sleep(nanoseconds: UInt64(tick * 1_000_000_000))
            }
        }
    }

    func stop() {
        isPlaying = false
        playTask?.cancel()
        playTask = nil
    }

    // MARK: - detail on demand

    /// A small patch of stock re-simulated at far higher resolution than the
    /// whole block could afford. A uniform 0.01mm grid over a 430mm panel
    /// would be 1.7 billion cells and exceed Metal's texture limits; 0.01mm
    /// over the 30mm you are actually looking at is 9 million.
    private(set) var detailField: HeightField?
    private(set) var detailCell: Double = 0
    private var detailTask: Task<Void, Never>?

    /// Finest cell we will ever compute, in mm.
    static let finestCell = 0.01
    /// Roughly how many cells to put across the visible region.
    static let detailCellsAcross = 2600.0

    /// Bumped to ask the view to return to a top-down framing.
    private(set) var resetViewRequest = 0
    func resetView() { resetViewRequest += 1 }

    /// Called when the camera stops moving. `halfSize` is half the visible
    /// width in mm.
    func refineDetail(centerX: Double, centerY: Double, halfSize: Double) {
        guard let base = field else { return }

        let target = max(Self.finestCell,
                         (halfSize * 2) / Self.detailCellsAcross)

        // Zoomed out far enough that the base grid is already as good: drop
        // any patch and show the whole block.
        if target >= base.resolution * 0.9 || halfSize <= 0 {
            detailTask?.cancel()
            if detailField != nil {
                detailField = nil
                detailCell = 0
                generation &+= 1
            }
            return
        }

        // Skip if the live patch already covers this view at this detail.
        if let d = detailField,
           abs(d.resolution - target) / target < 0.25,
           centerX - halfSize >= d.xmin, centerX + halfSize <= d.xmax,
           centerY - halfSize >= d.ymin, centerY + halfSize <= d.ymax {
            return
        }

        let pad = halfSize * 0.25
        let xmin = max(base.xmin, centerX - halfSize - pad)
        let xmax = min(base.xmax, centerX + halfSize + pad)
        let ymin = max(base.ymin, centerY - halfSize - pad)
        let ymax = min(base.ymax, centerY + halfSize + pad)
        guard xmax > xmin, ymax > ymin else { return }

        let prog = program
        let r = radius
        let upto = currentMove
        let top = base.top, bottom = base.bottom

        detailTask?.cancel()
        detailTask = Task { [weak self] in
            // Only the height array crosses the actor boundary; the field
            // itself is a class and is rebuilt on this side.
            let heights = await Task.detached(priority: .userInitiated) { () -> [Float] in
                let f = HeightField(xmin: xmin, xmax: xmax, ymin: ymin, ymax: ymax,
                                    top: top, bottom: bottom, resolution: target)
                Simulator.run(program: prog, into: f, radius: r,
                              maxSag: min(0.01, target), from: 0, through: upto)
                return f.h
            }.value
            if Task.isCancelled { return }
            let patch = HeightField(xmin: xmin, xmax: xmax, ymin: ymin, ymax: ymax,
                                    top: top, bottom: bottom, resolution: target)
            patch.replace(heights: heights)
            guard let self, !Task.isCancelled else { return }
            self.detailField = patch
            self.detailCell = target
            self.generation &+= 1
        }
    }

    /// Detail patches are only valid for one moment in the program.
    private func invalidateDetail() {
        detailTask?.cancel()
        detailField = nil
        detailCell = 0
    }

    /// Shown under the window title.
    ///
    /// Leads with the app name on purpose, against the usual Mac rule that
    /// the menu bar identifies the app: when CutSim is in the background
    /// the menu bar belongs to something else, and a bare filename does not
    /// say whose window this is.
    ///
    /// Then the containing folder, because the archive has several NC files
    /// sharing a basename across directories, and that is the thing worth
    /// telling apart at a glance.
    var windowSubtitle: String {
        guard let url else { return Self.appName }
        let folder = url.deletingLastPathComponent().lastPathComponent
        var parts = [Self.appName]
        if !folder.isEmpty { parts.append(folder) }
        parts.append("\(moveCount) moves")
        return parts.joined(separator: " · ")
    }

    /// One place to change when the name is settled.
    static let appName = "CutSim"

    var currentSectionName: String {
        guard currentMove < program.moves.count,
              let s = program.moves[currentMove].section,
              s < program.sections.count else { return "—" }
        return program.sections[s].name
    }
}
