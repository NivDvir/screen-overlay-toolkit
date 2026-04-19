import Foundation
import CoreGraphics
import AppKit

/// Super-Deep Scan: Qwen2.5-VL panel detection via persistent Python server.
/// Model loaded ONCE (~5.3GB), stays in memory, accepts requests via stdin/stdout.

struct ScreenAnalysis {
    let platform: String
    let questionPanel: PanelInfo
    let editorPanel: PanelInfo
    let solution: MockSolution
}

struct PanelInfo {
    let bounds: CGRect
    let title: String
    let content: String
    let lineHeight: CGFloat
    let firstLineY: CGFloat
}

class LLMAnalyzer {
    private var serverProcess: Process?
    private var serverStdin: FileHandle?
    private var serverStdout: FileHandle?
    private var isReady = false

    /// Start the persistent Python model server.
    /// Expects `panel_detector_server.py` alongside the binary (same directory as the .app's executable,
    /// or in the current working directory). Set `GROUNDINGKIT_PYTHON_SERVER` env var to override.
    func startServer() {
        let scriptPath: String = {
            if let override = ProcessInfo.processInfo.environment["GROUNDINGKIT_PYTHON_SERVER"],
               !override.isEmpty { return override }
            let bundleDir = Bundle.main.bundleURL.deletingLastPathComponent().path
            let candidates = [
                "\(bundleDir)/panel_detector_server.py",
                "\(FileManager.default.currentDirectoryPath)/Python/panel_detector_server.py",
                "\(FileManager.default.currentDirectoryPath)/panel_detector_server.py"
            ]
            return candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) ?? candidates[0]
        }()
        let pythonPath = ProcessInfo.processInfo.environment["GROUNDINGKIT_PYTHON"] ?? "/usr/bin/env"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = pythonPath.hasSuffix("/env") ? ["python3", scriptPath] : [scriptPath]
        process.currentDirectoryURL = URL(fileURLWithPath: (scriptPath as NSString).deletingLastPathComponent)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Log stderr in background
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                for line in text.split(separator: "\n") {
                    NSLog("QwenServer: %@", String(line))
                }
            }
        }

        do {
            try process.run()
            serverProcess = process
            serverStdin = stdinPipe.fileHandleForWriting
            serverStdout = stdoutPipe.fileHandleForReading

            // Wait for READY signal
            NSLog("LLM: waiting for Qwen model to load...")
            if let readyLine = readLine(from: serverStdout!) {
                if readyLine.contains("READY") {
                    isReady = true
                    NSLog("LLM: Qwen server READY")
                }
            }
        } catch {
            NSLog("LLM: failed to start server: %@", error.localizedDescription)
        }
    }

    /// Stop the server and release memory
    func stopServer() {
        if let stdin = serverStdin {
            if let data = "QUIT\n".data(using: .utf8) {
                stdin.write(data)
            }
        }
        serverProcess?.terminate()
        serverProcess = nil
        serverStdin = nil
        serverStdout = nil
        isReady = false
        NSLog("LLM: server stopped")
    }

    /// Detect panels by sending screenshot to persistent server
    func detectPanels(from image: CGImage) -> ScreenAnalysis? {
        guard isReady, let stdin = serverStdin, let stdout = serverStdout else {
            NSLog("LLM: server not ready")
            return nil
        }

        // Save screenshot
        let path = "/tmp/superdeep_input.png"
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return nil }
        try? data.write(to: URL(fileURLWithPath: path))

        // Send path to server
        guard let pathData = "\(path)\n".data(using: .utf8) else { return nil }
        stdin.write(pathData)

        // Read JSON response (with timeout)
        let startTime = CFAbsoluteTimeGetCurrent()
        guard let jsonLine = readLine(from: stdout, timeout: 30) else {
            NSLog("LLM: timeout waiting for response")
            return nil
        }
        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        NSLog("LLM: detection in %.0fms", elapsed)

        // Cleanup screenshot file
        try? FileManager.default.removeItem(atPath: path)

        // Parse response
        guard let jsonData = jsonLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            NSLog("LLM: invalid JSON: %@", String(jsonLine.prefix(100)))
            return nil
        }

        if let error = json["error"] as? String {
            NSLog("LLM: error: %@", error)
            return nil
        }

        return parseJSON(json)
    }

    /// Load analysis from pre-written JSON file (for initial startup)
    func loadAnalysis() -> ScreenAnalysis? {
        let path = "/tmp/superdeep_analysis.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parseJSON(json)
    }

    func hasAnalysis() -> Bool {
        let path = "/tmp/superdeep_analysis.json"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modDate = attrs[.modificationDate] as? Date else {
            return false
        }
        return Date().timeIntervalSince(modDate) < 60
    }

    // MARK: - Private

    /// Read a single line from file handle with timeout
    private func readLine(from handle: FileHandle, timeout: TimeInterval = 60) -> String? {
        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty {
                usleep(50000) // 50ms
                continue
            }
            buffer.append(chunk)
            if let str = String(data: buffer, encoding: .utf8), str.contains("\n") {
                return str.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return nil
    }

    private func parseJSON(_ json: [String: Any]) -> ScreenAnalysis? {
        let platform = json["platform"] as? String ?? "unknown"

        guard let qp = json["questionPanel"] as? [String: Any],
              let ep = json["editorPanel"] as? [String: Any] else { return nil }

        let questionPanel = PanelInfo(
            bounds: rectFromJSON(qp),
            title: qp["title"] as? String ?? "",
            content: qp["description"] as? String ?? "",
            lineHeight: 0,
            firstLineY: 0
        )

        let editorPanel = PanelInfo(
            bounds: rectFromJSON(ep),
            title: ep["language"] as? String ?? "",
            content: ep["currentCode"] as? String ?? "",
            lineHeight: (ep["lineHeight"] as? Double).map { CGFloat($0) } ?? 21,
            firstLineY: (ep["firstLineY"] as? Double).map { CGFloat($0) } ?? 0
        )

        // Load solution from existing analysis or empty
        let solLines: [SolutionLine]
        if let sol = json["solution"] as? [String: Any],
           let lineArray = sol["lines"] as? [[String: String]], !lineArray.isEmpty {
            solLines = lineArray.map { SolutionLine(text: $0["text"] ?? "", type: $0["type"] ?? "ctx", section: $0["section"] ?? "logic") }
        } else {
            solLines = []
        }

        let solution = MockSolution(problemId: "llm_\(platform)", keywords: [], lines: solLines)

        return ScreenAnalysis(platform: platform, questionPanel: questionPanel,
                              editorPanel: editorPanel, solution: solution)
    }

    private func rectFromJSON(_ dict: [String: Any]) -> CGRect {
        CGRect(
            x: (dict["x"] as? Double).map { CGFloat($0) } ?? 0,
            y: (dict["y"] as? Double).map { CGFloat($0) } ?? 0,
            width: (dict["width"] as? Double).map { CGFloat($0) } ?? 0,
            height: (dict["height"] as? Double).map { CGFloat($0) } ?? 0
        )
    }
}
