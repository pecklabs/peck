import Foundation

enum AppPaths {
    static var dataDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("PRAgent", isDirectory: true)
    }
    static var skillsDir: URL { dataDir.appendingPathComponent("skills", isDirectory: true) }

    static func ensure() {
        try? FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        seedDefaultSkill()
    }

    /// Copy the bundled default skill into the user skills dir on first launch so
    /// it's visible and editable.
    private static func seedDefaultSkill() {
        let dest = skillsDir.appendingPathComponent("default-review.md")
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }
        if let src = Bundle.module.url(forResource: "default-review", withExtension: "md", subdirectory: "skills")
            ?? Bundle.module.url(forResource: "default-review", withExtension: "md") {
            try? FileManager.default.copyItem(at: src, to: dest)
        }
    }
}

struct Skill {
    var name: String
    var description: String
    var enabled: Bool
    var path: String
    var body: String
}

enum Skills {
    static func parseFrontmatter(_ raw: String) -> (meta: [String: String], body: String) {
        guard raw.hasPrefix("---") else { return ([:], raw.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let lines = raw.components(separatedBy: "\n")
        guard lines.first == "---" else { return ([:], raw) }
        var meta: [String: String] = [:]
        var i = 1
        while i < lines.count, lines[i] != "---" {
            let line = lines[i]
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                var val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                val = val.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                meta[key] = val
            }
            i += 1
        }
        let body = lines[(min(i + 1, lines.count))...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (meta, body)
    }

    static func load() -> [Skill] {
        AppPaths.ensure()
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: AppPaths.skillsDir, includingPropertiesForKeys: nil)
        else { return [] }
        var out: [Skill] = []
        for url in entries where url.pathExtension == "md" {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let (meta, body) = parseFrontmatter(raw)
            let name = meta["name"] ?? url.deletingPathExtension().lastPathComponent
            let desc = meta["description"] ?? String(body.prefix(120)).components(separatedBy: "\n").first ?? ""
            let enabled = (meta["enabled"] ?? "true") != "false"
            out.append(Skill(name: name, description: desc, enabled: enabled, path: url.path, body: body))
        }
        return out.sorted { $0.name < $1.name }
    }

    static func info() -> [SkillInfo] {
        load().map { SkillInfo(name: $0.name, description: $0.description, enabled: $0.enabled, path: $0.path) }
    }

    /// Concatenated instructions for the agent + which skills were applied.
    static func activeInstructions() -> (text: String, applied: [String]) {
        let active = load().filter { $0.enabled && !$0.body.isEmpty }
        let text = active.map { "## Skill: \($0.name)\n\($0.body)" }.joined(separator: "\n\n")
        return (text, active.map { $0.name })
    }
}
