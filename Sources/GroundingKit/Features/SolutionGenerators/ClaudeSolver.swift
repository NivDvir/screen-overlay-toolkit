import Foundation

/// Solves MCQ questions using a SINGLE persistent Claude CLI session.
/// First call opens the session with test context. Subsequent calls resume it.
/// Uses Claude Max subscription — zero extra API cost.

enum ClaudeSolver {

    /// Path to the Claude CLI. Resolves via PATH by default.
    /// Set `CLAUDE_CLI_PATH` env var to override (e.g. `/opt/homebrew/bin/claude` or `~/.local/bin/claude`).
    private static let claudePath: String = {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CLI_PATH"],
           !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        // Fallback: assume claude is on PATH
        return "claude"
    }()
    private static var sessionStarted = false
    private static var questionCount = 0

    /// Ask Claude to provide a complete coding solution. Returns code text or nil.
    /// Runs synchronously (call from background queue).
    /// Reader-mode summarizer — produces a compact bullet summary of long-form reading content.
    /// Used by reader mode (Wikipedia, arXiv, documentation pages).
    public static func summarize(content: String) -> String? {
        questionCount += 1
        let qNum = questionCount

        let prompt: String
        if !sessionStarted {
            sessionStarted = true
            prompt = """
            You are helping a reader skim long-form content captured from their own screen — an article, a paper, documentation, or similar.
            Reply with a compact summary in EXACTLY this format:
             • one-line bullet
             • one-line bullet
             • one-line bullet
             • ...

            5–8 bullets, each 8–14 words, each stating a concrete claim or fact from the content. No preamble, no sign-off, no markdown headers. Use '• ' (U+2022 + space) as the marker for each bullet.

            Content:
            \(content)
            """
        } else {
            prompt = """
            Produce a 5–8 bullet compact summary of the following content. Same format as before: '• ' markers, 8–14 words per bullet, factual.

            Content:
            \(content)
            """
        }

        NSLog("ClaudeSummary: sending Q%d (%d chars)", qNum, content.count)
        guard let output = runClaude(prompt: prompt, resume: qNum > 1) else { return nil }
        let summary = output.trimmingCharacters(in: .whitespacesAndNewlines)
        NSLog("ClaudeSummary: Q%d got %d chars", qNum, summary.count)
        return summary.isEmpty ? nil : summary
    }

    static func solveCoding(question: String, editorCode: String) -> String? {
        questionCount += 1
        let qNum = questionCount

        let prompt: String
        if !sessionStarted {
            sessionStarted = true
            prompt = """
            You are assisting a programmer who is writing code in a code editor.
            I will send you the problem description and the current editor contents.
            Reply with ONLY the complete solution code — all imports, full class or module, every line.
            No explanations, no markdown fencing, no comments about your approach.

            Problem:
            \(question)

            Current editor code:
            \(editorCode)
            """
        } else {
            prompt = """
            Coding problem:
            \(question)

            Current editor:
            \(editorCode)

            Reply with ONLY the complete solution code. No explanations, no markdown.
            """
        }

        NSLog("ClaudeCoding: sending Q%d (%d chars question, %d chars editor)",
              qNum, question.count, editorCode.count)

        guard let output = runClaude(prompt: prompt, resume: qNum > 1) else { return nil }
        let code = output.trimmingCharacters(in: .whitespacesAndNewlines)
        NSLog("ClaudeCoding: Q%d got %d chars of code", qNum, code.count)
        return code.isEmpty ? nil : code
    }

    /// Ask Claude to solve an MCQ question. Returns MCQAnswer or nil on failure.
    /// Runs synchronously (call from background queue).
    /// choiceHint tells Claude whether single or multiple answers are expected.
    static func solve(question: String, options: String, choiceHint: String = "") -> MCQAnswer? {
        questionCount += 1
        let qNum = questionCount

        let hint = choiceHint.isEmpty ? "" : "\n\(choiceHint)\n"

        // Put format instruction AFTER the question — last thing Claude reads.
        // This is a separate MCQ prompt, NOT mixed with coding questions.
        let prompt: String
        if !sessionStarted {
            sessionStarted = true
            prompt = """
            This is a MULTIPLE CHOICE test. I will give you questions with numbered options.
            \(hint)

            Question:
            \(question)

            \(options)

            ANSWER FORMAT: Reply with ONLY the option number(s). Example: 2 or 1, 3
            No explanations, no code, no text. Just the number(s).
            """
        } else {
            prompt = """
            \(hint)

            Question:
            \(question)

            \(options)

            ANSWER: Reply with ONLY the number(s).
            """
        }

        NSLog("ClaudeMCQ: sending Q%d (%d chars) session=%@", qNum, question.count, sessionStarted ? "resumed" : "new")
        // Debug: log first 200 chars of question and options so we can verify content
        NSLog("ClaudeMCQ: Q%d question: %@", qNum, String(question.prefix(200)))
        NSLog("ClaudeMCQ: Q%d options: %@", qNum, String(options.prefix(200)))

        guard let output = runClaude(prompt: prompt, resume: qNum > 1) else { return nil }
        let rawResponse = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = rawResponse
        var indices: [Int] = []

        // Strategy 1: Extract numbers (1-based) from response
        let numbers = cleaned
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .filter { !$0.isEmpty }
            .compactMap { Int($0) }
            .filter { $0 >= 1 && $0 <= 30 }

        let shortResponse = cleaned.count <= 5
        if shortResponse && !numbers.isEmpty {
            indices = Array(Set(numbers.map { $0 - 1 })).sorted()
        } else if !numbers.isEmpty {
            let unique = Array(Set(numbers)).sorted()
            indices = unique.map { $0 - 1 }
            NSLog("ClaudeMCQ: extracted %d unique numbers from explanation: %@", unique.count, unique.map(String.init).joined(separator: ","))
        }

        // Strategy 2: If no numbers found, try letter answers (A/B/C/D)
        if indices.isEmpty {
            let letterMap: [Character: Int] = ["A": 0, "B": 1, "C": 2, "D": 3, "E": 4, "F": 5]
            let upperCleaned = cleaned.uppercased()
            for (letter, idx) in letterMap {
                if upperCleaned.hasPrefix(String(letter)) && cleaned.count <= 3 {
                    indices = [idx]
                    NSLog("ClaudeMCQ: parsed letter answer '%@' → index %d", cleaned, idx)
                    break
                }
            }
        }

        // Strategy 3: If still nothing, try matching against option text
        // Claude sometimes responds with the option text (e.g., "HAVING" instead of "1")
        // Filter out UI chrome ("Finish Test", "Answers", timestamps, etc.) and cap at 6 options max
        if indices.isEmpty && !options.isEmpty {
            let uiChrome = ["finish test", "answers", "add files", "next", "previous", "submit"]
            let optionLines = options.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { line in
                    let lower = line.lowercased()
                    return line.count > 3 && !uiChrome.contains(where: { lower.contains($0) })
                        && !lower.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" || $0 == " " || $0 == "м" || $0 == "н" })
                }
            // Only check first 6 lines (real options, not chrome)
            let realOptions = Array(optionLines.prefix(6))
            let cleanedLower = cleaned.lowercased()
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespaces)
            for (i, opt) in realOptions.enumerated() {
                let optLower = opt.lowercased()
                if cleanedLower == optLower || optLower.contains(cleanedLower) || cleanedLower.contains(optLower) {
                    indices = [i]
                    NSLog("ClaudeMCQ: matched text response '%@' to option %d: '%@'", cleaned, i + 1, opt)
                    break
                }
            }
        }

        guard !indices.isEmpty else {
            NSLog("ClaudeMCQ: could not parse response: '%@'", cleaned.prefix(100).description)
            return nil
        }

        // Deduplicate and sort
        indices = Array(Set(indices)).sorted()

        let letters = indices.map { String(UnicodeScalar(65 + $0)!) }.joined(separator: ", ")
        let answerNums = indices.map { String($0 + 1) }.joined(separator: ", ")

        NSLog("ClaudeMCQ: Q%d answer = %@ (#%@) (raw: '%@')", qNum, letters, answerNums, rawResponse.prefix(50).description)
        return MCQAnswer(
            correctIndices: indices,
            letters: letters,
            numbers: answerNums,
            questionSent: question,
            optionsSent: options,
            rawResponse: rawResponse
        )
    }

    /// Run claude CLI. First call creates session, subsequent calls resume it.
    private static func runClaude(prompt: String, resume: Bool = false) -> String? {
        let process = Process()
        // If claudePath is absolute, execute directly. Otherwise resolve via PATH (/usr/bin/env).
        if claudePath.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: claudePath)
            var args = ["-p", "--model", "opus", "--no-session-persistence"]
            args.append(prompt)
            process.arguments = args
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            var args = [claudePath, "-p", "--model", "opus", "--no-session-persistence"]
            args.append(prompt)
            process.arguments = args
        }

        // Strip CLAUDE_CODE_* env vars that cause subprocess hangs
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        for key in env.keys where key.hasPrefix("CLAUDE_CODE_") {
            env.removeValue(forKey: key)
        }
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            NSLog("ClaudeMCQ: failed to launch: %@", error.localizedDescription)
            return nil
        }

        // Read pipe data concurrently to avoid pipe buffer deadlock
        var outputData = Data()
        let pipeGroup = DispatchGroup()
        pipeGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            pipeGroup.leave()
        }

        // Timeout: 180s — Opus needs time for coding solutions with long prompts
        let timeout: TimeInterval = 180
        let timeoutQueue = DispatchQueue(label: "claude-mcq-timeout")
        let timer = DispatchSource.makeTimerSource(queue: timeoutQueue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            if process.isRunning {
                NSLog("ClaudeMCQ: timeout after %.0fs — killing", timeout)
                process.terminate()
            }
        }
        timer.resume()

        process.waitUntilExit()
        timer.cancel()

        // Wait for pipe reader (should complete quickly since process exited)
        _ = pipeGroup.wait(timeout: .now() + 5)

        guard process.terminationStatus == 0 else {
            NSLog("ClaudeMCQ: exited with status %d", process.terminationStatus)
            return nil
        }

        return String(data: outputData, encoding: .utf8)
    }
}
