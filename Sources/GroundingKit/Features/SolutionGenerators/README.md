# Feature: SolutionGenerators

Pluggable backends for generating a solution (code / answer / text) given a question. Two backends included:

1. **ClaudeSolver** — uses the Claude CLI in `-p` mode (requires Claude Max subscription or Pro, no API key needed beyond what the CLI handles). Best for coding problems.
2. **GeminiClient** — Gemini API direct HTTP calls. Requires `GEMINI_API_KEY` environment variable.

## Standalone use

```swift
// Option A: Claude CLI (reads CLAUDE_CLI_PATH env var, or falls back to `claude` in PATH)
if let code = ClaudeSolver.solveCoding(
    question: "Given an array of integers, return two indices that sum to target",
    editorCode: "class Solution { public int[] twoSum(int[] nums, int target) { } }"
) {
    print(code)  // Complete solution, ready to type
}

// Option B: Gemini API
// (set GEMINI_API_KEY=... in your environment)
GeminiClient.shared.requestSolution(
    questionText: "Longest palindromic substring",
    editorSkeleton: "class Solution { public String longestPalindrome(String s) {} }",
    retryCount: 3
) { result in
    switch result {
    case .success(let code): print(code)
    case .failure(let error): print("Gemini failed: \(error)")
    }
}
```

## What's in this folder

| File | Purpose |
|------|---------|
| `ClaudeSolver.swift` | Claude CLI wrapper with session persistence (reuse context across multiple questions in one session). Includes both coding (`solveCoding`) and multiple-choice (`solve`) entry points. |
| `GeminiClient.swift` | Gemini API client with retry, caching by question hash. API key from `GEMINI_API_KEY` env var. |
| `SolutionTypes.swift` | Shared data types: `SolutionLine`, `MockSolution`, `LineAction`. Empty mock registry by default — populate for offline pre-canned answers. |

## Dependencies

- **External (ClaudeSolver):** Claude CLI installed. Path auto-detected via `CLAUDE_CLI_PATH` env var or system PATH lookup.
- **External (GeminiClient):** `URLSession` (built-in). `GEMINI_API_KEY` env var.
- **Internal:** none.

## Public API surface

- `ClaudeSolver.solveCoding(question:editorCode:) -> String?`
- `ClaudeSolver.solve(question:options:choiceHint:) -> MCQAnswer?`
- `GeminiClient.shared.requestSolution(...)` — closure-based
- `GeminiClient.parseCodeToSolution(code:questionText:) -> MockSolution` — convert raw code into typed `SolutionLine`s
- `SolutionLine`, `MockSolution`, `LineAction` — types

## Notes

- **ClaudeSolver session:** First call establishes a session with test context. Subsequent calls use the shorter prompt, carrying conversation state. Resets with `sessionStarted = false`.
- **Gemini I/O hints:** `promptIOHint` lets you inject platform-specific rules (e.g., "Use Scanner for Java stdin" or "The class must be named TestImpl").
- **Error handling:** both paths return `nil` / `.failure` on any error. Consumer should handle gracefully (don't assume solution is available).
- **Cost:** ClaudeSolver via Claude Max is unlimited. GeminiClient has per-request API cost.
