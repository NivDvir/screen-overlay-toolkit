#!/usr/bin/env python3
"""
Persistent Qwen2.5-VL panel detection server.
Loads the model ONCE, then accepts screenshot paths via stdin.
Each input line: path to screenshot PNG
Each output line: JSON with panel bounds

Usage:
  python3 panel_detector_server.py   # starts server, reads stdin
  echo "/tmp/screenshot.png" | python3 panel_detector_server.py  # one-shot
"""

import sys, json, time, gc
from PIL import Image

MODEL_ID = "mlx-community/Qwen2.5-VL-7B-Instruct-4bit"  # already downloaded, proven accurate
RETINA_SCALE = 2.0
MAX_IMAGE_SIZE = 1280

# Load model once at startup
from mlx_vlm import apply_chat_template, generate, load
from mlx_vlm.utils import load_config

print("LOADING", file=sys.stderr, flush=True)
start = time.time()
model, processor = load(MODEL_ID)
config = load_config(MODEL_ID)
load_time = time.time() - start
print(f"READY in {load_time:.1f}s", file=sys.stderr, flush=True)

# Signal ready to parent process
print("READY", flush=True)

def get_chrome_bounds():
    """Get Chrome window bounds via AppleScript for Y-axis correction."""
    import subprocess
    try:
        result = subprocess.run(
            ["osascript", "-e", 'tell application "Google Chrome" to get bounds of front window'],
            capture_output=True, text=True, timeout=2
        )
        parts = result.stdout.strip().split(", ")
        if len(parts) == 4:
            return [int(p) for p in parts]
    except:
        pass
    return None

def detect_panels(image_path):
    """Detect panels in a screenshot, return JSON string."""
    try:
        chrome_bounds = get_chrome_bounds()
        if chrome_bounds:
            print(f"Chrome bounds: {chrome_bounds}", file=sys.stderr, flush=True)
        image = Image.open(image_path)
        orig_w, orig_h = image.size

        # Resize to max 1280 (multiple of 28) for fast inference
        ratio = MAX_IMAGE_SIZE / max(image.size)
        new_w = int(image.size[0] * ratio) // 28 * 28
        new_h = int(image.size[1] * ratio) // 28 * 28
        image_resized = image.resize((new_w, new_h), Image.LANCZOS)
        print(f"Image: {orig_w}x{orig_h} → {new_w}x{new_h}", file=sys.stderr, flush=True)

        # Run grounding
        prompt = "Detect the problem description panel on the left and the code editor panel on the right. Output bbox coordinates in JSON format."
        formatted = apply_chat_template(processor, config, prompt, num_images=1)

        start = time.time()
        resp = generate(model, processor, formatted, image_resized, max_tokens=300, verbose=False)
        text = resp.text if hasattr(resp, 'text') else str(resp)
        elapsed = time.time() - start

        print(f"Inference: {elapsed:.1f}s", file=sys.stderr, flush=True)

        # Parse bboxes — strip markdown fences if present
        import re
        cleaned = text.replace("```json", "").replace("```", "").strip()
        json_match = re.search(r'\[.*\]', cleaned, re.DOTALL)
        if not json_match:
            return json.dumps({"error": f"no JSON in response: {text[:100]}"})

        bboxes = json.loads(json_match.group())

        # Convert model coords → logical screen coords
        scale_x = orig_w / new_w
        scale_y = orig_h / new_h

        question = None
        editor = None

        for item in bboxes:
            bbox = item.get("bbox_2d", [0, 0, 0, 0])
            label = item.get("label", "").lower()

            x1 = bbox[0] * scale_x / RETINA_SCALE
            y1 = bbox[1] * scale_y / RETINA_SCALE
            x2 = bbox[2] * scale_x / RETINA_SCALE
            y2 = bbox[3] * scale_y / RETINA_SCALE

            # Clip to Chrome window bounds
            if chrome_bounds:
                cx, cy, cr, cb = chrome_bounds
                x1 = max(x1, cx)
                y1 = max(y1, cy)
                x2 = min(x2, cr)
                y2 = min(y2, cb)

            panel = {"x": round(x1), "y": round(y1),
                     "width": round(x2 - x1), "height": round(y2 - y1)}

            if any(k in label for k in ["problem", "description", "left", "question"]):
                question = panel
                question["title"] = "Detected"
                question["description"] = ""
            elif any(k in label for k in ["editor", "code", "right"]):
                editor = panel
                editor["language"] = "java"
                editor["currentCode"] = ""
                editor["lineHeight"] = 21
                editor["firstLineY"] = round(y1) + 20

        if not question or not editor:
            return json.dumps({"error": f"classification failed, got {len(bboxes)} panels"})

        result = {
            "platform": "detected",
            "questionPanel": question,
            "editorPanel": editor,
            "solution": {"lines": []}
        }

        # Free image memory
        del image, image_resized
        gc.collect()

        return json.dumps(result)

    except Exception as e:
        return json.dumps({"error": str(e)})


# Main loop: read paths from stdin, write JSON to stdout
for line in sys.stdin:
    path = line.strip()
    if not path:
        continue
    if path == "QUIT":
        break

    print(f"Processing: {path}", file=sys.stderr, flush=True)
    result = detect_panels(path)
    print(result, flush=True)  # JSON output to stdout
    print(f"Done", file=sys.stderr, flush=True)

print("Server shutting down", file=sys.stderr, flush=True)
