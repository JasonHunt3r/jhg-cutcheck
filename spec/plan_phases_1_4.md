# jhg-cutcheck — Development Plan, Phases 1–4

> **HISTORICAL — do not plan from this document.**
> The order was reversed: visualiser first, verification later. The live
> plan is `spec/plan.md`. This file is kept because the verification design
> below (severity model, finding codes, report and manifest schemas) is
> parked rather than abandoned, and is worth returning to when rules are
> written — informed by what the simulator actually shows.

**Version:** 0.3 (draft, superseded)
**Date:** 2026-09-20
**Repo:** `github.com/JasonHunt3r/jhg-cutcheck` (public)
**Local:** `/Users/jasonhunter/Projects/jhg-cutcheck`
**Status:** Phase 0 complete. Phase 1 not started.

### Changes from 0.2

- **CAMotics reframed from anti-goal to reference.** The project began as
  "why don't we rebuild that in Swift." Prior drafts wrote CAMotics up as scope
  creep to resist, which inverted the founding intent. The scope *limits* are
  unchanged; the relationship claim is corrected.
- **The viewer is promoted to a primary deliverable**, deferred in sequence
  only. It replaces what CAMotics showed, and it is the surface Jason uses to
  discuss a cut with Claude.
- **Motivating incident named:** the failed Panel C run. A working simulator
  would have caught it before the material was cut.
- **The repo's role as shared workspace made explicit** — Jason, Claude Code
  and App Claude working the same files.

### Changes from 0.1

- Primary failure mode restated: the defect this tool exists to catch is a
  **shipped NC file that cuts a path the preview image did not show**, not
  dimensional inaccuracy. Trueness of cuts has not been the problem.
- **Independence rule added:** cutcheck reads only the shipped NC file. It never
  reads the generator's intermediate path data.
- Swept volume, not radius alone — Z extent is explicit in the model.
- **STL export moved into Phase 2.** Virtual inspection by eye is core function,
  not polish, and arrives before any Swift exists.
- Fixtures changed from measured parts to **file pairs** (NC + the overlay SVG
  that misrepresented it). Caliper measurement is now secondary.

---

## What this is

A verification tool for generated G-code. It reconstructs the cut from the NC
file alone, removes virtual material with the tool's swept volume, and reports
what the part actually becomes — so the result can be inspected before it is
promoted to real material.

**The failure it exists to catch:** a preview overlay is a drawing of intent. An
NC file is an instruction to a machine. Anything that happens between those two
artifacts — arc fitting, path reversal, an offset applied after the overlay was
drawn, a winding flip — is invisible in the picture. The overlay can look correct
while the file cuts something else. That has happened, and it is the class of
defect this tool targets.

## What this is NOT

- **Not a general CAM simulator.** 3-axis, 2.5D, flat cutters, GRBL dialect
  only — this bench's machine and dialect, not everyone's. Narrow scope, but
  CAMotics is the model rather than something to avoid; see below.
- **Not a physics simulator.** It cannot see bit deflection, workpiece movement,
  stock that was not flat, or feeds that burn rather than cut. Those are settled
  at the machine.
- **Not a product.** No signing, no notarization, no Apple Developer account, no
  other users. Deferred until the tool earns its place on this bench.

The honest claim is "catches the errors visible in the file," never "ensures
the cut."

## Relationship to CAMotics

CAMotics is the functional reference. The project began as "why don't we
rebuild that in Swift," and that remains the shape of it.

**Carried over:** simulating the tool's path through the medium, and showing
the result. That is the part of CAMotics in daily use here, and the part whose
loss would actually be felt.

**Not carried over:** the breadth — other dialects, other machine classes,
lathes, 5-axis, the plugin surface. Narrowing is not rejection.

**Added, which CAMotics never did:** automated checking against design intent
and machine limits, emitting a machine-readable report another program can gate
on. A human watching a CAMotics animation catches what they happen to notice.
A report catches what it was told to look for, every time, without fatigue.

### The incident this is measured against

The failed Panel C run. Time and material lost to a file that was committed to
real stock before anyone could see what it would actually do. A simulator that
showed the cut, or a checker that flagged it, would have stopped it at no cost.

That run is the benchmark: **if cutcheck would not have caught Panel C, it is
not finished.** The archived NC file for it is the primary Phase 2 fixture.

---

## Deferred past Phase 4

Native 3D viewer, RealityKit, deviation coloring on the mesh, pass-by-pass
playback, section cuts, OpenSCAD/SCAD integration, the SwiftUI app, additional
G-code dialects, additional machine profiles, signing, anything product-related.

**Deferred in sequence, not in rank.** The viewer is a primary deliverable — it
is what replaces what CAMotics showed. It is scheduled after the checker only
because the checker can be proven against fixtures sooner and more cheaply.

Deferring the *viewer* does not defer *inspection* — see Phase 2.

---

## How the core works

1. **Parse the shipped NC file.** Tool center path, move by move.
2. **Sweep the tool.** Not radius alone: the cutter is a cylinder with a Z
   extent, swept along each move. Radius handles XY; depth of cut handles Z.
   Step-downs, tabs and plunges live in Z, and a radius-only model would draw a
   convincing outline while missing a plunge through the spoilboard.
3. **Remove material.** Stock is a grid of Z heights; each move lowers every
   cell the swept volume passes over.
4. **Compare.** Simulated stock against design intent: where they differ, by how
   much, and in which direction — material missing that should be there (gouge)
   or material left that should be gone (uncut).
5. **Report and export.** Machine-readable findings, plus an STL of the result
   for visual inspection.

### The independence rule

**Cutcheck reads only the shipped NC file.** Never the generator's intermediate
arrays, never the path data the overlay was drawn from, never a parallel export.

This is not a style preference — it is the entire basis of the tool's value. The
bug class in scope is precisely one where the overlay and the G-code were drawn
from different representations. A checker sharing a representation with either
one is blind to exactly the defect it exists to find.

Machine-specific facts live in `profiles/*.json` as data: travel envelope, max
feeds, spindle RPM range, units. Adding a machine means adding a file, never
editing the simulator. If a machine fact is about to be hardcoded, that is a bug.

---

## Severity model

| Level | Meaning | Examples | CC behavior |
|---|---|---|---|
| **fatal** | Damages part or machine, or the part is not what was designed | Gouge into the finished boundary; uncut material where the design says removed; path outside travel envelope; plunge deeper than stock; cut into keep-out | **Block.** Do not present the file. |
| **warning** | Survivable, or the documentation lied but the part is right | Overlay SVG disagrees with the simulated result while design intent is still met; feed or RPM outside profile; deviation past the red band; tab shorter than nominal | Surface to Jason, do not block |
| **note** | Informational | Run time, pass count, cut length, plunge count | Log only |

A run passes with zero fatals. Deviation bands follow existing JHG convention:
green <0.1mm, yellow 0.1–0.2, orange 0.2–0.3, red >0.3.

The overlay-disagreement case is deliberately a warning rather than a fatal: if
the simulated part matches the design, the file is safe to cut even though the
picture was wrong. But it must always be reported, because a lying overlay is a
generator bug that will bite differently next time.

---

## Phase 1 — The spec

**Where:** this chat, drafted into `spec/`
**Who:** Claude drafts, Jason reviews
**Estimate:** one session

The formats are the contract between three parties: the generator (ClaudeCAM via
Claude Code), the checker, and design review (App Claude reading the repo).
Nothing gets built until they are settled.

### Deliverables

1. **`spec/manifest.schema.md`** — what a run submits.
   - run id, timestamp, generator name and version
   - NC file path and SHA256
   - design reference: SVG path and SHA256
   - **overlay reference:** the preview SVG the generator produced, and its
     SHA256 — this is what gets checked against the simulated result
   - stock: dimensions, thickness, material
   - tool: diameter, type, flutes
   - parameters actually used: BIT_R, offsets (EMG_OFFSET, POCKET_EXPAND),
     depth per pass, feeds, RPM
   - expected cut order
   - keep-out regions, if any
   - machine profile reference

2. **`spec/report.schema.md`** — what the checker returns.
   - run id and manifest SHA256, so a report can never be read against the
     wrong job
   - pass/fail, counts by severity
   - findings: severity, code, message, NC line number, XY position,
     measured vs expected
   - **divergence section:** simulated result vs overlay SVG, region by region
   - dimensional summary: overall extents, per-feature measurements
   - deviation summary in the color bands
   - path to the exported STL
   - run-time estimate, pass count, cut length
   - versions: checker, machine profile

3. **`spec/machine-profile.schema.md`** + **`profiles/ttc450-pro.json`**
   Travel envelope XYZ, max feed per axis, max plunge feed, spindle RPM range,
   soft limit behavior, units.

4. **`spec/folder-layout.md`** — run folder naming, what is committed, what
   stays local (heightmaps are regenerable and stay out of git; STLs are
   regenerable too and are gitignored).

### Gate

Jason can express a real past job as a manifest by hand without hitting a
missing field. A missing field means the schema is wrong and gets fixed before
Phase 2.

---

## Phase 2 — Python prototype

**Where:** this chat, into `prototype/`
**Who:** Claude writes, Jason supplies fixture file pairs
**Estimate:** one to two sessions

Exists to make the difficulty estimate falsifiable cheaply, before any Swift.

### Components

1. **GRBL parser.** G0/G1/G2/G3, G20/G21, G90/G91, G17, arc I/J offsets, feed
   and spindle words. Arcs are the known hazard: I/J sign conventions and swept
   area on curves are where prior geometry bugs have lived.
2. **Swept-volume engine.** Height grid; cylinder with Z extent swept along each
   move. Resolution configurable, default fine enough to resolve 0.1mm.
3. **Checks.** Simulated-vs-design comparison, simulated-vs-overlay divergence,
   envelope, feeds, RPM, plunge depth, keep-out, tab heights, cut-order
   conformance.
4. **Report writer.** Emits the Phase 1 report schema.
5. **STL export.** Height grid to mesh. This is what makes virtual inspection
   possible in Phase 2 rather than Phase 5: the result opens in OpenSCAD via
   `import()`, Blender, MeshLab or Fusion, and can be spun and zoomed the same
   day the simulator runs.

### Gates — all must hold

- **It fires.** The archived divergence fixture is flagged, and the finding
  matches the defect that actually occurred.
- **It stays quiet.** No fatal on a job known to have cut correctly.
- **It survives the eye.** The exported STL, spun and inspected by Jason, looks
  like the part — no artifacts, no phantom geometry, no missing features. If the
  mesh looks wrong, either the simulator is broken or the file is, and both are
  worth knowing immediately.

Dimensional agreement with measurement is a secondary check, not a gate.
Trueness of cuts has not been the failing area.

### Fixtures required from Jason

- **The Panel C run:** its archived NC file, the overlay SVG that accompanied
  it, and what went wrong. Confirm the exact run against the archive when
  pulling it — several Panel C jobs exist and only one is the failure.
- **A divergence pair:** an NC file that cut wrong and the overlay SVG that
  misrepresented it, plus which one was wrong and how it showed up. Panel C may
  serve as this if its defect was of that class.
- **A clean pair:** an NC and overlay from a job that cut correctly.
- Parameters used for each, and the design SVG they came from.

Measured parts are welcome but optional. The defect lives in the files.

---

## Phase 3 — Swift CLI

**Where:** Claude Code, into `sim/`
**Who:** Claude Code writes and builds; the Python prototype is the oracle
**Estimate:** days of CC work

Port the Phase 2 core to a Swift package with a command-line front end. Shared
library plus thin CLI, so the later viewer links the same code rather than
reimplementing it.

The safest kind of work: translation against a reference implementation that
already agrees with known-good and known-bad fixtures.

### Gate

On every fixture, the Swift CLI produces the same report as the Python
prototype — same findings, same measurements, same severities, same STL
geometry. Timing and formatting differences allowed; numeric differences not.

### Notes

- Xcode is installed; `xcode-select -p` must point at Xcode.app, not
  CommandLineTools.
- No Apple Developer account at this phase.

---

## Phase 4 — Watcher and Git automation

**Where:** Claude Code, into `sim/`
**Estimate:** fiddly; plumbing time hides here
**Risk:** highest of the four

### Behavior

- Watch the runs folder; new run appears, check it, write the report and STL.
- Pull before each run; commit and push after the report lands.
- Structured commit messages: run id, pass/fail, worst deviation. History reads
  as a shop log.
- Each run in its own folder with a unique id. Claude Code writes inputs, the
  checker writes outputs, neither touches the other's files. Merge conflicts are
  avoided by never writing the same file, not by resolving cleverly.
- System git and the existing SSH key. No stored credentials.
- Committed: NC, manifest, report, overlay SVG. Not committed: heightmaps, STLs,
  other regenerable intermediates.

### Gate

Claude Code drops a run into the folder and the report appears in the repo,
pushed, with no human action — then verified from a second location by reading
the public raw URL.

### After Phase 4

The full checking value exists with no GUI. What remains is a better pair of
eyes, which is a real upgrade rather than polish — see below.

---

## The viewer — primary, and why it is still sequenced last

Automated checks only catch what someone thought to write a rule for. Jason's
eye catches what nobody anticipated, which is the category that has actually
bitten this project. Virtual inspection is therefore core function, not
decoration.

It arrives in two stages:

- **Phase 2 (early):** STL export, inspected in any existing 3D viewer. Spin,
  zoom, look. No new software required.
- **Later (deferred):** a native viewer, which adds what a generic STL viewer
  cannot — deviation bands painted on the surface so a gouge glows, pass-by-pass
  playback to catch a tab removed too early, section cuts through pockets, and
  the intended part ghosted over the simulated one.

The second stage is worth building, and it is the point of the Swift work
rather than a bonus on top of it. It is simply not what stands between Jason
and inspecting a part before cutting it — stage one already clears that.

It is also the surface Jason uses to talk to Claude about a cut. A rendered
part in a viewer, in a repo both Claude Code and App Claude can read, is a
shared referent: "this pocket, here" beats describing coordinates in prose.

---

## The repo as shared workspace

The repo is the surface three parties work on, not just storage:

| Party | Access | Role |
|---|---|---|
| Jason | the files in `~/Projects` | shop truth; inspects the simulated part by eye |
| Claude Code | the same files, locally | generates, checks, builds |
| App Claude | the same files, via the public repo | design review, planning, spec drafting |

Two consequences worth stating plainly:

- **Pushing is what makes work visible to App Claude.** A local commit is not
  readable over the network. Work that stays local is invisible to a third of
  the team.
- **The repo is public**, which is what makes that access possible. Nothing
  secret goes in it. Credentials stay out; the tooling stores none.

Together with ClaudeCAM this forms one working set — the tools for the work in
one place, reachable by all three parties, rather than carried between them by
copy-paste.

---

## Division of labor

| | Jason | Claude Code | App Claude |
|---|---|---|---|
| Fixture file pairs | ✅ | | |
| Visual inspection of simulated parts | ✅ | | |
| Shop truth, spec review | ✅ | | |
| Schemas | review | | draft |
| Python prototype | fixtures | | write |
| Swift port, build, test | | ✅ | review |
| Watcher and git | | ✅ | |
| Design review from repo | | | ✅ |

Physical shop observation overrules simulation. If the tool and the part in
Jason's hand disagree, the part is right and the tool has a bug.

---

## Risk register

| Risk | Phase | Mitigation |
|---|---|---|
| Arc handling (G2/G3, I/J, swept area on curves) | 2 | Known-hazard area with prior history; test against arc-heavy fixtures specifically |
| Z modeling: step-downs, tabs, plunges | 2 | Swept volume with explicit Z extent from the start, never radius-only |
| Checks only catch anticipated defects | all | STL export in Phase 2 so human inspection covers the unanticipated |
| Shared representation blindness | all | The independence rule: NC file only, never generator internals |
| Estimate optimism | all | Every phase ends in a gate that can fail cheaply |
| Plumbing time (watcher, git, permissions) | 4 | Individually boring, collectively a week — budget it |
| Scope creep beyond this bench's machine and dialect | all | The scope limits under "What this is NOT" are the boundary — not the CAMotics comparison, which is the reference |
| Panel C would not have been caught | 2 | Its archived NC file is the primary fixture; the gate is that the tool fires on it |
