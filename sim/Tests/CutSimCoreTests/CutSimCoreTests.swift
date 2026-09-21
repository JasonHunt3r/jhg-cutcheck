import XCTest
@testable import CutSimCore

final class ParserTests: XCTestCase {

    func testQuarterArcGeometry() {
        let prog = NCParser.parse(text: """
        G21 G90 G17
        G0 X10 Y0 Z1
        G1 Z-1 F500
        G3 X0 Y10 I-10 J0
        """)
        let arc = prog.moves.first { $0.isArc }!
        XCTAssertEqual(arc.radius!, 10, accuracy: 1e-9)
        XCTAssertEqual(arc.sweep, .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(arc.xyLength, 10 * .pi / 2, accuracy: 1e-9)

        // Tessellation must stay on the arc and land on the commanded end.
        let pts = arc.polyline(maxSag: 0.001)
        let worst = pts.map { abs(($0.x * $0.x + $0.y * $0.y).squareRoot() - 10) }.max()!
        XCTAssertLessThan(worst, 0.0011)
        XCTAssertEqual(pts.last!.x, arc.end.x, accuracy: 1e-12)
        XCTAssertEqual(pts.last!.y, arc.end.y, accuracy: 1e-12)
    }

    func testFullCircle() {
        let prog = NCParser.parse(text: """
        G21 G90 G17
        G0 X10 Y0 Z1
        G1 Z-1 F500
        G2 X10 Y0 I-10 J0
        """)
        let arc = prog.moves.first { $0.isArc }!
        XCTAssertEqual(arc.sweep, -2 * .pi, accuracy: 1e-9)
        XCTAssertEqual(arc.xyLength, 2 * .pi * 10, accuracy: 1e-9)
    }

    /// A check that has never fired is not a check.
    func testRadiusMismatchFires() {
        // start (10,0), centre (15,0) -> r=5 ; end (20,5) -> r=7.07
        let prog = NCParser.parse(text: """
        G21 G90 G17
        G0 X10 Y0 Z5
        G1 Z-1 F500
        G2 X20 Y5 I5 J0
        """)
        XCTAssertTrue(prog.warnings.contains { $0.code == "arc_radius_mismatch" })
    }

    func testCleanArcDoesNotWarn() {
        let prog = NCParser.parse(text: """
        G21 G90 G17
        G0 X10 Y0 Z5
        G1 Z-1 F500
        G3 X0 Y10 I-10 J0
        """)
        XCTAssertFalse(prog.warnings.contains { $0.code == "arc_radius_mismatch" })
    }

    func testModalMotionCarriesAcrossLines() {
        let prog = NCParser.parse(text: """
        G21 G90
        G1 X1 Y0 Z-1 F500
        X2
        X3
        """)
        XCTAssertEqual(prog.moves.count, 3)
        XCTAssertTrue(prog.moves.allSatisfy { $0.kind == .linear })
        XCTAssertEqual(prog.moves.last!.end.x, 3, accuracy: 1e-12)
    }

    func testCommentsAndSections() {
        let prog = NCParser.parse(text: """
        ; BIT_R:  3.175mm
        ; SECTION: ROUGH: BODY OUTLINE
        ; --- Z=-1.5 ---
        G21 G90
        G1 X1 Y0 Z-1.5 F500
        (inline comment) X2
        """)
        XCTAssertEqual(prog.bitRadius!, 3.175, accuracy: 1e-9)
        XCTAssertEqual(prog.sections.count, 1)
        XCTAssertEqual(prog.sections[0].name, "ROUGH: BODY OUTLINE")
        XCTAssertEqual(prog.sections[0].depths, [-1.5])
        XCTAssertEqual(prog.moves.count, 2)   // parenthesised text must not eat the move
    }
}

final class SimulatorTests: XCTestCase {

    /// A rapid below the surface removes material, because the machine
    /// would. This is the repositioning-at-depth defect class.
    func testRapidAtDepthCuts() {
        let prog = NCParser.parse(text: """
        G21 G90 G17
        G0 X-20 Y0 Z5
        G1 Z-3 F500
        G0 X20 Y0
        G0 Z5
        """)
        let f = HeightField(xmin: -30, xmax: 30, ymin: -10, ymax: 10,
                            top: 0, bottom: -10, resolution: 0.25)
        Simulator.run(program: prog, into: f, radius: 3.175)
        XCTAssertGreaterThan(f.removedVolume(), 500)
        XCTAssertEqual(f.lowest(), -3, accuracy: 1e-5)
    }

    func testRetractingFirstCutsFarLess() {
        let prog = NCParser.parse(text: """
        G21 G90 G17
        G0 X-20 Y0 Z5
        G1 Z-3 F500
        G0 Z5
        G0 X20 Y0
        """)
        let f = HeightField(xmin: -30, xmax: 30, ymin: -10, ymax: 10,
                            top: 0, bottom: -10, resolution: 0.25)
        Simulator.run(program: prog, into: f, radius: 3.175)
        XCTAssertLessThan(f.removedVolume(), 200)   // just the plunge hole
    }

    func testMovesAboveStockDoNotCut() {
        let prog = NCParser.parse(text: """
        G21 G90 G17
        G0 X-20 Y0 Z5
        G1 X20 Y0 F500
        """)
        let f = HeightField(xmin: -30, xmax: 30, ymin: -10, ymax: 10,
                            top: 0, bottom: -10, resolution: 0.5)
        Simulator.run(program: prog, into: f, radius: 3.175)
        XCTAssertEqual(f.removedVolume(), 0, accuracy: 1e-9)
    }

    /// A ramp must cut at the depth the tool is actually at along the move,
    /// not an average of its endpoints.
    func testRampFollowsDepth() {
        let prog = NCParser.parse(text: """
        G21 G90 G17
        G0 X-20 Y0 Z0
        G1 X20 Y0 Z-4 F500
        """)
        let f = HeightField(xmin: -30, xmax: 30, ymin: -10, ymax: 10,
                            top: 0, bottom: -10, resolution: 0.5)
        Simulator.run(program: prog, into: f, radius: 3.175)
        let iy = f.ny / 2
        let atStart = f.height(ix: Int((-18.0 - f.xmin) / f.resolution), iy: iy)
        let atEnd = f.height(ix: Int((18.0 - f.xmin) / f.resolution), iy: iy)
        XCTAssertGreaterThan(atEnd < atStart ? 1 : 0, 0, "ramp should deepen along the move")
        XCTAssertEqual(Double(atEnd), -4, accuracy: 0.3)
        XCTAssertLessThan(abs(Double(atStart)), 1.0)
    }
}
