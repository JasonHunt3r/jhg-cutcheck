# CLAUDE.md — jhg-cutcheck

Standing context for Claude Code sessions in this repo. Read this first.

---

## What this project is

**jhg-cutcheck** verifies generated G-code before it cuts material.

It simulates the cut from an NC file, compares the result against the design
intent the generator was working from, checks it against the machine's limits,
and writes a machine-readable report that Claude Code can gate on.

The loop it closes: ClaudeCAM generates a job → cutcheck checks it → the report
comes back → the generator is fixed, or the file is cleared for the shop. The
two sides talk through files in this repo, not through copy-paste.

## What it is NOT

- **Not a CAMotics replacement.** 3-axis, 2.5D, flat cutters, GRBL dialect only.
  Scope creep toward a general CAM simulator is the main thing to resist.
- **Not a physics simulator.** It cannot see bit deflection, workpiece movement,
  stock that was not flat, or feeds that burn rather than cut. Those are settled
  at the machine by Jason.
- **Not a product.** No signing, no notarization, no Apple Developer account, no
  other users. That question is deferred until the tool earns its place on this
  bench.

The honest claim is "catches the errors visible in the file," never "ensures
the cut."

---

## Relationship to ClaudeCAM

Two separate repos, siblings, not nested:

| | Repo | Origin | Role |
|---|---|---|---|
| `~/Projects/ClaudeCAM` | jhg-shop-docs | public docs library | generates G-code; holds shop standards and runbook |
| `~/Projects/jhg-cutcheck` | jhg-cutcheck | this repo | checks G-code |

They were deliberately kept separate: ClaudeCAM's origin is the public
documentation library pulled at session start, and nesting repos invites
submodule confusion.

**Naming collision to watch:** ClaudeCAM has `jobs/`. This repo uses `runs/`
for the same conceptual thing. They are not interchangeable. If a file's
provenance is unclear, do not guess which folder it came from — check.

The shop standards in jhg-shop-docs (`jhg_gcode_hygiene`, `jhg_shop_file_standards`,
the runbook) still govern G-code conventions. This repo does not restate them.

---

## Current state

Phase 0 complete: repo created, structure pushed, Xcode installed.
Phase 1 (spec) is next. **No code has been written yet, by design.**

Full plan: `spec/plan_phases_1_4.md`. That document is the reference for what
each phase delivers and what gate it must pass. Read it before proposing work.

Short version:

1. **Phase 1 — spec.** Four schemas: job manifest, report, machine profile,
   folder layout. Nothing is built until the formats are settled, because they
   are the contract between generator, checker, and design review.
2. **Phase 2 — Python prototype** in `prototype/`. GRBL parser, heightmap
   engine, checks, report writer. Exists to test the difficulty estimate
   cheaply before any Swift work.
3. **Phase 3 — Swift CLI** in `sim/`. Port with the Python as oracle. Shared
   library plus thin CLI, so a later viewer links the same code.
4. **Phase 4 — watcher and git automation.** Runs without hands.

3D views, OpenSCAD/STL, the SwiftUI app, extra dialects and extra machines are
all deferred past Phase 4.

---

## Repo layout

```
spec/        schemas and the phase plan
profiles/    machine profiles, one JSON per machine (TTC450 PRO first)
fixtures/    ground-truth jobs: NC + SVG + parameters + caliper measurements
prototype/   Python simulation core
sim/         Swift package (Phase 3+)
runs/        live run folders, one per run id
```

Committed: NC, manifest, report, overlay SVG.
Not committed: heightmaps and other regenerable intermediates, STL files
(OpenSCAD regenerates those from `.scad` source).

---

## How the core works

Stock is a grid of Z heights. Each move lowers every cell the cutter footprint
passes over. That is the whole engine, and it is machine-agnostic — geometry is
geometry regardless of whose gantry it is.

Machine-specific facts live in `profiles/*.json` as data: travel envelope, max
feeds, spindle RPM range, units. Adding a machine means adding a file, never
editing the simulator. If a machine fact is about to be hardcoded, that is a bug.

---

## Severity model

Every finding carries one level. This is the contract that makes the loop
automatic.

| Level | Meaning | Claude Code behavior |
|---|---|---|
| **fatal** | Damages part or machine: outside travel envelope, cut into keep-out, plunge deeper than stock, gouge into the finished boundary | **Block.** Do not present the file. |
| **warning** | Out of spec but survivable: feed or RPM outside profile, deviation past the red band | Surface to Jason, do not block |
| **note** | Informational: run time, pass count, cut length | Log only |

A run passes with zero fatals. Deviation bands follow existing JHG convention:
green <0.1mm, yellow 0.1–0.2, orange 0.2–0.3, red >0.3.

---

## Working rules

- **Physical shop observation overrules simulation.** If this tool and the part
  in Jason's hand disagree, the part is right and the tool has a bug. Never
  argue the reverse.
- **A verifier that has never fired is not a verifier.** Every check needs a
  fixture that makes it fire. Passing a file that was already good proves
  nothing.
- **Gates are pass/fail, not judgment calls.** Do not advance a phase because
  the work looks done. Phase 2 requires all three: dimensional agreement with
  calipers, correct firing on the known-bad fixture, and no false fatal on the
  good one.
- **Return to source files, not conversation summaries.** Relayed claims lose
  their derivation between sessions. The NC file is the source of truth.
- **Surgical changes.** Read the full relevant section before editing anything;
  verify output after each individual change, not in batches.
- **State the plan and confirm understanding before writing code.** Jason will
  correct direction directly; do not extend discussion once corrected.
- **No scope creep.** If a task is not in the current phase of
  `spec/plan_phases_1_4.md`, raise it rather than building it.

## Environment

- macOS on Apple silicon. Xcode installed.
- Git over SSH, key already configured. The tooling stores no credentials.
- No browser tools.
- Python for the prototype; existing pipeline libraries are PyClipper,
  svgpathtools, Shapely.
- OpenSCAD, when it becomes relevant in a later phase, must be a development
  snapshot — the 2021.01 stable release is Intel-only.
