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

## Incident 2026-04-25 — 10th MROPE bug, hidden by loose gate

**What happened.** While preparing PR #222 split, a forensic re-measurement found Swift output drifting 9 px from the Python reference on the canonical LeetCode image — despite the published "≤2 px" parity claim. Root cause: `Qwen2VLMessageGenerator.generate(message:)` in `Libraries/MLXVLM/Models/Qwen2VL.swift` ordered content as `[text] + images`. HuggingFace's `apply_chat_template` for Qwen2.5-VL emits `<|vision_start|><|image_pad|><|vision_end|>{text}` (image first). The mismatched order shifted image-token positions, which shifted MROPE position-IDs for image patches, which shifted bbox output deterministically by +9/+8/+5 px on outer edges.

**Why it stayed hidden.** The previous parity gate (`_zero_px_test/accuracy_gate.sh`, TOLERANCE=30 px) was 15× looser than the publication's "≤2 px" claim. Real measured 9 px parity passed the gate silently; the gate stopped serving as a check on the publication.

**Fix.** Swap `Qwen2VLMessageGenerator` content order to `images + videos + [text]`. Result: bit-exact (0 px) on 2 of 3 canonical images, ≤2 px on the third — across all 8 edges of both panels.

**Permanent prevention** (this commit):

1. `patches/mlx-swift-lm-mrope-fixes.patch` now covers BOTH `Qwen25VL.swift` and `Qwen2VL.swift` (re-derived from production GhostOverlay's working tree). Previously only covered `Qwen25VL.swift` — the chat-template fix in `Qwen2VL.swift` was completely outside its scope.
2. `scripts/parity/canonical_baselines.json` — saved Python mlx-vlm reference output (deterministic, temperature=0) for every canonical test image. The publication's "≤2 px" number now lives in code, not in prose.
3. `scripts/parity/strict_2px_gate.py` — replaces the 30 px tolerance gate. Fails loudly if any edge of any panel exceeds 2 px against the saved reference.
4. `scripts/parity/setup_and_verify.sh` — the only sanctioned way to bootstrap a parity-test clone. Fresh-clones upstream at the pinned commit, applies the patch, builds with xcodebuild, runs the strict gate. Aborts if anything fails.
5. The setup script also greps the patched checkout for the literal `image-first` chat-template line and aborts before building if it's missing — so an incomplete patch can't sneak through to the build step.

**Lesson.** The parity gate must enforce the number you publish. A gate that's looser than the claim is not a gate.
