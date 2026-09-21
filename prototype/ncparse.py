"""Parse a GRBL-dialect NC file into an ordered tool path.

Reads only the shipped NC file. Emits moves in emission order with modal
state resolved, so downstream code can ask "what did the tool do, and in
what sequence" without re-reading G-code.

Scope: 3-axis, G17 XY plane, the subset of GRBL the JHG pipeline emits.
Anything outside that is reported as a warning rather than guessed at.
"""

from __future__ import annotations

import math
import re
import sys
from dataclasses import dataclass, field
from typing import Iterator, Optional

# One G/M word, or one axis/parameter word, e.g. "G1", "X-12.5", "I.003"
WORD = re.compile(r"([A-Za-z])\s*(-?\d*\.?\d+)")

MOTION_CODES = {0: "rapid", 1: "linear", 2: "arc_cw", 3: "arc_ccw"}

# Arc endpoint radii must agree to this, in mm, or the arc is malformed.
# GRBL's own tolerance is looser; we are stricter because a mismatch here
# is a known defect class in this pipeline, not a rounding artifact.
ARC_RADIUS_TOL = 0.002


@dataclass
class Move:
    """One commanded motion, with absolute start and end in mm."""

    line_no: int
    kind: str  # rapid | linear | arc_cw | arc_ccw
    start: tuple[float, float, float]
    end: tuple[float, float, float]
    center: Optional[tuple[float, float]] = None  # XY, arcs only
    feed: Optional[float] = None
    spindle: Optional[float] = None

    @property
    def is_rapid(self) -> bool:
        return self.kind == "rapid"

    @property
    def is_arc(self) -> bool:
        return self.kind in ("arc_cw", "arc_ccw")

    @property
    def dz(self) -> float:
        return self.end[2] - self.start[2]

    @property
    def min_z(self) -> float:
        return min(self.start[2], self.end[2])

    @property
    def radius(self) -> Optional[float]:
        if self.center is None:
            return None
        return math.hypot(self.start[0] - self.center[0], self.start[1] - self.center[1])

    @property
    def sweep(self) -> float:
        """Signed swept angle in radians. 0 for non-arcs."""
        if self.center is None:
            return 0.0
        cx, cy = self.center
        a0 = math.atan2(self.start[1] - cy, self.start[0] - cx)
        a1 = math.atan2(self.end[1] - cy, self.end[0] - cx)
        d = a1 - a0
        if self.kind == "arc_cw":
            while d >= 0:
                d -= 2 * math.pi
            while d < -2 * math.pi:
                d += 2 * math.pi
            # Coincident endpoints with a center given means a full circle.
            if abs(d) < 1e-9:
                d = -2 * math.pi
        else:
            while d <= 0:
                d += 2 * math.pi
            while d > 2 * math.pi:
                d -= 2 * math.pi
            if abs(d) < 1e-9:
                d = 2 * math.pi
        return d

    @property
    def xy_length(self) -> float:
        """Path length in XY, following the arc rather than the chord."""
        if self.is_arc:
            r = self.radius or 0.0
            return abs(self.sweep) * r
        return math.hypot(self.end[0] - self.start[0], self.end[1] - self.start[1])

    @property
    def length(self) -> float:
        """Full 3D path length, treating arc Z as a helix."""
        return math.hypot(self.xy_length, self.dz)

    def polyline(self, max_sag: float = 0.005) -> list[tuple[float, float, float]]:
        """Absolute points approximating this move, start and end included.

        Arcs are subdivided so the chord never departs from the true arc by
        more than max_sag. Linear moves return their two endpoints.
        """
        if not self.is_arc:
            return [self.start, self.end]

        r = self.radius or 0.0
        sweep = self.sweep
        if r <= 0:
            return [self.start, self.end]

        # Max angle per chord for a given sagitta.
        if max_sag >= r:
            step = abs(sweep)
        else:
            step = 2 * math.acos(1 - max_sag / r)
        n = max(2, int(math.ceil(abs(sweep) / max(step, 1e-9))))

        cx, cy = self.center  # type: ignore[misc]
        a0 = math.atan2(self.start[1] - cy, self.start[0] - cx)
        z0, z1 = self.start[2], self.end[2]

        pts = []
        for i in range(n + 1):
            t = i / n
            a = a0 + sweep * t
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a), z0 + (z1 - z0) * t))
        # Land exactly on the commanded endpoint rather than a rounded one.
        pts[-1] = self.end
        return pts


@dataclass
class Warning_:
    line_no: int
    code: str
    detail: str


@dataclass
class Program:
    moves: list[Move] = field(default_factory=list)
    warnings: list[Warning_] = field(default_factory=list)
    units: str = "mm"
    source: str = ""

    def cutting(self) -> Iterator[Move]:
        return (m for m in self.moves if not m.is_rapid)


def parse(path: str) -> Program:
    prog = Program(source=path)
    x = y = z = 0.0
    feed: Optional[float] = None
    spindle: Optional[float] = None
    motion: Optional[str] = None
    absolute = True
    unit_scale = 1.0
    plane = "XY"
    seen_unknown: set[str] = set()

    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line_no, raw in enumerate(fh, 1):
            # Strip comments: ";" to end of line, and "(...)" spans.
            line = re.sub(r"\([^)]*\)", " ", raw.split(";")[0])
            if not line.strip():
                continue

            words = WORD.findall(line)
            if not words:
                continue

            axis: dict[str, float] = {}
            motion_this_line: Optional[str] = None

            for letter, num in words:
                L = letter.upper()
                v = float(num)
                if L == "G":
                    g = int(round(v))
                    if g in MOTION_CODES:
                        motion_this_line = MOTION_CODES[g]
                    elif g == 20:
                        unit_scale, prog.units = 25.4, "in"
                        prog.warnings.append(
                            Warning_(line_no, "units_inch", "G20: file is in inches")
                        )
                    elif g == 21:
                        unit_scale, prog.units = 1.0, "mm"
                    elif g == 90:
                        absolute = True
                    elif g == 91:
                        absolute = False
                        prog.warnings.append(
                            Warning_(line_no, "incremental", "G91 incremental mode")
                        )
                    elif g in (17, 18, 19):
                        plane = {17: "XY", 18: "ZX", 19: "YZ"}[g]
                        if plane != "XY":
                            prog.warnings.append(
                                Warning_(line_no, "plane", f"G{g}: {plane} plane arcs")
                            )
                    elif g in (4, 53, 54, 28, 30, 80, 90, 91, 92, 93, 94):
                        pass  # benign or irrelevant to geometry
                    else:
                        key = f"G{g}"
                        if key not in seen_unknown:
                            seen_unknown.add(key)
                            prog.warnings.append(
                                Warning_(line_no, "unknown_code", f"unhandled {key}")
                            )
                elif L == "M":
                    pass  # spindle/coolant/program control: no geometry
                elif L == "F":
                    feed = v * unit_scale
                elif L == "S":
                    spindle = v
                elif L in ("X", "Y", "Z", "I", "J", "K", "R"):
                    axis[L] = v * unit_scale

            if motion_this_line:
                motion = motion_this_line

            if not any(k in axis for k in ("X", "Y", "Z")):
                continue  # a setting-only line, e.g. "F1200" or "M3 S18000"
            if motion is None:
                prog.warnings.append(
                    Warning_(line_no, "no_motion_mode", "coordinates before any G0-G3")
                )
                continue

            sx, sy, sz = x, y, z
            if absolute:
                x = axis.get("X", x)
                y = axis.get("Y", y)
                z = axis.get("Z", z)
            else:
                x += axis.get("X", 0.0)
                y += axis.get("Y", 0.0)
                z += axis.get("Z", 0.0)

            center = None
            if motion in ("arc_cw", "arc_ccw"):
                center = _arc_center(
                    prog, line_no, (sx, sy), (x, y), axis, motion
                )
                if center is None:
                    motion_kind = "linear"  # degenerate: treat as a straight move
                else:
                    motion_kind = motion
            else:
                motion_kind = motion

            prog.moves.append(
                Move(
                    line_no=line_no,
                    kind=motion_kind,
                    start=(sx, sy, sz),
                    end=(x, y, z),
                    center=center,
                    feed=feed,
                    spindle=spindle,
                )
            )

    return prog


def _arc_center(
    prog: Program,
    line_no: int,
    start: tuple[float, float],
    end: tuple[float, float],
    axis: dict[str, float],
    motion: str,
) -> Optional[tuple[float, float]]:
    """Resolve an arc centre from I/J offsets or an R radius.

    GRBL treats I/J as incremental from the start point. R-format arcs take
    the minor arc for positive R and the major arc for negative R.
    """
    sx, sy = start
    ex, ey = end

    if "I" in axis or "J" in axis:
        cx = sx + axis.get("I", 0.0)
        cy = sy + axis.get("J", 0.0)
        r_start = math.hypot(sx - cx, sy - cy)
        r_end = math.hypot(ex - cx, ey - cy)
        if r_start < 1e-9:
            prog.warnings.append(
                Warning_(line_no, "arc_zero_radius", "arc centre equals start point")
            )
            return None
        if abs(r_start - r_end) > ARC_RADIUS_TOL:
            prog.warnings.append(
                Warning_(
                    line_no,
                    "arc_radius_mismatch",
                    f"start r={r_start:.4f} end r={r_end:.4f} "
                    f"(delta {abs(r_start - r_end):.4f}mm)",
                )
            )
        return (cx, cy)

    if "R" in axis:
        r = axis["R"]
        dx, dy = ex - sx, ey - sy
        d = math.hypot(dx, dy)
        if d < 1e-9:
            prog.warnings.append(
                Warning_(line_no, "arc_r_full_circle", "R-format arc with no travel")
            )
            return None
        h_sq = r * r - (d / 2) ** 2
        if h_sq < 0:
            prog.warnings.append(
                Warning_(
                    line_no,
                    "arc_radius_too_small",
                    f"R={r} cannot span {d:.4f}mm",
                )
            )
            return None
        h = math.sqrt(h_sq)
        mx, my = (sx + ex) / 2, (sy + ey) / 2
        ux, uy = -dy / d, dx / d
        # Sign convention: which side of the chord the centre falls on.
        sign = 1.0 if (r > 0) == (motion == "arc_ccw") else -1.0
        return (mx + sign * h * ux, my + sign * h * uy)

    prog.warnings.append(
        Warning_(line_no, "arc_no_centre", "arc with no I/J and no R")
    )
    return None


def summarize(prog: Program, rapid_rate: float = 5000.0) -> str:
    moves = prog.moves
    if not moves:
        return "no moves parsed"

    cuts = [m for m in moves if not m.is_rapid]
    rapids = [m for m in moves if m.is_rapid]
    arcs = [m for m in moves if m.is_arc]

    xs = [c for m in moves for c in (m.start[0], m.end[0])]
    ys = [c for m in moves for c in (m.start[1], m.end[1])]
    zs = [c for m in moves for c in (m.start[2], m.end[2])]

    cut_len = sum(m.length for m in cuts)
    rapid_len = sum(m.length for m in rapids)

    secs = sum(m.length / m.feed * 60 for m in cuts if m.feed) + (
        rapid_len / rapid_rate * 60
    )

    feeds = sorted({round(m.feed, 1) for m in cuts if m.feed})
    spindles = sorted({int(m.spindle) for m in moves if m.spindle})

    plunges = [m for m in cuts if m.dz < -1e-6 and m.xy_length < 1e-6]

    out = [
        f"file        {prog.source}",
        f"units       {prog.units}",
        f"moves       {len(moves)}  ({len(cuts)} cutting, {len(rapids)} rapid, {len(arcs)} arc)",
        f"extents     X {min(xs):8.3f} .. {max(xs):8.3f}",
        f"            Y {min(ys):8.3f} .. {max(ys):8.3f}",
        f"            Z {min(zs):8.3f} .. {max(zs):8.3f}",
        f"path        {cut_len / 1000:.2f} m cutting, {rapid_len / 1000:.2f} m rapid",
        f"plunges     {len(plunges)} straight-down moves",
        f"feeds       {feeds if len(feeds) <= 8 else str(feeds[:8]) + ' ...'} mm/min",
        f"spindle     {spindles} rpm",
        f"est. time   {secs / 60:.1f} min (rapids assumed {rapid_rate:.0f} mm/min)",
    ]

    if prog.warnings:
        by_code: dict[str, list[Warning_]] = {}
        for w in prog.warnings:
            by_code.setdefault(w.code, []).append(w)
        out.append(f"warnings    {len(prog.warnings)} total")
        for code, ws in sorted(by_code.items(), key=lambda kv: -len(kv[1])):
            out.append(f"            {len(ws):>6}  {code}")
            for w in ws[:3]:
                out.append(f"                    line {w.line_no}: {w.detail}")
            if len(ws) > 3:
                out.append(f"                    ... and {len(ws) - 3} more")
    else:
        out.append("warnings    none")

    return "\n".join(out)


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        print("usage: ncparse.py FILE.nc [--moves N]")
        return 2

    path = argv[1]
    prog = parse(path)
    print(summarize(prog))

    if "--moves" in argv:
        n = int(argv[argv.index("--moves") + 1])
        print(f"\nfirst {n} moves:")
        for m in prog.moves[:n]:
            c = f" c={m.center[0]:.3f},{m.center[1]:.3f}" if m.center else ""
            print(
                f"  L{m.line_no:<6} {m.kind:<8} "
                f"({m.start[0]:8.3f},{m.start[1]:8.3f},{m.start[2]:7.3f}) -> "
                f"({m.end[0]:8.3f},{m.end[1]:8.3f},{m.end[2]:7.3f}) "
                f"len={m.length:7.3f}{c}"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
