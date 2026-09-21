# jhg-cutcheck — Development Plan, Phases 1–4

**Version:** 0.1 (draft)
**Date:** 2026-09-20
**Repo:** `github.com/JasonHunt3r/jhg-cutcheck` (public)
**Local:** `/Users/jasonhunter/Projects/jhg-cutcheck`
**Status:** Phase 0 complete. Phase 1 not started.

---

## What this is

A verification tool for generated G-code. It simulates the cut from the NC
file, compares the simulated result against the design intent the generator
was working from, checks it against the machine's limits, and writes a
machine-readable report that Claude Code can gate on automatically.

It is a sibling to ClaudeCAM, not part of it. ClaudeCAM generates; cutcheck
checks. The two talk through files in a repo.

## What this is not

- Not a CAMotics replacement. 3-axis, 2.5D, flat cutters, GRBL dialect only.
- Not a physics simulator. It cannot see bit deflection, workpiece movement,
  stock that was not flat, or feeds and speeds that burn rather than cut.
  Those are settled at the machine.
- Not a product. The question of whether anyone else would pay for this is
  deferred until the tool earns its place on one bench: this one.

The honest claim is "catches the errors that are visible in the file," not
"ensures the cut."

## Deferred to later phases

3D view, RealityKit, OpenSCAD/STL integration, the SwiftUI viewer, design-vs-cut
overlay in 3D, additional G-code dialects, additional machine profiles, code
signing and notarization, anything product-related.

---

## Severity model

Every finding carries one of three levels. This is the contract that makes the
loop automatic.

| Level | Meaning | Examples | CC behavior |
|---|---|---|---|
| **fatal** | Damages the part or the machine | Path outside travel envelope; cut into a keep-out region; plunge deeper than stock; gouge into the finished part boundary | Block. Do not present the file. |
| **warning** | Out of spec but survivable | Feed or RPM outside machine profile; deviation past the red band (>0.3mm); tab shorter than nominal | Surface to Jason, do not block |
| **note** | Informational | Run time estimate, pass count, cut length, plunge count | Log only |

A run passes if it has zero fatals. Warnings are for human judgment.

---

## Phase 1 — The spec

**Where:** this chat, drafted into `spec/`
**Who:** Claude drafts, Jason reviews
**Estimate:** one session

The formats are the contract between three parties: the generator (ClaudeCAM
via Claude Code), the checker (this tool), and design review (App Claude
reading the repo). If they drift, the copy-paste problem comes back. Nothing
gets built until they are settled.

### Deliverables

1. **`spec/manifest.schema.md`** — what a run submits.
   Sketch of fields:
   - run id, timestamp, generator name and version
   - NC file path and SHA256
   - design reference: SVG (or `.scad`, later) path and SHA256
   - stock: dimensions, thickness, material
   - tool: diameter, type, flutes
   - parameters actually used: BIT_R, offsets (EMG_OFFSET, POCKET_EXPAND),
     depth per pass, feeds, RPM
   - expected cut order
   - keep-out regions, if any
   - machine profile reference

2. **`spec/report.schema.md`** — what the checker returns.
   Sketch of fields:
   - run id and manifest SHA256 (so a report can never be read against the
     wrong job)
   - pass/fail, counts by severity
   - findings list: severity, code, message, location (line number in the NC
     file, XY position), measured vs expected
   - dimensional summary: overall extents, per-feature measurements
   - deviation summary in the existing color bands
     (green <0.1mm, yellow 0.1–0.2, orange 0.2–0.3, red >0.3)
   - run-time estimate, pass count, cut length
   - versions: checker version, machine profile version, OpenSCAD version
     where relevant

3. **`spec/machine-profile.schema.md`** plus **`profiles/ttc450-pro.json`**
   - travel envelope XYZ
   - max feed per axis, max plunge feed
   - spindle RPM range
   - soft limit behavior
   - units
   The TTC450 PRO is profile number one because it is the one that can be
   validated against real cut parts. Every other machine is a new file in
   `profiles/`, not a code change.

4. **`spec/folder-layout.md`** — run folder naming, what gets committed, what
   stays local (heightmaps are regenerable and do not go in git).

### Gate

Jason can take a real past job — one already cut — and express it as a manifest
by hand without hitting a missing field. If a field is missing, the schema is
wrong and gets fixed before Phase 2.

---

## Phase 2 — Python prototype

**Where:** this chat, into `prototype/`
**Who:** Claude writes, Jason supplies fixtures and measurements
**Estimate:** one to two sessions

This phase exists to make the difficulty estimate falsifiable early and cheaply.
If the core math does not work here, the cost is an hour, not weeks of Swift.

### Components

1. **GRBL parser.** G0/G1/G2/G3, G20/G21, G90/G91, G17, arc I/J offsets, feed
   and spindle words, tool changes ignored. Arcs are the known hazard: I/J sign
   conventions and swept area on curves are where prior geometry bugs have
   lived.
2. **Heightmap engine.** Stock as a grid of Z heights. Each move lowers every
   cell the cutter footprint passes over. Grid resolution configurable; default
   fine enough to resolve 0.1mm deviation on a panel.
3. **Checks.** Envelope, feeds, RPM, plunge depth, keep-out regions, deviation
   against the design SVG, tab heights, cut-order conformance.
4. **Report writer.** Emits the Phase 1 report schema.

### Gates — both must hold

- **Dimensional agreement.** Simulated measurements match Jason's calipers on a
  part that was cut correctly, within the tolerance the spec sets.
- **It fires.** The known-bad fixture is flagged, with the finding matching the
  defect that actually occurred. A verifier that has never fired is not a
  verifier — this is the single sharpest test available and it applies here.
- **No false fatals** on the good job.

### Fixtures required from Jason

- A good job: NC file, source SVG, parameters, caliper measurements
- A bad job: an archived NC file that cut wrong, plus what went wrong
- What "correct" meant in each case

---

## Phase 3 — Swift CLI

**Where:** Claude Code, on the Mac, into `sim/`
**Who:** Claude Code writes and builds; Python prototype is the oracle
**Estimate:** days of CC work

Port the Phase 2 core to a Swift package with a command-line front end. Same
inputs, same outputs, no GUI. Structured as a shared library plus a thin CLI so
the later viewer app can link the same code rather than reimplementing it.

This is the safest kind of work: translation against a reference implementation
that already agrees with physical measurements.

### Gate

On every fixture, the Swift CLI produces the same report as the Python
prototype — same findings, same measurements, same severities. Differences in
timing and formatting are allowed; differences in numbers are not.

### Notes

- Xcode is installed; verify `xcode-select -p` points at Xcode.app, not
  CommandLineTools.
- No Apple Developer account needed at this phase. Signing and notarization
  only matter when shipping to other people.

---

## Phase 4 — Watcher and Git automation

**Where:** Claude Code, into `sim/`
**Estimate:** fiddly; this is where plumbing time hides
**Risk:** highest of the four

Make the loop run without hands.

### Behavior

- Watch the runs folder. New run appears, check it, write the report.
- Pull before each run, commit and push after the report lands.
- Commit messages structured: run id, pass/fail, worst deviation. History reads
  as a shop log.
- Each run in its own folder with a unique id. Claude Code writes the inputs,
  the checker writes the outputs, and neither touches the other's files. This
  is how merge conflicts are avoided: by never writing to the same file, not by
  resolving cleverly.
- Uses the system git and the SSH key already configured. The tool stores no
  credentials.
- Committed: NC, manifest, report, overlay SVG. Not committed: heightmaps and
  other regenerable intermediates.

### Gate

Claude Code drops a run into the folder and the report appears in the repo,
pushed, with no human action. Then it is verified from a second location —
readable at the public raw URL from this chat.

### After Phase 4

The full value of the tool exists with no GUI at all. Everything after this
point is eyes and polish, and can be scheduled or dropped on its merits.

---

## Division of labor

| | Jason | Claude Code | App Claude |
|---|---|---|---|
| Fixtures and measurements | ✅ | | |
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
| Partial-depth passes and tabs complicate "how deep did this cut" | 2 | Handle explicitly in the heightmap model, not as an afterthought |
| Estimate optimism | all | Every phase ends in a gate that can fail cheaply; Phase 2 exists to test the estimate before Swift work begins |
| Plumbing time (watcher, git, permissions) | 4 | Individually boring, collectively a week — budget it |
| Scope creep toward a CAMotics clone | all | Deferred list above is the boundary |
