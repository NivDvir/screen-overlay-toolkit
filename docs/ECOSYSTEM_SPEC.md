# GroundingKit Ecosystem Tool Spec — `ground_region`

GroundingKit is a Swift SDK first; ecosystem **adapters** wrap it for specific
agent runtimes (MCP, Osaurus, LangChain, HTTP, CLI). To keep AI agents able to
move between adapters without re-learning the surface, every adapter SHOULD
expose **one tool** with the contract below.

> **Status:** stable. Versioned together with the `Grounder` SDK in this repo.
> Reference implementations: [`groundingkit-mcp`](https://github.com/NivDvir/groundingkit-mcp),
> [`groundingkit-osaurus`](https://github.com/NivDvir/groundingkit-osaurus).

---

## Tool

| Field | Value |
|---|---|
| **Name** | `ground_region` |
| **Purpose** | Detect bounding-box regions in an image using natural-language prompts |
| **Backend** | `Grounder.ground(image:prompt:)` from this SDK (Qwen2.5-VL via mlx-swift-lm) |

## Input schema

```jsonc
{
  "type": "object",
  "properties": {
    "image_path": {
      "type": "string",
      "description": "Path to a local image file. Supported: PNG, JPEG, TIFF, HEIF. Adapters MAY accept relative paths (resolved against an adapter-specific working directory)."
    },
    "prompt": {
      "type": "string",
      "description": "Natural-language description of regions to detect. For best Qwen2.5-VL results, ask for `bbox_2d` JSON output explicitly and number each region."
    }
  },
  "required": ["image_path", "prompt"]
}
```

## Output schema

```jsonc
{
  "regions": [
    {
      "label": "string",   // the model-returned label for this region
      "x1": 123,           // top-left x in MODEL RESIZE space
      "y1": 145,           // top-left y
      "x2": 421,           // bottom-right x
      "y2": 626            // bottom-right y
    }
  ]
}
```

**Coordinate space:** the model returns bboxes in its **internal resize space**
(longest side capped at 1280 px, snapped to multiples of 28 — Qwen2.5-VL's patch
grid). Callers that need source-image pixels MUST scale by
`source_longest_side / 1280`.

**Empty results** are valid: `{"regions": []}`. The adapter SHOULD NOT throw
when the model finds nothing.

## Error schema

On failure, return JSON of shape:

```jsonc
{ "error": "human-readable message" }
```

Standardized error categories an adapter SHOULD distinguish:

| Category | Example message |
|---|---|
| Bad request | `"Invalid arguments: image_path is not a string"` |
| Path security | `"Path outside working directory: ..."` |
| File missing | `"Image not found: /path/to/file.png"` |
| Image decode | `"Could not decode image at /path — supported: PNG, JPEG, TIFF, HEIF"` |
| Model failure | `"ground_region failed: <Grounder error>"` |

## Behavioural requirements

1. **Lazy model load.** First call may take 25-40 s for cold MLX init. Subsequent calls in the same process are fast. Adapters SHOULD NOT block their `init`/startup on model load.
2. **Single Grounder instance per adapter process.** The `Grounder` actor handles serialization internally; do not construct multiple Grounders.
3. **Sync→async bridge** (for adapters with sync transports like C ABI): the calling thread MAY be the host's main thread. Adapters MUST NOT block the main thread in a way that prevents the main actor from draining (Grounder's progress callbacks hop to MainActor). See `groundingkit-osaurus`'s `Plugin.swift` for the reference runloop-drain pattern.
4. **No telemetry.** Adapters MUST NOT make outbound network calls beyond the (optional) one-time HuggingFace model download.

## Adapter manifest convention

Adapters SHOULD self-describe with a small machine-readable manifest at the
root of their repo or distribution:

```jsonc
{
  "name":          "groundingkit-<adapter-kind>",
  "version":       "0.1.0",
  "spec_version":  "1.0",                    // version of THIS document
  "tool":          "ground_region",
  "underlying_sdk": "screen-overlay-toolkit"  // this repo
}
```

`groundingkit-osaurus` ships `osaurus-plugin.json` with this shape.
`groundingkit-mcp` returns equivalent metadata via the MCP `Server.init(name:version:)` call.

## Compliance — current adapters

| Adapter | Tool name | Input schema | Output schema | Manifest |
|---|---|---|---|---|
| `groundingkit-mcp` | ✓ | ✓ | ✓ | via MCP `ListTools` |
| `groundingkit-osaurus` | ✓ | ✓ | ✓ | `osaurus-plugin.json` |

## Versioning

This spec uses **semantic versioning**. Breaking changes (renaming `ground_region`,
changing field names, changing coordinate space) require a major bump and a
migration window where adapters expose both old and new tool names.

| Spec version | Date | Notes |
|---|---|---|
| **1.0** | 2026-04-27 | Initial — `ground_region` as canonical tool. |

## Future tools (not yet specified)

Possible additions, intentionally **out of scope of v1**:

- `summarize_region` — crop + OCR + LLM-summarize a single bbox region
- `track_region` — re-ground the same region across N screenshots (scroll-tracking)
- `compare_screens` — bbox-aware diff between two screen captures

If you implement one of these in an adapter, please open an issue here so the
spec can be updated centrally rather than diverging.
