# Feature: SolutionGenerators

Optional LLM adapters for generating text over detected content regions — e.g., summarizing a paragraph the VLM identified, or answering a user question about what's on screen. The default reader-mode pipeline doesn't invoke these; they exist for consumers that want to layer LLM output on top of GroundingKit's grounding output.

Two adapters included:

1. **ClaudeSolver** — wraps the Claude CLI in `-p` mode. Requires Claude Max or Pro subscription, no API key needed beyond what the CLI manages itself.
2. **GeminiClient** — direct HTTP calls to the Gemini API. Requires `GEMINI_API_KEY` environment variable.

## Standalone use

```swift
// Claude CLI — summarize a paragraph extracted from the detected content region
if let summary = ClaudeSolver.solveCoding(
    question: "Summarize this paragraph in one sentence:",
    editorCode: extractedParagraphText
) {
    print(summary)
}

// Gemini — same shape, different backend
GeminiClient.shared.requestSolution(
    questionText: "Summarize the following paragraph",
    editorSkeleton: extractedParagraphText,
    retryCount: 3
) { result in
    switch result {
    case .success(let text): print(text)
    case .failure(let error): print("Gemini failed: \(error)")
    }
}
```

> The function signatures carry legacy names (`solveCoding`, `editorCode`, `editorSkeleton`) from an earlier version of the project. They take plain strings — you can pass any text, not just code.

## What's in this folder

| File | Purpose |
|------|---------|
| `ClaudeSolver.swift` | Claude CLI wrapper with optional session persistence across calls. |
| `GeminiClient.swift` | Gemini API client with retry and caching by input hash. API key from `GEMINI_API_KEY`. |
| `SolutionTypes.swift` | Shared data types used by both adapters. |

## Dependencies

- **External (ClaudeSolver):** Claude CLI installed. Path via `CLAUDE_CLI_PATH` env var or system PATH.
- **External (GeminiClient):** `URLSession` (built-in) + `GEMINI_API_KEY` env var.
- **Internal:** none.

## Notes

- Both adapters return `nil` / `.failure` on any error. Consumers should handle gracefully (don't assume output is available).
- `ClaudeSolver` via Claude Max has no per-call cost; `GeminiClient` uses metered API calls.
- Legacy helpers like `parseCodeToSolution` convert raw model output into structured line types — leftover from the earlier version of the project, safe to ignore for reader-mode consumers.
