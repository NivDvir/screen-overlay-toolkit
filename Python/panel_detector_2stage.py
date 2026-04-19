#!/usr/bin/env python3
"""
Two-stage VLM panel detector using hierarchical GUI grounding.

Stage 1: Detect Chrome browser window in full screenshot
Stage 2: Detect Q/E panels within cropped Chrome region

Usage: python3 panel_detector_2stage.py [screenshot_path]
"""

import sys, json, time, re
from pathlib import Path
from PIL import Image, ImageDraw

INPUT_PATH = sys.argv[1] if len(sys.argv) > 1 else "/tmp/native_vlm_input.png"
OUTPUT_PATH = "/tmp/superdeep_analysis.json"
MODEL_ID = "mlx-community/Qwen2.5-VL-7B-Instruct-4bit"
RETINA = 2.0


def resize_for_vlm(img, max_size=1280):
    ratio = max_size / max(img.size)
    if ratio >= 1.0:
        ratio = 1.0
    new_w = int(img.size[0] * ratio) // 28 * 28
    new_h = int(img.size[1] * ratio) // 28 * 28
    if new_w == 0 or new_h == 0:
        return img
    return img.resize((new_w, new_h), Image.LANCZOS)


def run_vlm(model, processor, config, image, prompt, max_tokens=200):
    from mlx_vlm import apply_chat_template, generate
    formatted = apply_chat_template(processor, config, prompt, num_images=1)
    start = time.time()
    resp = generate(model, processor, formatted, image, max_tokens=max_tokens, verbose=False)
    text = resp.text if hasattr(resp, 'text') else str(resp)
    elapsed = time.time() - start
    print(f"  VLM: {elapsed:.1f}s, {len(text)} chars", file=sys.stderr)
    print(f"  Raw: {text[:200]}", file=sys.stderr)
    match = re.search(r'\[.*\]', text, re.DOTALL)
    if not match:
        # Try single object
        match = re.search(r'\{.*\}', text, re.DOTALL)
        if match:
            return [json.loads(match.group())]
        return []
    return json.loads(match.group())


# Load model
from mlx_vlm import load
from mlx_vlm.utils import load_config

start = time.time()
model, processor = load(MODEL_ID)
config = load_config(MODEL_ID)
print(f"Model loaded in {time.time()-start:.1f}s", file=sys.stderr)

# Load image
full_img = Image.open(INPUT_PATH)
orig_w, orig_h = full_img.size
print(f"Image: {orig_w}x{orig_h}", file=sys.stderr)

# ============================================================
# STAGE 1: Detect Chrome browser in full screenshot
# ============================================================
print("\n=== STAGE 1: Detect Chrome browser ===", file=sys.stderr)
full_resized = resize_for_vlm(full_img)
print(f"  Resized: {full_resized.size}", file=sys.stderr)

chrome_prompt = "Detect the web browser window and output its bbox_2d coordinates as a JSON array with one object."
chrome_results = run_vlm(model, processor, config, full_resized, chrome_prompt)

if not chrome_results:
    print("ERROR: Stage 1 failed - no Chrome bbox detected", file=sys.stderr)
    sys.exit(1)

chrome_bbox = chrome_results[0].get("bbox_2d", [0, 0, 0, 0])
print(f"  Chrome bbox (resized): {chrome_bbox}", file=sys.stderr)

# Map chrome bbox from resized coords to original pixel coords
s1_sx = orig_w / full_resized.size[0]
s1_sy = orig_h / full_resized.size[1]
crop_box = (
    int(chrome_bbox[0] * s1_sx),
    int(chrome_bbox[1] * s1_sy),
    int(chrome_bbox[2] * s1_sx),
    int(chrome_bbox[3] * s1_sy),
)
# Clamp to image bounds
crop_box = (
    max(0, crop_box[0]),
    max(0, crop_box[1]),
    min(orig_w, crop_box[2]),
    min(orig_h, crop_box[3]),
)
crop_w = crop_box[2] - crop_box[0]
crop_h = crop_box[3] - crop_box[1]
print(f"  Chrome crop (original px): {crop_box} = {crop_w}x{crop_h}", file=sys.stderr)

# Compare with AppleScript Chrome bounds
import subprocess
try:
    result = subprocess.run(
        ["osascript", "-e", 'tell application "Google Chrome" to get bounds of front window'],
        capture_output=True, text=True, timeout=2
    )
    if result.returncode == 0:
        ax_bounds = [int(p) for p in result.stdout.strip().split(", ")]
        # AppleScript returns logical coords [x1, y1, x2, y2]
        ax_retina = [int(v * RETINA) for v in ax_bounds]
        print(f"  AppleScript Chrome (logical): {ax_bounds}", file=sys.stderr)
        print(f"  AppleScript Chrome (retina px): {ax_retina}", file=sys.stderr)
        print(f"  Stage1 vs AX delta: x1={crop_box[0]-ax_retina[0]} y1={crop_box[1]-ax_retina[1]} x2={crop_box[2]-ax_retina[2]} y2={crop_box[3]-ax_retina[3]}", file=sys.stderr)
except Exception:
    pass

# Crop Chrome region
chrome_crop = full_img.crop(crop_box)
chrome_crop.save("/tmp/vlm_stage1_crop.png")

# ============================================================
# STAGE 2: Detect Q/E panels in cropped Chrome
# ============================================================
print("\n=== STAGE 2: Detect panels in Chrome ===", file=sys.stderr)
chrome_resized = resize_for_vlm(chrome_crop)
print(f"  Chrome crop resized: {chrome_resized.size}", file=sys.stderr)

panel_prompt = "Detect these two UI panels and output their bbox_2d coordinates as a JSON array:\n1. \"question\" - the problem description panel on the left\n2. \"editor\" - the code editor panel on the right"
panel_results = run_vlm(model, processor, config, chrome_resized, panel_prompt)

if len(panel_results) < 2:
    print(f"ERROR: Stage 2 found {len(panel_results)} panels, need 2", file=sys.stderr)
    sys.exit(1)

# Map Stage 2 bboxes back to full-image logical screen coords
s2_sx = chrome_crop.width / chrome_resized.size[0]
s2_sy = chrome_crop.height / chrome_resized.size[1]

question = None
editor = None

for item in panel_results:
    bbox = item.get("bbox_2d", [0, 0, 0, 0])
    label = item.get("label", "").lower()

    # Stage 2 (cropped coords) -> original pixel coords -> logical screen coords
    px1 = bbox[0] * s2_sx + crop_box[0]
    py1 = bbox[1] * s2_sy + crop_box[1]
    px2 = bbox[2] * s2_sx + crop_box[0]
    py2 = bbox[3] * s2_sy + crop_box[1]

    x1 = px1 / RETINA
    y1 = py1 / RETINA
    x2 = px2 / RETINA
    y2 = py2 / RETINA

    panel = {"x": round(x1), "y": round(y1), "width": round(x2 - x1), "height": round(y2 - y1)}
    print(f"  {label}: bbox_2d={bbox} -> screen ({panel['x']},{panel['y']}) {panel['width']}x{panel['height']}", file=sys.stderr)

    if "problem" in label or "description" in label or "left" in label or "question" in label:
        question = panel
        question["title"] = "Detected Question Panel"
        question["description"] = ""
    elif "editor" in label or "code" in label or "right" in label:
        editor = panel
        editor["language"] = "java"
        editor["currentCode"] = ""
        editor["lineHeight"] = 21
        editor["firstLineY"] = round(y1) + 20

if not question or not editor:
    print(f"ERROR: Couldn't classify panels", file=sys.stderr)
    sys.exit(1)

# Write output
result = {
    "platform": "detected_2stage",
    "questionPanel": question,
    "editorPanel": editor,
    "solution": {"lines": []}
}

with open(OUTPUT_PATH, "w") as f:
    json.dump(result, f, indent=2)

print(f"\n=== RESULT ===", file=sys.stderr)
print(f"Q: ({question['x']},{question['y']}) {question['width']}x{question['height']}", file=sys.stderr)
print(f"E: ({editor['x']},{editor['y']}) {editor['width']}x{editor['height']}", file=sys.stderr)

# Draw annotated image for visual verification
annotated = full_img.copy()
draw = ImageDraw.Draw(annotated)
# Chrome box (red)
draw.rectangle(crop_box, outline='red', width=4)
# Question (blue) and Editor (green) in original pixel coords
for item in panel_results:
    bbox = item.get("bbox_2d", [0, 0, 0, 0])
    label = item.get("label", "").lower()
    px1 = int(bbox[0] * s2_sx + crop_box[0])
    py1 = int(bbox[1] * s2_sy + crop_box[1])
    px2 = int(bbox[2] * s2_sx + crop_box[0])
    py2 = int(bbox[3] * s2_sy + crop_box[1])
    color = 'blue' if any(k in label for k in ['question', 'problem', 'left']) else 'green'
    draw.rectangle([px1, py1, px2, py2], outline=color, width=6)

annotated.save("/tmp/vlm_2stage_result.png")
print(f"Annotated image: /tmp/vlm_2stage_result.png", file=sys.stderr)
print(f"Written to {OUTPUT_PATH}", file=sys.stderr)
