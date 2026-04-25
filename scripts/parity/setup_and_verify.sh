#!/bin/bash
# Canonical bootstrap-and-verify for the Qwen2.5-VL Swift parity harness.
#
# This is the ONLY sanctioned way to set up a parity-test clone. It:
#   1. Fresh-clones ml-explore/mlx-swift-lm at the pinned commit
#   2. Applies patches/mlx-swift-lm-mrope-fixes.patch
#   3. Generates the reproducer's Package.swift from the template
#   4. Builds the reproducer with xcodebuild
#   5. Runs the reproducer on every canonical image
#   6. Runs the strict ≤2 px gate against canonical_baselines.json
#
# Aborts loudly if any step fails. If the gate fails, the patch is incomplete
# or upstream changed semantics — investigate before doing any other parity work.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PARITY_DIR="$REPO_ROOT/scripts/parity"
PATCH_FILE="$REPO_ROOT/patches/mlx-swift-lm-mrope-fixes.patch"
PINNED_COMMIT="8c9dd6391139242261bcf27d253c326f9cf2d567"
UPSTREAM_URL="https://github.com/ml-explore/mlx-swift-lm.git"

WORKDIR="${PARITY_WORKDIR:-/tmp/parity-harness}"
CLONE_DIR="$WORKDIR/mlx-swift-lm"
REPRO_DIR="$WORKDIR/reproducer"
DD_DIR="$WORKDIR/dd"
BINARY="$DD_DIR/Build/Products/Release/VLMParityFinding"

echo "▶ Parity harness root: $WORKDIR"
echo "▶ Pinned upstream:    $PINNED_COMMIT"
echo "▶ Patch:              $PATCH_FILE"
echo

# --- Step 1: fresh clone at pinned commit ----------------------------------
if [ ! -d "$CLONE_DIR/.git" ]; then
    echo "▶ Cloning upstream..."
    rm -rf "$CLONE_DIR"
    mkdir -p "$WORKDIR"
    git clone --quiet "$UPSTREAM_URL" "$CLONE_DIR"
fi
cd "$CLONE_DIR"
git fetch --quiet origin
git checkout --quiet "$PINNED_COMMIT"
git reset --hard --quiet "$PINNED_COMMIT"

# --- Step 2: apply patch ---------------------------------------------------
echo "▶ Applying patch..."
if ! git apply --check "$PATCH_FILE" 2>/dev/null; then
    echo "❌ Patch does not apply cleanly to $PINNED_COMMIT."
    echo "   Either upstream moved or the patch is for a different commit."
    git apply --check "$PATCH_FILE" 2>&1 | head -30
    exit 1
fi
git apply "$PATCH_FILE"

# Sanity check: the chat-template image-first fix must be present
if ! grep -q 'message.images.map { _ in \["type": "image"\] }' \
        Libraries/MLXVLM/Models/Qwen2VL.swift; then
    echo "❌ Patch applied but Qwen2VL.swift is missing the image-first chat-template fix."
    echo "   The patch file is incomplete — re-derive from production GhostOverlay's"
    echo "   .build/checkouts/mlx-swift-lm/ working tree."
    exit 1
fi
echo "  ✓ image-first chat-template fix present"

# --- Step 3: stage reproducer ----------------------------------------------
echo "▶ Staging reproducer..."
mkdir -p "$REPRO_DIR/Sources"
cp "$PARITY_DIR/reproducer/Sources/app.swift" "$REPRO_DIR/Sources/app.swift"
sed "s|__MLX_SWIFT_LM_PATH__|$CLONE_DIR|g" \
    "$PARITY_DIR/reproducer/Package.swift.template" > "$REPRO_DIR/Package.swift"

# --- Step 4: build with xcodebuild (NOT swift build — Metal kernels) -------
echo "▶ Building reproducer (xcodebuild, may take a few minutes first time)..."
cd "$REPRO_DIR"
if ! xcodebuild -scheme VLMParityFinding -configuration Release \
        -destination 'platform=macOS' -derivedDataPath "$DD_DIR" \
        build 2>&1 | tail -3 | grep -q "BUILD SUCCEEDED"; then
    echo "❌ xcodebuild failed."
    exit 1
fi
[ -x "$BINARY" ] || { echo "❌ binary not produced at $BINARY"; exit 1; }

# --- Step 5/6: run reproducer on every canonical image + strict gate -------
echo "▶ Running strict ≤2 px gate..."
echo
/opt/homebrew/bin/python3 "$PARITY_DIR/strict_2px_gate.py" \
    --binary "$BINARY" \
    --baselines "$PARITY_DIR/canonical_baselines.json" \
    --repo-root "$HOME/dev"
