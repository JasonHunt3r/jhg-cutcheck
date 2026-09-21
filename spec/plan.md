# jhg-cutcheck — Plan

**Version:** 0.1
**Date:** 2026-09-20
**Status:** Viewer works. Windowing next.
**Supersedes:** `spec/plan_phases_1_4.md` (v0.3), kept as the historical
record of the verification design, which is parked rather than abandoned.

---

## What this is

A previsualisation tool for generated G-code. It reads an NC file, acts as
the cutting head moving through virtual stock, removes material where the
cutter and the stock overlap, and shows what the part becomes — spinnable,
zoomable, scrubbable through the program.

It is a drawing tool, not a judging tool. It shows what the file says. What
that means is Jason's call.

## Why it exists

CutSim is built for the ClaudeCAM pipeline: ClaudeCAM generates the NC file,
CutSim shows what that file actually does.

Path previsualisation is a well-established category — CAMotics, the
simulators inside most CAM packages, and others all show a toolpath cutting
virtual stock. This is another program doing that task, written for this
bench and this pipeline.

**Provenance: no CAMotics source has been examined, and none is used.** The
implementation came from the NC files and from the standard approach to the
problem — stock as a grid of surface heights, the cutter swept through it as
a cylinder — which is common to the category.

CAMotics sets the schedule rather than the design: it is what the shop uses
for previsualisation today, it is an Intel binary, and when Rosetta goes it
stops running.

The failure it is measured against is the Panel C run of March 2026: a file
whose preview overlay looked correct while the G-code drove 400mm across the
panel at full depth, six times, sawing it in half. No rule anticipated it.
A picture would have made it obvious in seconds.

**If cutcheck would not have caught Panel C, it is not finished.** It does:
the traverse is visible on sight, in under a second, without the machine.

## What it is not

- **Not a general CAM simulator.** 3-axis, 2.5D, flat cutters, GRBL dialect.
  This bench's machine and dialect.
- **Not a physics simulator.** No deflection, no workpiece movement, no
  stock that was not flat, no feeds that burn rather than cut. Those are
  settled at the machine.
- **Not a checker — yet.** See *Parked* below.

---

## Current state

### Works, verified

| | |
|---|---|
| `prototype/` | Python parser and simulator. Now the oracle, not the product. |
| `sim/Sources/CutSimCore` | Swift core: parser, height field, sections, PNG preview |
| `sim/Sources/cutsim` | CLI: simulate, write STL or depth-map PNG, list sections |
| `sim/Sources/CutSimApp` | `CutSim.app` — the viewer |
| `sim/Tests` | 10 unit tests |
| `sim/make-app.sh` | wraps the SwiftPM binary in a `.app` bundle |

**Parity gate held.** Across all 11 archived Panel C files, Swift matches
Python on move count, removed volume, lowest Z and segment count, and the
depth-map preview is byte-for-byte identical. Swift runs Panel C in 0.01s
against Python's 0.3s.

### Viewer features

- Orbit (drag), slide (⌥ or ⇧ drag, or right-drag), zoom (scroll or pinch)
- Reset to top view
- Shaded and wireframe
- Detail quality: 0.6 / 0.3 / 0.2 / 0.12mm
- **Detail on demand:** the visible region re-simulates at up to 0.01mm when
  the camera settles, drawn as a layer over the base
- Section landmarks read from the file's own comments, in both the current
  `; SECTION:` dialect and the older banner-wrapped one
- Move list with the current move highlighted; click to seek
- Scrub slider, arrow-key stepping (1 / 10 / 100), section jumps
- Playback with a log-scale speed control, 20–20000 moves/sec
- Self-configuring from the NC header: bit diameter, total depth, safe Z

### Design commitments

- **Reads only the shipped NC file.** Never the generator's intermediate
  data. A checker or viewer sharing a representation with the generator is
  blind to exactly the defects worth finding.
- **The work happens on Jason's CPU and GPU.** The app is self-sufficient;
  Claude is involved in building it, not in running it.
- **The height grid is the geometry.** It uploads as a texture and the
  vertex shader displaces a plane by it. No CPU mesh, so showing a different
  moment costs one texture upload.
- **Machine facts live in data, not code.** If a machine fact is about to be
  hardcoded, that is a bug.

---

## Next: windowing

Panels become real windows rather than docked columns. No docking tree, no
tear-off, no tab reintegration — those are weeks of work and permanent
maintenance against undocumented AppKit behaviour.

### Scope

1. **Panels as `NSPanel`s** with the utility style mask — the thin title bar,
   a real system style rather than custom chrome. Main window keeps the
   viewport and transport.
2. **Snapping**, in an `NSPanel` subclass overriding `setFrame` so it
   intercepts the drag rather than correcting afterwards. Within ~10pt:
   screen edges, another panel's opposing edge, another panel's matching
   edge.
3. **Size matching.** When a panel snaps alongside another and its opposite
   edge is already within ~24pt, it resizes to match exactly. Only fires
   when you were nearly there, so it does not fight you.
4. **Window menu** listing every panel with show/hide.
5. **View menu with layout presets** — arrangements that place and size all
   panels at once.
6. **Keyboard shortcuts.** Proposed, for review: ⌥⌘I Inspector, ⌥⌘1
   Sections, ⌥⌘2 Moves. Avoiding ⌥⌘M, which is Minimize All.
7. **Persistence** via `setFrameAutosaveName`, which macOS handles itself,
   plus which panels were open.

### Gate

Arrange the panels once, quit, relaunch, and the arrangement is still there.
Drag a panel near another and it snaps flush without a fight.

### Open question

Preset definitions. Candidates: *Inspect* (viewport large, moves narrow),
*Review* (moves wide for reading the program), *Present* (viewport only).
Jason to say what arrangements he actually reaches for.

---

## Then: inspection

Ranked by how much they change the work, not by effort.

1. **Compare two files.** Load two NC files and see them side by side, or one
   subtracted from the other. This is what turns "I changed something at
   home" into "here is what changed." Highest value in the list.
2. **Measure.** Click two points, get a distance. Click a feature, get its
   extents.
3. **Section cut.** A movable plane through the part, to see inside a pocket.
4. **Deviation colouring.** Needs a design reference to compare against, so
   it depends on the parked verification work.
5. **Batch contact sheet.** Point at a folder, get one image per file. The
   Python prototype already did this; it found the Panel C defect's whole
   five-month lifespan at a glance.

---

## Parked

The verification design in `spec/plan_phases_1_4.md` — severity model,
finding codes, manifest and report schemas, machine profiles, overlay
divergence checking. Parked deliberately: rules only catch what someone
thought to write a rule for, and the defects that actually bit this project
were ones nobody anticipated. The simulator surfaces those; rules can come
later, informed by what it shows.

Two open items from that design still stand as notes: uncut-material-as-fatal
collides with tabs, and the independence rule's wording needs to distinguish
geometry (NC only) from declared intent (manifest, treated as a claim).

Also parked: STL export from the app (the CLI does it), OpenSCAD/SCAD
integration, additional dialects, additional machines, signing and
notarisation, anything product-related.

---

## Division of labour

| | Jason | Claude Code | App Claude |
|---|---|---|---|
| Shop truth, fixtures | ✅ | | |
| Visual judgement of the result | ✅ | | |
| Swift, build, test | | ✅ | |
| Design review from the repo | | | ✅ |

Physical shop observation overrules simulation. If the tool and the part in
Jason's hand disagree, the part is right and the tool has a bug.

## Working rules

- **A verifier that has never fired is not a verifier.** The test suite
  caught a real section-parsing bug that had silently inflated Panel C from
  23 landmarks to 53. Keep tests that fire.
- **Return to source files, not conversation summaries.** The NC file is the
  source of truth.
- **Push, do not just commit.** A local commit is invisible to App Claude.
- **State the plan before writing code**, and confirm the understanding
  first.

## Risk register

| Risk | Mitigation |
|---|---|
| Rosetta removal ends the shop's current previsualisation before CutSim is trusted | Capture reference meshes from the existing tool while it still runs; they outlive it and make a useful cross-check |
| Offset geometry: comparing against design intent means reimplementing the generator's riskiest math | Deferred with the verification work; treat as a known hazard when it lands |
| Triangle load with a fine patch over a large base | Skip the base where the patch covers it, if it bites |
| Window-management work against undocumented AppKit behaviour | Scope limited to snapping and persistence; no docking tree |
| Scope creep toward a general CAM simulator | The scope limits above are the boundary |
