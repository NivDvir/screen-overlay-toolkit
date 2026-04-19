# BUILD_NOTES.md — GroundingKit

## TL;DR

```bash
git clone <this-repo>
cd GroundingKit-axvs-clone
bash build-app.sh
open GroundingKit.app
```

It should just work. The dependency graph handles everything.

## Why This Needs Notes

`Package.swift` pins the `mlx-swift-lm` dependency to a **fork at NivDvir/mlx-swift-lm** (commit `b4ea2216`), NOT the upstream `ml-explore/mlx-swift-lm@8c9dd63`. The fork carries the 9 MROPE bug fixes that make native Swift Qwen2.5-VL produce correct bounding boxes — the subject of the dev.to publication *"Building a Real-Time Screen Reader on macOS That Actually Works"*.

### If you prefer upstream

The fork exists specifically because upstream doesn't (yet) include these fixes.

- Fork branch: https://github.com/NivDvir/mlx-swift-lm/tree/fix/qwen25vl-mrope
- Upstream issue asking for fork work: https://github.com/ml-explore/mlx-swift-lm/issues/221
- A PR against upstream will track here: [TBD]

Once merged upstream, `Package.swift` will be repointed to `ml-explore` and the fork will be archived.

## Diagnostic: Is My Binary Broken?

Symptom of a broken build (built against pristine upstream, no MROPE fixes):
- VLM returns `need 2 panels, got 0` every cycle
- Log grep: `grep "got 0" /tmp/ccsv_overlay.log | wc -l` → many
- Panel bounds never lock: `grep "initial bounds" /tmp/ccsv_overlay.log | wc -l` → zero

Binary diagnostic:

```bash
nm GroundingKit.app/Contents/MacOS/GroundingKitAgent | grep -c ropeDelta
# 0  = broken (missing MROPE fixes)
# 20+ = correct (MROPE fixes present)
```

## Incident 2026-04-19

Full root-cause investigation recorded in this document's prior revision (see git history). The summary:

- The original GhostOverlay project kept the MROPE fixes as **uncommitted working-tree modifications** in `.build/checkouts/mlx-swift-lm/Libraries/MLXVLM/Models/Qwen25VL.swift` (+410 lines, -41 lines).
- Any fresh SPM resolution of `mlx-swift-lm@8c9dd63` would silently produce a binary missing those fixes — the VLM then hallucinated bounding box coordinates.
- This session: forked `ml-explore/mlx-swift-lm` → `NivDvir/mlx-swift-lm`, committed the fixes on branch `fix/qwen25vl-mrope` (commit `b4ea2216`), repointed GroundingKit's `Package.swift` at the fork's pinned revision.
- Consumers cloning this repo now get a working build automatically.

## Upstreaming Plan

1. ✅ Fork created, patch committed, GroundingKit pinned to fork
2. ⏳ Open PR against `ml-explore/mlx-swift-lm` referencing issue #221 and the dev.to publication
3. ⏳ Once merged (or if maintainer requests smaller PRs, split the commit), repoint Package.swift back to upstream

If the upstream maintainers decline, the fork is maintained indefinitely. `fix/qwen25vl-mrope` branch on the fork is always rebaseable onto newer `main` from upstream.
