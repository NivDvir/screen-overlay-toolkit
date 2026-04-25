#!/usr/bin/env python3
"""Strict ≤2 px parity gate.

Runs the freshly-built Swift reproducer on every canonical image, parses the
bbox JSON the model emits, compares each edge to canonical_baselines.json, and
exits non-zero if any edge of any panel exceeds the allowed delta.

Replaces the previous TOLERANCE=30 / ≤15 px gates that hid the chat-template
bug for weeks.

Usage:
  strict_2px_gate.py --binary PATH/TO/VLMParityFinding [--baselines JSON]
"""
import argparse, json, os, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DEFAULT_BASELINES = ROOT / "canonical_baselines.json"

BBOX_RE = re.compile(r'"bbox_2d"\s*:\s*\[\s*([-\d.]+)\s*,\s*([-\d.]+)\s*,\s*([-\d.]+)\s*,\s*([-\d.]+)\s*\][^{}]*?"label"\s*:\s*"(\w+)"|"label"\s*:\s*"(\w+)"[^{}]*?"bbox_2d"\s*:\s*\[\s*([-\d.]+)\s*,\s*([-\d.]+)\s*,\s*([-\d.]+)\s*,\s*([-\d.]+)\s*\]', re.DOTALL)

def parse_bboxes(stdout: str) -> dict:
    out = {}
    for m in BBOX_RE.finditer(stdout):
        if m.group(5):  # bbox-then-label
            label = m.group(5)
            coords = [int(round(float(m.group(i)))) for i in range(1, 5)]
        else:           # label-then-bbox
            label = m.group(6)
            coords = [int(round(float(m.group(i)))) for i in range(7, 11)]
        out[label] = coords
    return out

def run_swift(binary: str, image: str, w: int, h: int) -> str:
    env = {**os.environ, "TEST_IMAGE": image, "RESIZE_W": str(w), "RESIZE_H": str(h)}
    r = subprocess.run([binary], env=env, capture_output=True, text=True, timeout=180)
    return r.stdout + r.stderr

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", required=True)
    ap.add_argument("--baselines", default=str(DEFAULT_BASELINES))
    ap.add_argument("--repo-root", default=str(Path.home() / "dev"),
                    help="prefix for relative image paths in baselines")
    args = ap.parse_args()

    spec = json.load(open(args.baselines))
    max_allowed = spec["max_edge_delta_allowed"]
    failed = []
    print(f"Strict gate: max edge delta ≤ {max_allowed} px on every edge of every panel")
    print(f"Reference: mlx-vlm {spec['mlx_vlm_version']} on {spec['model']}")
    print()

    for img in spec["images"]:
        ipath = img["path"] if img["path"].startswith("/") else str(Path(args.repo_root) / img["path"])
        if not os.path.exists(ipath):
            print(f"  SKIP {img['name']}: image not found at {ipath}")
            continue
        rw, rh = img["model_resize"]
        out = run_swift(args.binary, ipath, rw, rh)
        sw_panels = parse_bboxes(out)
        if not sw_panels:
            print(f"  FAIL {img['name']}: Swift output had no parseable bbox_2d")
            print("    --- raw output (last 600 chars) ---")
            print("    " + out[-600:].replace("\n", "\n    "))
            failed.append(img["name"])
            continue
        worst = 0
        rows = []
        for label, ref in img["panels"].items():
            sw = sw_panels.get(label)
            if sw is None:
                rows.append(f"    {label}: MISSING in Swift output")
                failed.append(f"{img['name']}/{label}")
                continue
            deltas = [abs(s - r) for s, r in zip(sw, ref)]
            mx = max(deltas)
            worst = max(worst, mx)
            verdict = "OK " if mx <= max_allowed else "BAD"
            rows.append(f"    {label}: ref={ref} swift={sw} Δ={deltas} max={mx} {verdict}")
            if mx > max_allowed:
                failed.append(f"{img['name']}/{label}")
        print(f"  {img['name']} ({rw}x{rh}): worst Δ = {worst} px")
        for r in rows: print(r)
        print()

    if failed:
        print(f"❌ STRICT GATE FAILED on: {', '.join(failed)}")
        print("This likely means the mlx-swift-lm patch is missing the chat-template")
        print("image-first fix or another MROPE fix has regressed. Check that all")
        print("hunks in patches/mlx-swift-lm-mrope-fixes.patch applied cleanly.")
        sys.exit(1)
    print("✅ STRICT GATE PASSED — all images within the configured delta on all edges")

if __name__ == "__main__":
    main()
