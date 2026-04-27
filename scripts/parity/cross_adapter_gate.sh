#!/usr/bin/env bash
# cross_adapter_gate.sh
#
# 3-way parity validation for the GroundingKit ecosystem:
#
#   SDK     : Grounder.ground(...)               — direct in-process call
#   MCP     : groundingkit-mcp                    — stdio JSON-RPC
#   Osaurus : libgroundingkit-osaurus.dylib       — dlopen + C ABI
#
# All three MUST return identical bbox coordinates for the same input.
# Pre-condition: groundingkit-mcp and groundingkit-osaurus are checked out
# as siblings of this repo (~/dev/groundingkit-mcp, ~/dev/groundingkit-osaurus).
#
# Usage:  bash scripts/parity/cross_adapter_gate.sh [TOLERANCE]
#         (default tolerance: 0 px — strict)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOLERANCE="${1:-0}"

# Canonical input — same one the existing strict gate uses
IMAGE="${REPO_ROOT}/_zero_px_test/leetcode_test.png"
[[ -f "$IMAGE" ]] || IMAGE="$(jq -r '.images[0].path' "${REPO_ROOT}/scripts/parity/canonical_baselines.json")"
PROMPT="$(jq -r '.prompt' "${REPO_ROOT}/scripts/parity/canonical_baselines.json")"

echo "═══════════════════════════════════════════════════════════════════"
echo "  Cross-adapter parity gate"
echo "═══════════════════════════════════════════════════════════════════"
echo "  Image:     ${IMAGE}"
echo "  Prompt:    $(echo "$PROMPT" | head -c 80)..."
echo "  Tolerance: ${TOLERANCE} px"
echo

OUT="${REPO_ROOT}/scripts/parity/cross_adapter/.out"
mkdir -p "$OUT"
SDK_OUT="$OUT/sdk.json"
MCP_OUT="$OUT/mcp.json"
OSA_OUT="$OUT/osa.json"
rm -f "$SDK_OUT" "$MCP_OUT" "$OSA_OUT"

# ──────────────────────────────────────────────────────────────────────
# 1. SDK probe — Grounder direct
# ──────────────────────────────────────────────────────────────────────
echo "→ [1/3] Building SDK probe (Grounder.ground direct)…"
PROBE_DIR="${REPO_ROOT}/scripts/parity/cross_adapter"
(
  cd "$PROBE_DIR"
  xcodebuild -scheme SDKProbe -configuration Release \
             -destination 'platform=macOS' build > "$OUT/sdk-build.log" 2>&1 \
    || { echo "  ✗ SDK probe build failed — see $OUT/sdk-build.log"; exit 1; }
)
SDK_BIN=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
              -name SDKProbe -type f -perm +111 2>/dev/null \
              | grep -v dSYM | head -1)
[[ -x "$SDK_BIN" ]] || { echo "  ✗ SDK probe binary not found"; exit 1; }
echo "  binary: ${SDK_BIN}"
echo "→ [1/3] Running SDK probe…"
"$SDK_BIN" "$IMAGE" "$PROMPT" > "$SDK_OUT" 2> "$OUT/sdk-stderr.log"
echo "  ✓ SDK probe done — $(jq '.regions | length' "$SDK_OUT") regions"
echo

# ──────────────────────────────────────────────────────────────────────
# 2. MCP probe — stdio JSON-RPC
# ──────────────────────────────────────────────────────────────────────
MCP_REPO="${MCP_REPO:-${HOME}/dev/groundingkit-mcp}"
[[ -d "$MCP_REPO" ]] || { echo "  ✗ groundingkit-mcp not found at $MCP_REPO — set MCP_REPO env var"; exit 1; }

echo "→ [2/3] Building groundingkit-mcp via xcodebuild…"
# NOTE: must be xcodebuild, NOT swift build. mlx-swift's Cmlx target relies on
# Xcode's auto Metal-compiler phase to produce default.metallib; swift build
# silently skips it and the binary crashes at first inference.
(
  cd "$MCP_REPO"
  xcodebuild -scheme groundingkit-mcp -configuration Release \
             -destination 'platform=macOS' build > "$OUT/mcp-build.log" 2>&1 \
    || { echo "  ✗ MCP build failed — see $OUT/mcp-build.log"; exit 1; }
)
MCP_BIN=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
              -path "*groundingkit-mcp-*" -name "groundingkit-mcp" -type f -perm +111 2>/dev/null \
              | grep -v dSYM | grep "Release/groundingkit-mcp$" | head -1)
[[ -x "$MCP_BIN" ]] || { echo "  ✗ MCP binary not found in DerivedData"; exit 1; }
echo "  binary: ${MCP_BIN}"
echo "→ [2/3] Running MCP probe (stdio JSON-RPC handshake → tools/call)…"

# Build the MCP JSON-RPC dialog
ESCAPED_PROMPT=$(printf '%s' "$PROMPT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read())[1:-1])')
MCP_DIALOG=$(cat <<EOF
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"cross-adapter-gate","version":"1"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ground_region","arguments":{"image_path":"${IMAGE}","prompt":"${ESCAPED_PROMPT}"}}}
EOF
)

# Send dialog, capture all responses, extract the tools/call result
( echo "$MCP_DIALOG"; sleep 60 ) | "$MCP_BIN" 2> "$OUT/mcp-stderr.log" > "$OUT/mcp-raw.jsonl" &
MCP_PID=$!
# Wait up to 4 min for response with id=2 to arrive
for i in {1..240}; do
    if grep -q '"id":2' "$OUT/mcp-raw.jsonl" 2>/dev/null; then break; fi
    sleep 1
done
kill -9 "$MCP_PID" 2>/dev/null || true
wait "$MCP_PID" 2>/dev/null || true

# Extract bbox JSON from the MCP tool response
python3 <<PYEOF
import json, sys, re
raw = open("$OUT/mcp-raw.jsonl").read()
# MCP responses are NDJSON-ish; find the line with "id":2
for line in raw.splitlines():
    line = line.strip()
    if not line.startswith("{"): continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    if d.get("id") == 2:
        # Tool result is in result.content[0].text — a JSON string (array or {regions:...})
        content = d.get("result", {}).get("content", [])
        if content and content[0].get("type") == "text":
            inner = json.loads(content[0]["text"])
            # Normalise: bare array → {"regions": [...]}
            if isinstance(inner, list):
                inner = {"regions": inner}
            json.dump(inner, open("$MCP_OUT", "w"), indent=2, sort_keys=True)
            sys.exit(0)
print("ERROR: no tools/call response with id=2 found", file=sys.stderr)
sys.exit(1)
PYEOF
echo "  ✓ MCP probe done — $(jq '.regions | length' "$MCP_OUT") regions"
echo

# ──────────────────────────────────────────────────────────────────────
# 3. Osaurus probe — dlopen + C ABI via host-harness batch mode
# ──────────────────────────────────────────────────────────────────────
OSA_REPO="${OSA_REPO:-${HOME}/dev/groundingkit-osaurus}"
[[ -d "$OSA_REPO" ]] || { echo "  ✗ groundingkit-osaurus not found at $OSA_REPO — set OSA_REPO env var"; exit 1; }

echo "→ [3/3] Building groundingkit-osaurus host-harness + dylib…"
(
  cd "$OSA_REPO"
  xcodebuild -scheme groundingkit-osaurus -configuration Release \
             -destination 'platform=macOS' build > "$OUT/osa-build.log" 2>&1 \
    || { echo "  ✗ Osaurus dylib build failed"; exit 1; }
  xcodebuild -scheme host-harness -configuration Release \
             -destination 'platform=macOS' build >> "$OUT/osa-build.log" 2>&1 \
    || { echo "  ✗ Osaurus harness build failed"; exit 1; }
)
OSA_HARNESS=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
                  -name host-harness -type f -perm +111 2>/dev/null \
                  | grep -v dSYM | head -1)
[[ -x "$OSA_HARNESS" ]] || { echo "  ✗ Osaurus harness binary not found"; exit 1; }
echo "  binary: ${OSA_HARNESS}"

# Sync dylib to .build/release where harness expects it
OSA_DYLIB=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
                -path "*groundingkit-osaurus*" -name "groundingkit-osaurus" -type f 2>/dev/null \
                | grep -i framework | head -1)
mkdir -p "$OSA_REPO/.build/release"
cp "$OSA_DYLIB" "$OSA_REPO/.build/release/libgroundingkit-osaurus.dylib"

echo "→ [3/3] Running Osaurus probe (dlopen + C ABI invoke)…"
(
  cd "$OSA_REPO"
  GK_HARNESS_BATCH="$IMAGE" GK_HARNESS_PROMPT="$PROMPT" \
    "$OSA_HARNESS" 2> "$OUT/osa-stderr.log" > "$OUT/osa-raw.log"
)
# Extract bbox JSON from __BATCH__ line
python3 <<PYEOF
import re, json
text = open("$OUT/osa-raw.log").read()
m = re.search(r'^__BATCH__ \S+ (\[.*\])$', text, re.MULTILINE)
if not m:
    raise SystemExit("ERROR: no __BATCH__ line in Osaurus output")
regions = json.loads(m.group(1))
json.dump({"regions": regions}, open("$OSA_OUT", "w"), indent=2, sort_keys=True)
PYEOF
echo "  ✓ Osaurus probe done — $(jq '.regions | length' "$OSA_OUT") regions"
echo

# ──────────────────────────────────────────────────────────────────────
# 4. Diff
# ──────────────────────────────────────────────────────────────────────
echo "→ Diff …"
python3 "${REPO_ROOT}/scripts/parity/cross_adapter/diff.py" \
    --sdk "$SDK_OUT" --mcp "$MCP_OUT" --osa "$OSA_OUT" \
    --tolerance "$TOLERANCE"
