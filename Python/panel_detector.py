#!/usr/bin/env python3
"""
Panel detector using Qwen2.5-VL-7B via MLX.
Takes a screenshot, returns panel bounding boxes as JSON.

Usage: python3 panel_detector.py [screenshot_path]
  - Reads screenshot from path (default: /tmp/superdeep_input.png)
  - Writes results to /tmp/superdeep_analysis.json
"""

import sys, json, time
from pathlib import Path
from PIL import Image

INPUT_PATH = sys.argv[1] if len(sys.argv) > 1 else "/tmp/superdeep_input.png"
OUTPUT_PATH = "/tmp/superdeep_analysis.json"
MODEL_ID = "mlx-community/Qwen2.5-VL-7B-Instruct-4bit"

# Load model (cached after first run)
from mlx_vlm import apply_chat_template, generate, load
from mlx_vlm.utils import load_config

start = time.time()
model, processor = load(MODEL_ID)
config = load_config(MODEL_ID)
print(f"Model loaded in {time.time()-start:.1f}s", file=sys.stderr)

# Load and resize image
image = Image.open(INPUT_PATH)
orig_w, orig_h = image.size

max_size = 1280
ratio = max_size / max(image.size)
new_size = (int(image.size[0] * ratio) // 28 * 28, int(image.size[1] * ratio) // 28 * 28)
image_resized = image.resize(new_size, Image.LANCZOS)
resized_w, resized_h = image_resized.size

print(f"Image: {orig_w}x{orig_h} → {resized_w}x{resized_h}", file=sys.stderr)

# Run grounding
prompt = "Detect these two UI panels and output their bbox_2d coordinates as a JSON array:\n1. \"question\" - the problem description panel on the left\n2. \"editor\" - the code editor panel on the right"
formatted = apply_chat_template(processor, config, prompt, num_images=1)

start = time.time()
resp = generate(model, processor, formatted, image_resized, max_tokens=300, verbose=False)
text = resp.text if hasattr(resp, 'text') else str(resp)
print(f"Inference: {time.time()-start:.1f}s", file=sys.stderr)
print(f"Raw: {text[:300]}", file=sys.stderr)

# Parse bboxes from response
import re
# Extract JSON array from response
json_match = re.search(r'\[.*\]', text, re.DOTALL)
if not json_match:
    print("ERROR: No JSON array in response", file=sys.stderr)
    sys.exit(1)

bboxes = json.loads(json_match.group())

# Convert model coords → logical screen coords
scale_x = orig_w / resized_w
scale_y = orig_h / resized_h
retina = 2.0

question = None
editor = None

for item in bboxes:
    bbox = item.get("bbox_2d", [0,0,0,0])
    label = item.get("label", "").lower()

    # Model coords → original pixels → logical screen
    x1 = bbox[0] * scale_x / retina
    y1 = bbox[1] * scale_y / retina
    x2 = bbox[2] * scale_x / retina
    y2 = bbox[3] * scale_y / retina

    panel = {"x": round(x1), "y": round(y1), "width": round(x2-x1), "height": round(y2-y1)}

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
    print(f"ERROR: Found {len(bboxes)} panels but couldn't classify as question/editor", file=sys.stderr)
    sys.exit(1)

# Write output
result = {
    "platform": "detected",
    "questionPanel": question,
    "editorPanel": editor,
    "solution": {"lines": []}  # solution loaded separately
}

with open(OUTPUT_PATH, "w") as f:
    json.dump(result, f, indent=2)

print(f"Q: ({question['x']},{question['y']}) {question['width']}x{question['height']}", file=sys.stderr)
print(f"E: ({editor['x']},{editor['y']}) {editor['width']}x{editor['height']}", file=sys.stderr)
print(f"Written to {OUTPUT_PATH}", file=sys.stderr)
