#!/usr/bin/env python3
"""Tiny helper: resize+normalize a screenshot for VLM. No model loaded.
Usage: python3 vlm_resize_helper.py /tmp/input.png /tmp/output.raw 1260 812
Outputs raw float32 CHW tensor [1,3,H,W] to output path.
Takes ~50ms, no GPU, no model."""
import sys, numpy as np
from PIL import Image

img = Image.open(sys.argv[1])
tw, th = int(sys.argv[3]), int(sys.argv[4])
out = sys.argv[2]

resized = img.resize((tw, th), Image.LANCZOS).convert('RGB')
arr = np.array(resized, dtype=np.float32)

mean = np.array([0.48145466, 0.4578275, 0.40821073], dtype=np.float32)
std = np.array([0.26862954, 0.26130258, 0.27577711], dtype=np.float32)
norm = (arr / 255.0 - mean) / std

chw = np.ascontiguousarray(np.transpose(norm, (2, 0, 1))[np.newaxis, :])
chw.tofile(out)
