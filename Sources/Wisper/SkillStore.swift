import Foundation

struct Skill: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var content: String
}

/// Named prompt snippets ("skills") pasted whole when you speak their name —
/// hold Fn and say "tdd skill" to paste the entire tdd prompt into whatever
/// LLM chat box has focus.
///
/// Stored as one .md file per skill in App Support/Wisper/Skills, so the
/// folder can also be managed by hand or synced.
final class SkillStore {
    private(set) var skills: [Skill] = []
    private let dirURL: URL

    init() {
        dirURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wisper/Skills", isDirectory: true)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        reload()
    }

    var directoryURL: URL { dirURL }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil)) ?? []
        skills = files
            .filter { $0.pathExtension == "md" }
            .compactMap { url in
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " ")
                return Skill(name: name, content: content)
            }
            .sorted { $0.name < $1.name }
    }

    func save(_ skill: Skill) {
        try? skill.content.write(to: fileURL(for: skill.name), atomically: true, encoding: .utf8)
        reload()
    }

    func rename(_ oldName: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != oldName else { return }
        try? FileManager.default.moveItem(at: fileURL(for: oldName), to: fileURL(for: trimmed))
        reload()
    }

    func delete(_ name: String) {
        try? FileManager.default.removeItem(at: fileURL(for: name))
        reload()
    }

    private func fileURL(for name: String) -> URL {
        let slug = name.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return dirURL.appendingPathComponent("\(slug.isEmpty ? "skill" : slug).md")
    }

    // MARK: - Matching

    /// A dictation invokes a skill when the whole utterance is the skill's
    /// name, optionally framed: "tdd", "tdd skill", "skill tdd",
    /// "use the tdd skill", "paste the code review skill".
    func match(_ utterance: String) -> Skill? {
        let spoken = Self.canonical(utterance)
        guard !spoken.isEmpty else { return nil }
        return skills.first { Self.canonical($0.name) == spoken }
    }

    static func canonical(_ text: String) -> String {
        var s = CommandStore.normalize(text)
        s = s.replacingOccurrences(of: #"^(use|paste|insert|apply)\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^(the)\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^skill\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+skill$"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Import from a GitHub repo

    /// Downloads a GitHub repo tarball and imports every SKILL.md (named
    /// after its parent directory) plus loose .md files under a skills/ tree.
    /// Returns the number of skills imported.
    func importFromGitHub(repo: String) async throws -> Int {
        // Accept "owner/name" or a full URL.
        let cleaned = repo
            .replacingOccurrences(of: "https://github.com/", with: "")
            .replacingOccurrences(of: ".git", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard cleaned.split(separator: "/").count == 2 else {
            throw NSError(domain: "Wisper", code: 10, userInfo: [NSLocalizedDescriptionKey: "Use owner/repo or a GitHub URL"])
        }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("wisper-skills-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        var tarballData: Data?
        for branch in ["main", "master"] {
            let url = URL(string: "https://codeload.github.com/\(cleaned)/tar.gz/refs/heads/\(branch)")!
            if let (data, response) = try? await URLSession.shared.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                tarballData = data
                break
            }
        }
        guard let tarballData else {
            throw NSError(domain: "Wisper", code: 11, userInfo: [NSLocalizedDescriptionKey: "Could not download \(cleaned)"])
        }

        let tarPath = temp.appendingPathComponent("repo.tar.gz")
        try tarballData.write(to: tarPath)
        let untar = Process()
        untar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        untar.arguments = ["-xzf", tarPath.path, "-C", temp.path]
        try untar.run()
        untar.waitUntilExit()
        guard untar.terminationStatus == 0 else {
            throw NSError(domain: "Wisper", code: 12, userInfo: [NSLocalizedDescriptionKey: "Could not unpack the repo"])
        }

        var imported = 0
        if let enumerator = FileManager.default.enumerator(at: temp, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.lastPathComponent == "SKILL.md" {
                let name = url.deletingLastPathComponent().lastPathComponent.replacingOccurrences(of: "-", with: " ")
                guard let content = try? String(contentsOf: url, encoding: .utf8), !content.isEmpty else { continue }
                save(Skill(name: name, content: content))
                imported += 1
            }
        }
        wlog("skills: imported \(imported) from \(cleaned)")
        return imported
    }
}
