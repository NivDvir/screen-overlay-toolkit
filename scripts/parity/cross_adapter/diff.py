#!/usr/bin/env python3
"""3-way bbox JSON diff with per-coordinate deltas.

Reads the JSON outputs of the three adapter probes and asserts that each
returns the SAME set of bboxes. Tolerance defaults to 0 px (strict) but can
be relaxed via --tolerance N for deltas-allowed mode.

Usage:
    diff.py --sdk sdk.json --mcp mcp.json --osa osa.json [--tolerance N]

Output:
    Per-region table of (label, x1, y1, x2, y2) across the three paths.
    Highlights any cell that differs from the SDK reference.

Exit:
    0 = all paths match within tolerance
    1 = any path diverges
"""
import argparse
import json
import sys
from pathlib import Path


def load_regions(path: str) -> list[dict]:
    if not path or not Path(path).exists():
        return []
    raw = json.loads(Path(path).read_text())
    return raw.get("regions", [])


def fmt_bbox(r: dict) -> str:
    return f"{r['x1']:>5},{r['y1']:>5},{r['x2']:>5},{r['y2']:>5}"


def diff_coord(ref: int, val: int, tol: int) -> str:
    delta = abs(ref - val)
    if delta == 0:
        return f"{val:>5}"
    if delta <= tol:
        return f"\033[33m{val:>5}\033[0m"   # yellow within tolerance
    return f"\033[31m{val:>5}\033[0m"        # red over tolerance


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--sdk", required=True)
    p.add_argument("--mcp", required=True)
    p.add_argument("--osa", required=True)
    p.add_argument("--tolerance", type=int, default=0)
    args = p.parse_args()

    sdk = load_regions(args.sdk)
    mcp = load_regions(args.mcp)
    osa = load_regions(args.osa)

    if not sdk:
        print("✗ SDK probe produced no regions — cannot compare", file=sys.stderr)
        return 1
    if len(sdk) != len(mcp) or len(sdk) != len(osa):
        print(f"✗ Region count differs: SDK={len(sdk)}  MCP={len(mcp)}  Osaurus={len(osa)}",
              file=sys.stderr)
        return 1

    failed = False
    print()
    print(f"  {'#':>3} {'label':<24}  {'SDK (reference)':<31} | {'MCP':<31} | {'Osaurus':<31}")
    print(f"  {'─'*3} {'─'*24}  {'─'*31} | {'─'*31} | {'─'*31}")

    for i, ref_r in enumerate(sdk):
        mcp_r = mcp[i]
        osa_r = osa[i]
        # Region order should match — bboxes returned by the model have stable order
        sdk_str = fmt_bbox(ref_r)
        mcp_str = (
            f"{diff_coord(ref_r['x1'], mcp_r['x1'], args.tolerance)},"
            f"{diff_coord(ref_r['y1'], mcp_r['y1'], args.tolerance)},"
            f"{diff_coord(ref_r['x2'], mcp_r['x2'], args.tolerance)},"
            f"{diff_coord(ref_r['y2'], mcp_r['y2'], args.tolerance)}"
        )
        osa_str = (
            f"{diff_coord(ref_r['x1'], osa_r['x1'], args.tolerance)},"
            f"{diff_coord(ref_r['y1'], osa_r['y1'], args.tolerance)},"
            f"{diff_coord(ref_r['x2'], osa_r['x2'], args.tolerance)},"
            f"{diff_coord(ref_r['y2'], osa_r['y2'], args.tolerance)}"
        )
        label = (ref_r.get("label") or "")[:24]
        print(f"  {i+1:>3} {label:<24}  {sdk_str:<31} | {mcp_str:<31} | {osa_str:<31}")

        for k in ("x1", "y1", "x2", "y2"):
            if abs(ref_r[k] - mcp_r[k]) > args.tolerance:
                failed = True
            if abs(ref_r[k] - osa_r[k]) > args.tolerance:
                failed = True

    print()
    if failed:
        print(f"✗ Cross-adapter parity FAILED (tolerance ≤ {args.tolerance} px)")
        return 1
    print(f"✓ Cross-adapter parity PASSED — all 3 paths match within {args.tolerance} px")
    return 0


if __name__ == "__main__":
    sys.exit(main())
