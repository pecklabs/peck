import Foundation

struct AgentError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Runs the code review agent against a PR and returns a structured draft.
/// Supports three backends: the Anthropic API directly, or the `claude` / `codex`
/// CLIs (which reuse the user's existing login — no API key needed).
enum ReviewAgent {
    static let maxDiffChars = 60_000

    /// An isolated empty directory to run the CLI backends in, so they don't scan
    /// the user's home / project and trigger Photos/Music/Files permission prompts.
    /// (The whole review is passed via stdin, so no real working dir is needed.)
    private static var workDir: String {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("PRAgent-agent")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    static let systemBase = """
    You are a senior code reviewer acting on behalf of the user, who has been asked to review a GitHub pull request.

    Your job has two parts:
    1. EXPLAIN the PR to the user in plain language — what it changes, why, and anything they should know before deciding. Assume the user has not read the diff.
    2. RECOMMEND a verdict: APPROVE, REQUEST_CHANGES, or COMMENT, with a ready-to-post review body.

    Be concrete and skimmable. Call out real risks (correctness, security, breaking changes, missing tests) — do not pad with generic praise. If the change is small and safe, say so plainly and APPROVE. Only REQUEST_CHANGES for issues that should block merge; use COMMENT for non-blocking notes.

    TONE: Courteous and natural — not blunt or commanding, but not over-the-top either. No gushing, flattery, excessive thanks, or emoji. Keep it plain and professional, like a normal coworker comment. In Korean use 존댓말 but understated. Don't be arrogant, and don't write filler.
    The body should contain substantive content (a concise note of what the change does and anything worth flagging). Never write a sentence whose only purpose is to announce the verdict — e.g. "approve 합니다", "approve 할게요", "LGTM", "머지해도 될 것 같습니다" — the verdict is shown separately, so don't restate it.

    The user makes the final call and will confirm before anything is posted to GitHub.
    """

    static let selfSystemBase = """
    You are a senior code reviewer helping the user sanity-check a pull request THEY just uploaded, before teammates look at it.

    Your job has two parts:
    1. EXPLAIN how the PR reads to a first-time reviewer — what it changes and why, and anything a reviewer would stumble on (unclear naming, missing context in the description).
    2. FLAG what the author should fix before requesting review — real bugs, leftover debug code, dead files, missing tests, risky edge cases — and give a readiness verdict: APPROVE (ready for review), REQUEST_CHANGES (fix the flagged items first), or COMMENT (minor notes only).

    Be concrete and skimmable. Don't pad with praise and don't restate the diff — only say things the author doesn't already know. If the PR is clean, say so plainly and APPROVE.

    Nothing here is posted to GitHub — this is a private pre-flight note for the author.
    """

    static let jsonInstruction = """
    Respond with ONLY a single JSON object (no markdown, no prose, no code fence) with exactly these keys:
    - "summary": string — plain-language explanation of what the PR does and why (2-5 sentences).
    - "verdict": one of "APPROVE", "REQUEST_CHANGES", "COMMENT".
    - "body": string — ready-to-post GitHub review body in markdown.
    - "risks": array of strings — specific risks or things to double-check (empty array if none).
    - "comments": array of objects {"path": string, "line": integer, "body": string} — optional inline comments (empty array if none).
    """

    static let selfJsonInstruction = """
    Respond with ONLY a single JSON object (no markdown, no prose, no code fence) with exactly these keys:
    - "summary": string — how the PR reads to a first-time reviewer: what it does and why (2-4 sentences).
    - "verdict": one of "APPROVE" (ready for review), "REQUEST_CHANGES" (fix first), "COMMENT" (minor notes only).
    - "body": string — leave as an empty string (nothing is posted).
    - "risks": array of strings — concrete things to fix or double-check before requesting review (empty array if none).
    - "comments": empty array.
    """

    // MARK: Shared context

    /// Who the review is for: a PR the user was asked to review, or a pre-flight
    /// self-review of a PR the user authored (never posted anywhere).
    enum Mode { case incoming, selfCheck }

    private struct Prepared {
        var content: PrContent
        var system: String
        var userMsg: String
        var applied: [String]
        var json: String
    }

    private static func languageInstruction(_ s: AppSettings, mode: Mode) -> String {
        switch mode {
        case .incoming:
            return """
            LANGUAGE:
            - Write "summary" and every item in "risks" in \(s.explanationLanguage).
            - Write "body" (this text will be posted publicly on GitHub) in \(s.reviewLanguage).
            - Keep the JSON keys and the "verdict" value exactly as specified (English enum values).
            """
        case .selfCheck:
            return """
            LANGUAGE:
            - Write "summary" and every item in "risks" in \(s.explanationLanguage).
            - Keep the JSON keys and the "verdict" value exactly as specified (English enum values).
            """
        }
    }

    private static func prepare(owner: String, repo: String, number: Int,
                                mode: Mode, settings: AppSettings) async throws -> Prepared {
        let content = try await GitHubClient.shared.fetchPrContent(owner: owner, repo: repo, number: number)
        var diff = content.diff
        var truncated = false
        if diff.count > maxDiffChars { diff = String(diff.prefix(maxDiffChars)); truncated = true }

        let skills = Skills.activeInstructions()
        let base = mode == .incoming ? systemBase : selfSystemBase
        let system = skills.text.isEmpty
            ? base
            : "\(base)\n\nThe user has provided the following review guidelines. Follow them:\n\n\(skills.text)"

        let fileList = content.files
            .map { "- \($0.status) \($0.filename) (+\($0.additions)/-\($0.deletions))" }
            .joined(separator: "\n")

        let userMsg = """
        Repository: \(owner)/\(repo)
        Pull request #\(number): \(content.title)

        Description:
        \(content.body.isEmpty ? "(no description)" : content.body)

        Changed files:
        \(fileList)

        Unified diff\(truncated ? " (truncated — review what is shown)" : ""):
        ```diff
        \(diff)
        ```

        \(mode == .incoming ? "Review this PR." : "Self-review this PR the user authored.")

        \(languageInstruction(settings, mode: mode))
        """
        return Prepared(content: content, system: system, userMsg: userMsg, applied: skills.applied,
                        json: mode == .incoming ? jsonInstruction : selfJsonInstruction)
    }

    private static func draft(from obj: [String: Any], applied: [String], model: String) throws -> ReviewDraft {
        guard let summary = obj["summary"] as? String,
              let verdictStr = obj["verdict"] as? String,
              let verdict = Verdict(rawValue: verdictStr)
        else { throw AgentError(message: "Agent returned an unexpected response shape") }
        let comments: [InlineComment] = (obj["comments"] as? [[String: Any]] ?? []).compactMap {
            guard let path = $0["path"] as? String, let body = $0["body"] as? String else { return nil }
            let line = ($0["line"] as? Int) ?? Int(($0["line"] as? Double) ?? 0)
            return InlineComment(path: path, line: line, body: body)
        }
        return ReviewDraft(
            summary: summary, verdict: verdict,
            body: obj["body"] as? String ?? "",
            risks: obj["risks"] as? [String] ?? [],
            comments: comments,
            model: model, skillsApplied: applied, generatedAt: Date(), error: nil
        )
    }

    // MARK: Entry points

    static func review(_ pr: ReviewRequest, settings: AppSettings) async throws -> ReviewDraft {
        try await run(owner: pr.owner, repo: pr.repo, number: pr.number, mode: .incoming, settings: settings)
    }

    /// Pre-flight review of the user's own PR. Same pipeline, self-check prompt.
    static func selfReview(_ pr: MyPullRequest, settings: AppSettings) async throws -> ReviewDraft {
        try await run(owner: pr.owner, repo: pr.repo, number: pr.number, mode: .selfCheck, settings: settings)
    }

    private static func run(owner: String, repo: String, number: Int,
                            mode: Mode, settings: AppSettings) async throws -> ReviewDraft {
        let p = try await prepare(owner: owner, repo: repo, number: number, mode: mode, settings: settings)
        switch settings.agentBackend {
        case .anthropicAPI: return try await reviewViaAPI(p, settings: settings)
        case .claudeCLI: return try await reviewViaClaude(p)
        case .codexCLI: return try await reviewViaCodex(p)
        }
    }

    // MARK: claude CLI

    private static func reviewViaClaude(_ p: Prepared) async throws -> ReviewDraft {
        guard let path = Shell.resolve("claude") else {
            throw AgentError(message: "`claude` CLI not found. Install Claude Code or pick another backend.")
        }
        let prompt = "\(p.system)\n\n\(p.userMsg)\n\n\(p.json)"
        let r = try await Shell.run(path, ["-p", "--output-format", "json"], stdin: prompt, cwd: workDir)
        guard r.exit == 0 else {
            throw AgentError(message: "claude CLI failed: \(r.stderr.isEmpty ? r.stdout : r.stderr)")
        }
        // Envelope: {"result": "<assistant text>", ...}
        guard let envelope = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any],
              let resultText = envelope["result"] as? String
        else { throw AgentError(message: "Could not parse claude CLI output") }
        guard let jsonStr = Shell.extractJSONObject(resultText),
              let obj = try? JSONSerialization.jsonObject(with: Data(jsonStr.utf8)) as? [String: Any]
        else { throw AgentError(message: "claude did not return valid JSON") }
        return try draft(from: obj, applied: p.applied, model: "claude-cli")
    }

    // MARK: codex CLI

    private static let codexSchema: [String: Any] = [
        "type": "object", "additionalProperties": false,
        "required": ["summary", "verdict", "body", "risks", "comments"],
        "properties": [
            "summary": ["type": "string"],
            "verdict": ["type": "string", "enum": ["APPROVE", "REQUEST_CHANGES", "COMMENT"]],
            "body": ["type": "string"],
            "risks": ["type": "array", "items": ["type": "string"]],
            "comments": [
                "type": "array",
                "items": [
                    "type": "object", "additionalProperties": false,
                    "required": ["path", "line", "body"],
                    "properties": [
                        "path": ["type": "string"],
                        "line": ["type": "integer"],
                        "body": ["type": "string"],
                    ],
                ],
            ],
        ],
    ]

    private static func reviewViaCodex(_ p: Prepared) async throws -> ReviewDraft {
        guard let path = Shell.resolve("codex") else {
            throw AgentError(message: "`codex` CLI not found. Install Codex or pick another backend.")
        }
        let prompt = "\(p.system)\n\n\(p.userMsg)\n\n\(p.json)"

        let dir = workDir
        let schemaPath = (dir as NSString).appendingPathComponent("schema.json")
        let outPath = (dir as NSString).appendingPathComponent("codex-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: codexSchema).write(to: URL(fileURLWithPath: schemaPath))
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        let r = try await Shell.run(path, [
            "exec", "--skip-git-repo-check", "-s", "read-only",
            "--output-schema", schemaPath, "-o", outPath,
        ], stdin: prompt, cwd: dir)

        guard let data = FileManager.default.contents(atPath: outPath),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            throw AgentError(message: "codex did not produce a result (exit \(r.exit)): \(r.stderr.isEmpty ? r.stdout : r.stderr)")
        }
        return try draft(from: obj, applied: p.applied, model: "codex-cli")
    }

    // MARK: Anthropic API

    private static func reviewViaAPI(_ p: Prepared, settings: AppSettings) async throws -> ReviewDraft {
        guard let key = Keychain.get(.anthropicKey) else {
            throw AgentError(message: "Anthropic API key not set")
        }
        let model = settings.model
        let tool: [String: Any] = [
            "name": "submit_review_draft",
            "description": "Provide the structured review of the pull request.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "summary": ["type": "string"],
                    "verdict": ["type": "string", "enum": ["APPROVE", "REQUEST_CHANGES", "COMMENT"]],
                    "body": ["type": "string"],
                    "risks": ["type": "array", "items": ["type": "string"]],
                    "comments": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "path": ["type": "string"], "line": ["type": "number"], "body": ["type": "string"],
                            ],
                            "required": ["path", "line", "body"],
                        ],
                    ],
                ],
                "required": ["summary", "verdict", "body", "risks"],
            ],
        ]
        let payload: [String: Any] = [
            "model": model, "max_tokens": 4096, "system": p.system,
            "tools": [tool], "tool_choice": ["type": "tool", "name": "submit_review_draft"],
            "messages": [["role": "user", "content": p.userMsg]],
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 120

        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = (json["error"] as? [String: Any])?["message"] as? String
            throw AgentError(message: msg ?? "Anthropic API error")
        }
        let blocks = json["content"] as? [[String: Any]] ?? []
        guard let toolUse = blocks.first(where: { ($0["type"] as? String) == "tool_use" }),
              let input = toolUse["input"] as? [String: Any]
        else { throw AgentError(message: "Agent did not return a structured review") }
        return try draft(from: input, applied: p.applied, model: model)
    }
}
