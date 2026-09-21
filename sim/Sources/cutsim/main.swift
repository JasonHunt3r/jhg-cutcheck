import Foundation
import CutSimCore

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("cutsim: " + msg + "\n").utf8))
    exit(2)
}

let usage = """
usage: cutsim FILE.nc [options]
  --size WxDxT     stock in mm (default: path extents + 5mm margin)
  --bit DIA        cutter diameter in mm (default: from the BIT_R header)
  --resolution MM  grid cell size (default 0.5)
  --preview PATH   write a top-down depth map PNG
  --sections       list the landmarks and exit
"""

func run() {
    var args = Array(CommandLine.arguments.dropFirst())
    guard !args.isEmpty else { print(usage); exit(2) }

    func take(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag) else { return nil }
        guard i + 1 < args.count else { fail("\(flag) needs a value") }
        let v = args[i + 1]
        args.removeSubrange(i...(i + 1))
        return v
    }
    func has(_ flag: String) -> Bool {
        guard let i = args.firstIndex(of: flag) else { return false }
        args.remove(at: i)
        return true
    }

    let sizeArg = take("--size")
    let bitArg = take("--bit")
    let resArg = take("--resolution")
    let previewArg = take("--preview")
    let listSections = has("--sections")
    guard let path = args.first else { fail("no input file") }

    let prog: Program
    do { prog = try NCParser.parse(path: path) }
    catch { fail("cannot read \(path): \(error)") }
    guard !prog.moves.isEmpty else { fail("no moves parsed") }

    if listSections {
        print("sections in \(path):")
        for (i, s) in prog.sections.enumerated() {
            let depths = s.depths.isEmpty ? "" : "  depths "
                + s.depths.map { String(format: "%.1f", $0) }.joined(separator: ", ")
            print(String(format: "  %2d  line %-7d moves %6d-%-6d  %@%@",
                         i, s.lineNo, s.firstMove, s.lastMove, s.name, depths))
        }
        exit(0)
    }

    let radius: Double
    if let b = bitArg, let d = Double(b) { radius = d / 2 }
    else if let r = prog.bitRadius { radius = r }
    else { fail("no --bit given and no BIT_R in the file header") }

    let res = Double(resArg ?? "0.5") ?? 0.5

    var xmin = 0.0, xmax = 0.0, ymin = 0.0, ymax = 0.0, thickness = 0.0
    if let s = sizeArg {
        let parts = s.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 3 else { fail("--size must look like 400x430x16") }
        xmin = -parts[0] / 2; xmax = parts[0] / 2
        ymin = -parts[1] / 2; ymax = parts[1] / 2
        thickness = parts[2]
    } else {
        var loX = Double.greatestFiniteMagnitude, loY = Double.greatestFiniteMagnitude
        var hiX = -Double.greatestFiniteMagnitude, hiY = -Double.greatestFiniteMagnitude
        var zlo = 0.0
        for m in prog.moves {
            loX = min(loX, m.start.x, m.end.x); hiX = max(hiX, m.start.x, m.end.x)
            loY = min(loY, m.start.y, m.end.y); hiY = max(hiY, m.start.y, m.end.y)
            zlo = min(zlo, m.minZ)
        }
        let margin = 5.0
        xmin = loX - margin; xmax = hiX + margin
        ymin = loY - margin; ymax = hiY + margin
        thickness = prog.depthTotal ?? abs(zlo)
    }

    let field = HeightField(xmin: xmin, xmax: xmax, ymin: ymin, ymax: ymax,
                            top: 0, bottom: -thickness, resolution: res)

    print("file      \(path)")
    print("          \(prog.moves.count) moves, \(prog.sections.count) sections, units \(prog.units)")
    print(String(format: "stock     X %.1f..%.1f  Y %.1f..%.1f  top 0.0 bottom %.1f",
                 xmin, xmax, ymin, ymax, -thickness))
    print(String(format: "grid      %d x %d cells @ %.3gmm (%.2fM)",
                 field.nx, field.ny, res, Double(field.nx * field.ny) / 1e6))
    print(String(format: "cutter    flat cylinder, dia %.3gmm (r %.4gmm)", radius * 2, radius))

    let t0 = Date()
    let segs = Simulator.run(program: prog, into: field, radius: radius)
    let elapsed = Date().timeIntervalSince(t0)

    let vol = field.removedVolume()
    let total = (xmax - xmin) * (ymax - ymin) * thickness
    print(String(format: "removed   %.1f cm3 of %.1f cm3 (%.1f%%)",
                 vol / 1000, total / 1000, 100 * vol / total))
    print(String(format: "lowest    Z %.3fmm%@", field.lowest(),
                 field.lowest() <= -thickness + 1e-6 ? "  (cut through)" : ""))
    print(String(format: "sim       %d segments in %.2fs", segs, elapsed))

    if let p = previewArg {
        do {
            let (w, h, f) = try field.writePreview(to: p)
            print("preview   \(p)  (\(w)x\(h)px\(f > 1 ? ", \(f)x downsampled" : ""))")
        } catch { fail("cannot write preview: \(error)") }
    }
}

run()
