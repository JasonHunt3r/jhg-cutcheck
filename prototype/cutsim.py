"""Run an NC file against a block of virtual stock and write the remainder.

The cutter is a flat-bottomed cylinder. It follows every commanded move --
rapids included, because a rapid below the surface removes material just as
a feed move does. Wherever the cylinder and the stock overlap, the stock
loses. What is left at the end of the program is written out as a mesh.

This draws the G-code. It does not judge it.
"""

from __future__ import annotations

import argparse
import math
import os
import struct
import sys
import time

import numpy as np

import ncparse


class Stock:
    """A rectangular block as a grid of surface heights.

    Each cell holds the Z of the material surface in that column. Cutting
    lowers cells; nothing ever raises them. Everything above a cell's height
    has been removed, which is what makes the cylinder's shaft free to model:
    only the tip's depth matters.
    """

    def __init__(self, xmin, xmax, ymin, ymax, top, bottom, resolution):
        self.xmin, self.xmax = float(xmin), float(xmax)
        self.ymin, self.ymax = float(ymin), float(ymax)
        self.top, self.bottom = float(top), float(bottom)
        self.res = float(resolution)

        self.nx = int(math.ceil((self.xmax - self.xmin) / self.res)) + 1
        self.ny = int(math.ceil((self.ymax - self.ymin) / self.res)) + 1

        self.xs = self.xmin + np.arange(self.nx) * self.res
        self.ys = self.ymin + np.arange(self.ny) * self.res
        self.h = np.full((self.ny, self.nx), self.top, dtype=np.float32)

    @property
    def cell_area(self):
        return self.res * self.res

    def _index_window(self, lo, hi, axis_min, n):
        """Grid index range covering [lo, hi], clipped to the block."""
        i0 = int(math.floor((lo - axis_min) / self.res))
        i1 = int(math.ceil((hi - axis_min) / self.res))
        return max(i0, 0), min(i1 + 1, n)

    def cut_segment(self, p0, p1, radius):
        """Sweep the cutter from p0 to p1, lowering every cell it covers."""
        x0, y0, z0 = p0
        x1, y1, z1 = p1

        # A move that stays at or above the untouched surface cannot cut.
        if min(z0, z1) >= self.top:
            return

        ix0, ix1 = self._index_window(
            min(x0, x1) - radius, max(x0, x1) + radius, self.xmin, self.nx
        )
        iy0, iy1 = self._index_window(
            min(y0, y1) - radius, max(y0, y1) + radius, self.ymin, self.ny
        )
        if ix0 >= ix1 or iy0 >= iy1:
            return  # entirely off the block

        gx = self.xs[ix0:ix1][None, :]
        gy = self.ys[iy0:iy1][:, None]

        dx, dy = x1 - x0, y1 - y0
        len_sq = dx * dx + dy * dy

        if len_sq < 1e-12:
            # Pure plunge or dwell: a disc at a single XY position.
            dist_sq = (gx - x0) ** 2 + (gy - y0) ** 2
            mask = dist_sq <= radius * radius
            if mask.any():
                view = self.h[iy0:iy1, ix0:ix1]
                np.minimum(view, min(z0, z1), out=view, where=mask)
            return

        # Distance from each cell centre to the segment, and how far along
        # the segment the closest point sits -- t gives us the cutter's Z
        # there, so ramps and helical moves cut at the right depth.
        t = ((gx - x0) * dx + (gy - y0) * dy) / len_sq
        np.clip(t, 0.0, 1.0, out=t)
        cx = x0 + t * dx
        cy = y0 + t * dy
        dist_sq = (gx - cx) ** 2 + (gy - cy) ** 2
        mask = dist_sq <= radius * radius
        if not mask.any():
            return

        z_at = z0 + (z1 - z0) * t
        view = self.h[iy0:iy1, ix0:ix1]
        np.minimum(view, z_at, out=view, where=mask)

    def removed_volume(self):
        return float((self.top - self.h).sum()) * self.cell_area

    def write_stl(self, path, name="cutsim"):
        """Write the remaining solid as a binary STL.

        Top surface from the height grid, vertical skirt around the edges,
        flat bottom -- a closed solid a viewer will shade correctly.
        """
        h = self.h.astype(np.float64)
        ny, nx = h.shape
        X, Y = np.meshgrid(self.xs, self.ys)

        def quads(a, b, c, d):
            """Two triangles per quad, as (n, 3, 3) vertex arrays."""
            t1 = np.stack([a, b, c], axis=1)
            t2 = np.stack([a, c, d], axis=1)
            return np.concatenate([t1, t2], axis=0)

        tris = []

        # Top surface.
        v00 = np.stack([X[:-1, :-1], Y[:-1, :-1], h[:-1, :-1]], axis=-1).reshape(-1, 3)
        v10 = np.stack([X[:-1, 1:], Y[:-1, 1:], h[:-1, 1:]], axis=-1).reshape(-1, 3)
        v11 = np.stack([X[1:, 1:], Y[1:, 1:], h[1:, 1:]], axis=-1).reshape(-1, 3)
        v01 = np.stack([X[1:, :-1], Y[1:, :-1], h[1:, :-1]], axis=-1).reshape(-1, 3)
        tris.append(quads(v00, v10, v11, v01))

        bz = self.bottom

        def skirt(px, py, pz, flip):
            top_a = np.stack([px[:-1], py[:-1], pz[:-1]], axis=-1)
            top_b = np.stack([px[1:], py[1:], pz[1:]], axis=-1)
            bot_a = np.stack([px[:-1], py[:-1], np.full(len(px) - 1, bz)], axis=-1)
            bot_b = np.stack([px[1:], py[1:], np.full(len(px) - 1, bz)], axis=-1)
            return quads(bot_a, bot_b, top_b, top_a) if flip else quads(
                top_a, top_b, bot_b, bot_a
            )

        tris.append(skirt(self.xs, np.full(nx, self.ys[0]), h[0, :], False))
        tris.append(skirt(self.xs, np.full(nx, self.ys[-1]), h[-1, :], True))
        tris.append(skirt(np.full(ny, self.xs[0]), self.ys, h[:, 0], True))
        tris.append(skirt(np.full(ny, self.xs[-1]), self.ys, h[:, -1], False))

        # Bottom face.
        c = np.array(
            [
                [self.xs[0], self.ys[0], bz],
                [self.xs[-1], self.ys[0], bz],
                [self.xs[-1], self.ys[-1], bz],
                [self.xs[0], self.ys[-1], bz],
            ]
        )
        tris.append(
            np.stack([c[[0, 2, 1]], c[[0, 3, 2]]], axis=0)
        )

        T = np.concatenate(tris, axis=0).astype(np.float32)

        n = np.cross(T[:, 1] - T[:, 0], T[:, 2] - T[:, 0])
        ln = np.linalg.norm(n, axis=1, keepdims=True)
        n = np.divide(n, ln, out=np.zeros_like(n), where=ln > 0).astype(np.float32)

        rec = np.zeros((len(T), 12), dtype=np.float32)
        rec[:, 0:3] = n
        rec[:, 3:12] = T.reshape(-1, 9)
        buf = np.zeros((len(T), 50), dtype=np.uint8)
        buf[:, :48] = rec.view(np.uint8).reshape(-1, 48)

        with open(path, "wb") as fh:
            fh.write(name.encode("ascii", "replace")[:79].ljust(80, b"\0"))
            fh.write(struct.pack("<I", len(T)))
            fh.write(buf.tobytes())

        return len(T)


def simulate(prog, stock, radius, max_sag=0.01, max_dz=0.2, progress=True):
    """Push every move through the stock, in emission order."""
    moves = prog.moves
    t0 = time.time()
    segs = 0

    for i, m in enumerate(moves):
        pts = m.polyline(max_sag=max_sag) if m.is_arc else [m.start, m.end]

        for a, b in zip(pts, pts[1:]):
            # Split steep moves so a ramp's depth is followed, not averaged.
            dz = abs(b[2] - a[2])
            steps = max(1, int(math.ceil(dz / max_dz)))
            if steps == 1:
                stock.cut_segment(a, b, radius)
                segs += 1
            else:
                for s in range(steps):
                    t_a, t_b = s / steps, (s + 1) / steps
                    pa = tuple(a[k] + (b[k] - a[k]) * t_a for k in range(3))
                    pb = tuple(a[k] + (b[k] - a[k]) * t_b for k in range(3))
                    stock.cut_segment(pa, pb, radius)
                    segs += 1

        if progress and (i % 250 == 0 or i == len(moves) - 1):
            pct = 100 * (i + 1) / len(moves)
            sys.stderr.write(
                f"\r  cutting {i + 1}/{len(moves)} moves ({pct:5.1f}%) "
                f"{segs} segments  {time.time() - t0:5.1f}s"
            )
            sys.stderr.flush()

    if progress:
        sys.stderr.write("\n")
    return segs


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Simulate an NC file cutting a block of stock; write the remainder as STL."
    )
    ap.add_argument("nc", help="NC file to run")
    ap.add_argument("--size", required=True,
                    help="stock as WxDxT in mm, e.g. 400x430x16")
    ap.add_argument("--origin", default="center",
                    help="'center' (default) or 'corner', or explicit 'xmin,ymin'")
    ap.add_argument("--bit", type=float, required=True,
                    help="cutter diameter in mm")
    ap.add_argument("--resolution", type=float, default=0.5,
                    help="grid cell size in mm (default 0.5)")
    ap.add_argument("-o", "--out", default=None, help="output STL path")
    args = ap.parse_args(argv)

    try:
        w, d, t = (float(v) for v in args.size.lower().split("x"))
    except ValueError:
        ap.error("--size must look like 400x430x16")

    if args.origin == "center":
        xmin, ymin = -w / 2, -d / 2
    elif args.origin == "corner":
        xmin, ymin = 0.0, 0.0
    else:
        try:
            xmin, ymin = (float(v) for v in args.origin.split(","))
        except ValueError:
            ap.error("--origin must be 'center', 'corner', or 'xmin,ymin'")

    out = args.out or os.path.splitext(os.path.basename(args.nc))[0] + "_cut.stl"

    print(f"parsing   {args.nc}")
    prog = ncparse.parse(args.nc)
    cuts = sum(1 for m in prog.moves if not m.is_rapid)
    print(f"          {len(prog.moves)} moves ({cuts} cutting), units {prog.units}")

    stock = Stock(xmin, xmin + w, ymin, ymin + d, 0.0, -t, args.resolution)
    print(f"stock     {w}x{d}x{t}mm  X {stock.xmin}..{stock.xmax}  "
          f"Y {stock.ymin}..{stock.ymax}  top 0.0 bottom {-t}")
    print(f"grid      {stock.nx} x {stock.ny} cells @ {args.resolution}mm "
          f"({stock.nx * stock.ny / 1e6:.2f}M)")
    print(f"cutter    flat cylinder, dia {args.bit}mm (r {args.bit / 2}mm)")

    t0 = time.time()
    segs = simulate(prog, stock, args.bit / 2.0)
    elapsed = time.time() - t0

    vol = stock.removed_volume()
    lowest = float(stock.h.min())
    print(f"removed   {vol / 1000:.1f} cm3 of {w * d * t / 1000:.1f} cm3 "
          f"({100 * vol / (w * d * t):.1f}%)")
    print(f"lowest    Z {lowest:.3f}mm"
          + ("  (cut through)" if lowest <= -t + 1e-6 else ""))
    print(f"sim       {segs} segments in {elapsed:.1f}s")

    ntris = stock.write_stl(out)
    print(f"wrote     {out}  ({ntris} triangles, "
          f"{os.path.getsize(out) / 1e6:.1f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
