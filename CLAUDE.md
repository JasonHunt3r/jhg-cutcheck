# CLAUDE.md — jhg-cutcheck

Standing context for Claude Code sessions in this repo. Read this first.

---

## What this project is

**jhg-cutcheck** simulates the tool's path through the material, so the cut can
be seen and checked before it is committed to real stock.

It reconstructs the cut from the NC file alone, removes virtual material with
the tool's swept volume, and reports what the part actually becomes — plus a
mesh so the result can be inspected by eye.

It is built for the ClaudeCAM pipeline: ClaudeCAM generates, CutSim shows what
was generated. See **Prior art** below.

**The failure it exists to catch:** a preview overlay is a drawing of intent; an
NC file is an instruction to a machine. Anything happening between them — arc
fitting, path reversal, an offset applied after the overlay was drawn, a winding
flip — is invisible in the picture. The overlay can look right while the file
cuts something else. That has happened here. Dimensional trueness has *not* been
the problem; preview-versus-cut divergence has.

The loop it closes: ClaudeCAM generates a job → cutcheck checks it → the report
comes back → the generator is fixed, or the file is cleared for the shop. The
two sides talk through files in this repo, not through copy-paste.

## What it is NOT

- **Not a general CAM simulator.** 3-axis, 2.5D, flat cutters, GRBL dialect
  only — this bench's machine and dialect, not everyone's.
- **Not a physics simulator.** It cannot see bit deflection, workpiece movement,
  stock that was not flat, or feeds that burn rather than cut. Those are settled
  at the machine by Jason.
- **Not a product.** No signing, no notarization, no Apple Developer account, no
  other users. Deferred until the tool earns its place on this bench.

The honest claim is "catches the errors visible in the file," never "ensures
the cut."

---

## Prior art

Path previsualisation is a well-established category — CAMotics, the
simulators built into most CAM packages, and others all show a toolpath
cutting virtual stock. CutSim is another program doing that task, written
for this pipeline.

**Provenance: no CAMotics source has been examined, and none is used.** The
implementation was derived from the NC files themselves and from the
standard approach to this problem — stock as a grid of surface heights, the
cutter swept through it as a cylinder. That technique is common to the whole
category and predates any particular implementation of it.

CAMotics matters here for one practical reason: it is what the shop uses for
previsualisation today, and it is an Intel binary. When Rosetta goes it stops
running. That sets the schedule, not the design.

What CutSim adds beyond showing the cut is knowledge of this pipeline — it
reads ClaudeCAM's own section comments and header parameters, so it opens a
job already configured and already knowing what its passes are called.

---

## The independence rule

**Cutcheck reads only the shipped NC file.** Never the generator's intermediate
arrays, never the path data the overlay was drawn from, never a parallel export
of the same geometry.

This is the basis of the tool's value, not a style preference. The bug class in
scope is one where overlay and G-code came from different representations. A
checker sharing a representation with either is blind to exactly the defect it
exists to find.

---

## Relationship to ClaudeCAM

Two separate repos, siblings, not nested:

| | Repo | Origin | Role |
|---|---|---|---|
| `~/Projects/ClaudeCAM` | jhg-shop-docs | public docs library | generates G-code; holds shop standards and runbook |
| `~/Projects/jhg-cutcheck` | jhg-cutcheck | this repo | checks G-code |

Kept separate deliberately: ClaudeCAM's origin is the public documentation
library pulled at session start, and nesting repos invites submodule confusion.

**Naming collision to watch:** ClaudeCAM has `jobs/`. This repo uses `runs/`
for the same conceptual thing. Not interchangeable. If a file's provenance is
unclear, check rather than guess.

Shop standards in jhg-shop-docs (`jhg_gcode_hygiene`, `jhg_shop_file_standards`,
the runbook) still govern G-code conventions. This repo does not restate them.

---

## The repo as shared workspace

The repo is not just storage. It is the shared surface three parties work on:

| Party | Access | Role |
|---|---|---|
| Jason | the files in `~/Projects` | shop truth; inspects the simulated part by eye |
| Claude Code | the same files, locally | generates, checks, builds |
| App Claude | the same files, via the public repo | design review, planning, spec drafting |

This is why the work lives in `~/Projects` and why it is pushed rather than
kept local: pushing is what makes a file readable by App Claude. **A commit is
not visible to App Claude until it is pushed.** Local-only work is invisible to
a third of the team.

Together with ClaudeCAM this forms one working set — the tools for the work in
one place, reachable by all three parties, rather than moved between them by
copy-paste.

---

## Current state

**The viewer works.** `CutSim.app` reads an NC file, simulates the cut and
draws the result: orbit, zoom, scrub, section landmarks, playback, and
detail-on-demand down to 0.01mm on the region you are looking at. The Swift
core matches the Python prototype exactly on all 11 archived Panel C files.

It has already earned its keep: the March 2026 Panel C defect — a 400mm
traverse at full depth, invisible in the overlay — is obvious on sight.

Windowing is next. See `spec/plan.md`.

Full plan: **`spec/plan.md`**. That document is the reference for what is
built, what is next, and what gate it must pass. Read it before proposing
work.

`spec/macos_panels_guide.md` records how the window system was built —
floating panels, snapping, persistence, activation, menu conventions. It is
written to be reusable on other projects, not just this one.

`spec/plan_phases_1_4.md` (v0.3) is historical: it describes the
verification design, which is parked. Do not plan from it.

Short version:

The order was reversed early on, deliberately: **visualiser first,
verification later.** Rules only catch what someone thought to write a rule
for, and the defects that actually bit this project were ones nobody
anticipated. The simulator surfaces those.

A native 3D viewer, OpenSCAD/SCAD integration, the SwiftUI app, extra dialects
and extra machines are deferred past Phase 4 — **deferred in time, not in
rank.** The viewer is a primary deliverable, not polish: it is what replaces
previsualisation, and it is the surface Jason uses to talk to Claude about
a cut. It is sequenced late only because the checker is falsifiable sooner.

Deferring the *viewer* does not defer *inspection* — Phase 2's mesh opens in
any existing 3D viewer.

---

## Repo layout

```
spec/        schemas and the phase plan
profiles/    machine profiles, one JSON per machine (TTC450 PRO first)
fixtures/    ground-truth file pairs: NC + overlay SVG + design SVG + parameters
prototype/   Python simulation core
sim/         Swift package (Phase 3+)
runs/        live run folders, one per run id
```

Committed: NC, manifest, report, overlay SVG.
Not committed: heightmaps, exported STLs, and other regenerable intermediates.

---

## How the core works

1. Parse the shipped NC file into a tool center path.
2. Sweep the tool along it — **not radius alone**: the cutter is a cylinder with
   a Z extent. Radius handles XY, depth of cut handles Z. Step-downs, tabs and
   plunges live in Z, and a radius-only model would draw a convincing outline
   while missing a plunge through the spoilboard.
3. Remove material: stock is a grid of Z heights; each move lowers every cell
   the swept volume passes over.
4. Compare simulated stock against design intent (gouge vs uncut) and against
   the overlay SVG (did the picture lie).
5. Emit the report and an STL of the result.

Machine facts live in `profiles/*.json` as data: travel envelope, max feeds,
spindle RPM range, units. Adding a machine means adding a file, never editing
the simulator. If a machine fact is about to be hardcoded, that is a bug.

---

## Severity model

| Level | Meaning | Claude Code behavior |
|---|---|---|
| **fatal** | Damages part or machine, or the part is not what was designed: gouge into the finished boundary, uncut material where the design says removed, outside travel envelope, plunge deeper than stock, cut into keep-out | **Block.** Do not present the file. |
| **warning** | Survivable, or the documentation lied but the part is right: overlay disagrees with the simulated result while design intent is still met, feed or RPM outside profile, deviation past the red band | Surface to Jason, do not block |
| **note** | Informational: run time, pass count, cut length | Log only |

A run passes with zero fatals. Deviation bands follow existing JHG convention:
green <0.1mm, yellow 0.1–0.2, orange 0.2–0.3, red >0.3.

Overlay disagreement is a warning rather than a fatal: if the simulated part
matches the design, the file is safe to cut even though the picture was wrong.
It must always be reported — a lying overlay is a generator bug that will bite
differently next time.

---

## Working rules

- **Physical shop observation overrules simulation.** If this tool and the part
  in Jason's hand disagree, the part is right and the tool has a bug.
- **A verifier that has never fired is not a verifier.** Every check needs a
  fixture that makes it fire. Passing a file that was already good proves
  nothing.
- **Gates are pass/fail, not judgment calls.** Phase 2 requires all three: fires
  on the divergence fixture, stays quiet on the clean one, and the exported STL
  survives Jason's visual inspection.
- **Return to source files, not conversation summaries.** Relayed claims lose
  their derivation between sessions. The NC file is the source of truth.
- **Surgical changes.** Read the full relevant section before editing; verify
  output after each individual change, not in batches.
- **State the plan and confirm understanding before writing code.** Jason will
  correct direction directly; do not extend discussion once corrected.
- **No scope creep.** If a task is not in the current phase of
  `spec/plan.md`, raise it rather than building it.

## Environment

- macOS on Apple silicon. Xcode installed.
- Git over SSH, key already configured. The tooling stores no credentials.
- No browser tools.
- Python for the prototype; existing pipeline libraries are PyClipper,
  svgpathtools, Shapely.
- OpenSCAD doubles as an STL viewer via `import()` in Phase 2. When it becomes a
  dependency in a later phase, it must be a development snapshot — the 2021.01
  stable release is Intel-only.
