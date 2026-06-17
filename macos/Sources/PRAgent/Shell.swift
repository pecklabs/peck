import Foundation

/// Runs external CLIs (gh, claude, codex). A GUI app launched via `open` has a
/// minimal PATH, so tools are resolved via the login shell and run with an
/// augmented environment.
enum Shell {
    struct Result { let stdout: String; let stderr: String; let exit: Int32 }
    struct ShellError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let extraPaths = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
        NSHomeDirectory() + "/.local/bin",
    ]

    private static var cache: [String: String] = [:]
    private static let lock = NSLock()

    /// Absolute path to a CLI, or nil if not found.
    static func resolve(_ name: String) -> String? {
        lock.lock(); let cached = cache[name]; lock.unlock()
        if let cached { return cached }

        var found: String?
        for dir in extraPaths {
            let p = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: p) { found = p; break }
        }
        if found == nil,
           let r = try? runSync("/bin/zsh", ["-lc", "command -v \(name)"]),
           r.exit == 0 {
            let p = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !p.isEmpty, FileManager.default.isExecutableFile(atPath: p) { found = p }
        }
        if let found {
            lock.lock(); cache[found] = found; cache[name] = found; lock.unlock()
        }
        return found
    }

    private static func augmentedEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let current = env["PATH"] ?? ""
        env["PATH"] = (extraPaths + [current]).joined(separator: ":")
        return env
    }

    static func runSync(_ launchPath: String, _ args: [String],
                        stdin: String? = nil, cwd: String? = nil) throws -> Result {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        proc.environment = augmentedEnv()
        if let cwd { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = inPipe

        try proc.run()

        // Write stdin and read both outputs concurrently to avoid pipe deadlock.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        let q = DispatchQueue.global()
        group.enter(); q.async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); q.async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); q.async {
            if let stdin { inPipe.fileHandleForWriting.write(Data(stdin.utf8)) }
            try? inPipe.fileHandleForWriting.close()
            group.leave()
        }
        proc.waitUntilExit()
        group.wait()

        return Result(
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            exit: proc.terminationStatus
        )
    }

    static func run(_ launchPath: String, _ args: [String],
                    stdin: String? = nil, cwd: String? = nil) async throws -> Result {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                do { cont.resume(returning: try runSync(launchPath, args, stdin: stdin, cwd: cwd)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Extracts the first balanced top-level JSON object from text (tolerates
    /// code fences / surrounding prose from a CLI).
    static func extractJSONObject(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        var idx = start
        while idx < text.endIndex {
            let c = text[idx]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else {
                if c == "\"" { inString = true }
                else if c == "{" { depth += 1 }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 { return String(text[start...idx]) }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }
}
