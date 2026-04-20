import Foundation

/// Gemini 2.0 Flash API client for generating code solutions from problem text.
/// Uses URLSession (no external dependencies). Thread-safe via serial queue.

public class GeminiClient {

    public static let shared = GeminiClient()

    private let queue = DispatchQueue(label: "com.groundingkit.gemini")
    private let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"

    /// Cached responses keyed by a normalized hash of the question text
    private var cache: [String: MockSolution] = [:]

    /// Timestamps of recent API calls for rate limiting
    private var lastCallTime: Date = .distantPast

    /// Minimum interval between API calls (seconds)
    private let minInterval: TimeInterval = 30.0

    /// Whether a request is currently in flight
    private var inFlight = false

    /// Platform-specific I/O hint for Gemini prompt — set at startup
    public var promptIOHint: String = ""

    /// Gemini API key — set the `GEMINI_API_KEY` environment variable. If not set,
    /// the Gemini path is disabled (methods will return nil without attempting a request).
    private var apiKey: String? {
        let envKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ?? ""
        return envKey.isEmpty ? nil : envKey
    }

    /// Request a solution for the given question text.
    /// Returns cached result immediately if available.
    /// Otherwise fires an async API call and invokes the completion on the caller's queue.
    func requestSolution(
        questionText: String,
        completion: @escaping (MockSolution?) -> Void
    ) {
        let cacheKey = Self.cacheKey(for: questionText)

        // Check cache first (thread-safe)
        let cached: MockSolution? = queue.sync {
            return cache[cacheKey]
        }
        if let cached = cached {
            NSLog("GeminiClient: cache HIT for key %@", cacheKey.prefix(16).description)
            completion(cached)
            return
        }

        // Rate limit + dedup check
        let shouldProceed: Bool = queue.sync {
            if inFlight {
                NSLog("GeminiClient: request already in flight, skipping")
                return false
            }
            let elapsed = Date().timeIntervalSince(lastCallTime)
            if elapsed < minInterval {
                NSLog("GeminiClient: rate limited (%.0fs since last call, need %.0fs)", elapsed, minInterval)
                return false
            }
            inFlight = true
            lastCallTime = Date()
            return true
        }

        guard shouldProceed else {
            completion(nil)
            return
        }

        NSLog("GeminiClient: sending request (%d chars of question text)", questionText.count)

        let prompt = Self.buildPrompt(questionText: questionText, ioHint: self.promptIOHint)
        callAPI(prompt: prompt, retryCount: 0) { [weak self] result in
            guard let self = self else { return }

            self.queue.sync {
                self.inFlight = false
            }

            switch result {
            case .success(let codeText):
                let solution = Self.parseCodeToSolution(code: codeText, questionText: questionText)
                // Cache it
                self.queue.sync {
                    self.cache[cacheKey] = solution
                }
                NSLog("GeminiClient: SUCCESS — %d lines parsed", solution.lines.count)
                completion(solution)

            case .failure(let error):
                NSLog("GeminiClient: FAILED — %@", error.localizedDescription)
                completion(nil)
            }
        }
    }

    // MARK: - Prompt Construction

    static func buildPrompt(questionText: String, ioHint: String = "Use standard input/output if the problem requires it (Scanner for Java).") -> String {
        // Detect language from context clues
        let lower = questionText.lowercased()
        let language: String
        if lower.contains("spring boot") || lower.contains("springboot") || lower.contains("@restcontroller") {
            language = "Java (Spring Boot)"
        } else if lower.contains("react") || lower.contains("usestate") || lower.contains("jsx") || lower.contains("component") {
            language = "JavaScript (React)"
        } else if lower.contains("python") || lower.contains("def ") || lower.contains("print(") {
            language = "Python"
        } else {
            language = "Java"
        }

        return """
        You are a coding test solver. Given the following problem, provide ONLY the complete solution code.

        PROBLEM:
        \(questionText)

        RULES:
        1. Write the COMPLETE, compilable \(language) solution.
        2. Include ALL necessary imports.
        3. Include the full class and method signatures.
        4. Handle edge cases.
        5. \(ioHint)
        6. Output ONLY code — no explanations, no markdown fencing, no comments about the approach.
        7. Each line should be valid \(language) code or a blank line.
        """
    }

    // MARK: - API Call

    private func callAPI(
        prompt: String,
        retryCount: Int,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let key = apiKey else {
            NSLog("GeminiClient: GEMINI_API_KEY not set — skipping Gemini request")
            completion(.failure(GeminiError.invalidURL))
            return
        }
        guard let url = URL(string: "\(endpoint)?key=\(key)") else {
            completion(.failure(GeminiError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.1,
                "maxOutputTokens": 4096
            ]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(error))
            return
        }

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                if retryCount < 1 {
                    NSLog("GeminiClient: network error, retrying... (%@)", error.localizedDescription)
                    self.callAPI(prompt: prompt, retryCount: retryCount + 1, completion: completion)
                } else {
                    completion(.failure(error))
                }
                return
            }

            guard let data = data else {
                completion(.failure(GeminiError.noData))
                return
            }

            // Parse JSON response
            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completion(.failure(GeminiError.invalidJSON))
                    return
                }

                // Check for API error
                if let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    NSLog("GeminiClient: API error: %@", message)
                    completion(.failure(GeminiError.apiError(message)))
                    return
                }

                // Extract text from response
                guard let candidates = json["candidates"] as? [[String: Any]],
                      let first = candidates.first,
                      let content = first["content"] as? [String: Any],
                      let parts = content["parts"] as? [[String: Any]],
                      let text = parts.first?["text"] as? String else {
                    // Log the raw response for debugging
                    let rawStr = String(data: data, encoding: .utf8) ?? "<binary>"
                    NSLog("GeminiClient: unexpected response structure: %@", String(rawStr.prefix(500)))

                    if retryCount < 1 {
                        NSLog("GeminiClient: retrying...")
                        self.callAPI(prompt: prompt, retryCount: retryCount + 1, completion: completion)
                    } else {
                        completion(.failure(GeminiError.invalidJSON))
                    }
                    return
                }

                completion(.success(text))
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
    }

    // MARK: - Response Parsing

    /// Parse raw code text from Gemini into a MockSolution with line classifications.
    static func parseCodeToSolution(code: String, questionText: String) -> MockSolution {
        // Strip markdown code fences if present
        var cleaned = code
        // Remove ```java or ```python etc at the start
        if let fenceStart = cleaned.range(of: "```", options: .anchored) {
            // Find the end of the first line (the language tag line)
            if let newline = cleaned[fenceStart.upperBound...].firstIndex(of: "\n") {
                cleaned = String(cleaned[cleaned.index(after: newline)...])
            } else {
                cleaned = String(cleaned[fenceStart.upperBound...])
            }
        }
        // Remove trailing ```
        if let fenceEnd = cleaned.range(of: "```", options: [.backwards, .anchored]) {
            cleaned = String(cleaned[..<fenceEnd.lowerBound])
        }
        // Also handle ``` not at strict end — trim trailing whitespace first
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasSuffix("```") {
            cleaned = String(cleaned.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let rawLines = cleaned.components(separatedBy: "\n")

        // Classify each line — template lines (class/method signatures, braces, imports)
        // go to round 1 (.keep), new code goes to round 2 (.type)
        let templatePatterns = [
            "public class ", "class ", "interface ",
            "public static void main",
            "import ", "package ",
            "@RestController", "@Configuration", "@Component", "@Service",
        ]
        // First pass: find template boundaries.
        // Only the class declaration, method signature, and their closing braces are template.
        // All other lines (including intermediate "}" for if/for/else blocks) are solution code.
        let trimmedLines = rawLines.map { $0.trimmingCharacters(in: .whitespaces) }

        // Find the LAST two "}" lines — those are the method close and class close (template)
        var templateBraceIndices = Set<Int>()
        var braceCount = 0
        for i in stride(from: trimmedLines.count - 1, through: 0, by: -1) {
            if trimmedLines[i] == "}" || trimmedLines[i] == "};" {
                templateBraceIndices.insert(i)
                braceCount += 1
                if braceCount >= 2 { break }  // only last 2 closing braces are template
            }
        }

        let solutionLines: [SolutionLine] = rawLines.enumerated().map { (idx, line) in
            let trimmed = trimmedLines[idx]
            let type = classifyLine(trimmed)
            let section = classifySection(trimmed)

            // Template: class/method signatures, imports, and the last 2 closing braces
            let isTemplate = trimmed.isEmpty
                || templateBraceIndices.contains(idx)
                || templatePatterns.contains(where: { trimmed.hasPrefix($0) })
                || (trimmed.hasPrefix("public ") && trimmed.contains("(") && trimmed.hasSuffix("{"))

            return SolutionLine(
                text: line, type: type, section: section,
                round: isTemplate ? 1 : 2,
                action: isTemplate ? .keep : .type
            )
        }

        // Generate a problem ID from question text
        let words = questionText.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { $0.count > 3 }
            .prefix(3)
        let problemId = "gemini_" + words.joined(separator: "_")

        return MockSolution(
            problemId: problemId,
            keywords: [],  // Not needed for Gemini-generated solutions
            lines: solutionLines
        )
    }

    /// Classify a code line as "key", "ctx", or "boiler"
    static func classifyLine(_ trimmed: String) -> String {
        // Empty lines are boilerplate
        if trimmed.isEmpty { return "boiler" }

        // Import statements → context
        if trimmed.hasPrefix("import ") { return "ctx" }

        // Package declarations → boilerplate
        if trimmed.hasPrefix("package ") { return "boiler" }

        // Pure closing braces → boilerplate
        if trimmed == "}" || trimmed == "};" { return "boiler" }

        // Class/interface declarations → boilerplate
        if trimmed.hasPrefix("public class ") || trimmed.hasPrefix("class ") ||
           trimmed.hasPrefix("public interface ") {
            return "boiler"
        }

        // Main method signature → boilerplate
        if trimmed.contains("public static void main") { return "boiler" }

        // Method signatures (function declarations) → context
        if (trimmed.hasPrefix("public ") || trimmed.hasPrefix("private ") || trimmed.hasPrefix("protected ") ||
            trimmed.hasPrefix("static ")) && trimmed.contains("(") && (trimmed.hasSuffix("{") || trimmed.hasSuffix(")")) {
            return "ctx"
        }

        // Scanner/reader setup → context
        if trimmed.contains("new Scanner") || trimmed.contains("new BufferedReader") ||
           trimmed.contains("scanner.close") || trimmed.contains("sc.close") {
            return "ctx"
        }

        // Variable declarations that are just reading input → context
        if trimmed.contains("sc.next") || trimmed.contains("scanner.next") ||
           trimmed.contains("Integer.parseInt") || trimmed.contains("sc.skip") {
            return "ctx"
        }

        // Try/catch blocks → context
        if trimmed.hasPrefix("try {") || trimmed.hasPrefix("} catch") || trimmed.hasPrefix("catch (") {
            return "ctx"
        }

        // Core logic: conditionals, loops, returns, assignments with logic
        if trimmed.hasPrefix("if ") || trimmed.hasPrefix("} else") || trimmed.hasPrefix("else ") ||
           trimmed.hasPrefix("for ") || trimmed.hasPrefix("while ") || trimmed.hasPrefix("switch ") ||
           trimmed.hasPrefix("case ") || trimmed.hasPrefix("return ") ||
           trimmed.contains("System.out.print") || trimmed.contains("throw ") {
            return "key"
        }

        // Assignments and operations → key (these are the meat of the solution)
        if trimmed.contains(" = ") || trimmed.contains(" += ") || trimmed.contains(" -= ") ||
           trimmed.contains("++") || trimmed.contains("--") || trimmed.contains(".put(") ||
           trimmed.contains(".add(") || trimmed.contains(".push(") || trimmed.contains(".pop()") {
            return "key"
        }

        // Default: context
        return "ctx"
    }

    /// Classify a line's section as "input", "logic", or "output"
    static func classifySection(_ trimmed: String) -> String {
        if trimmed.contains("Scanner") || trimmed.contains("sc.next") || trimmed.contains("scanner.next") ||
           trimmed.contains("BufferedReader") || trimmed.contains("readLine") ||
           trimmed.hasPrefix("import ") {
            return "input"
        }
        if trimmed.contains("System.out.print") || trimmed.contains("return ") ||
           trimmed.contains("throw ") {
            return "output"
        }
        return "logic"
    }

    // MARK: - Helpers

    /// Generate a cache key from question text (normalized, trimmed)
    private static func cacheKey(for text: String) -> String {
        let normalized = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // Use a prefix hash to keep the key manageable
        let hash = normalized.hashValue
        return "q_\(hash)"
    }
}

// MARK: - Errors

enum GeminiError: LocalizedError {
    case invalidURL
    case noData
    case invalidJSON
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid Gemini API URL"
        case .noData: return "No data received from Gemini API"
        case .invalidJSON: return "Invalid JSON response from Gemini API"
        case .apiError(let msg): return "Gemini API error: \(msg)"
        }
    }
}
