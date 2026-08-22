import Foundation

/// The personalization loop: a word list that adapts Wisper to how this
/// person actually speaks.
///
/// Backed by a user-editable text file. Two kinds of lines:
///   Ghostty                      — vocabulary: prefer this word over
///                                  similar-sounding mishearings (via the LLM)
///   my arms -> my ums            — replacement: applied deterministically to
///                                  every transcript, for recurring mishearings
///
/// Vocabulary is also learned automatically: words that recur across
/// dictations but aren't in the system dictionary (names, jargon) get added
/// under the "# learned" marker.
final class PersonalDictionary {
    private(set) var vocabulary: [String] = []
    private(set) var replacements: [(from: String, to: String)] = []

    private let fileURL: URL
    private let learnedMarker = "# learned (auto-added from your dictations; edit or delete freely)"

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wisper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("dictionary.txt")

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let template = """
            # Wisper personal dictionary.
            # One entry per line:
            #   SomeWord            → tells the cleanup model to prefer this word
            #                         when the transcription picked a similar-sounding one
            #   wrong -> right      → always replace "wrong" with "right" in transcripts
            #                         (use for recurring mishearings, e.g. "my arms -> my ums")

            """
            try? template.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        reload()
    }

    var fileURLForEditing: URL { fileURL }

    func reload() {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        (vocabulary, replacements) = Self.parse(content)
    }

    static func parse(_ content: String) -> (vocabulary: [String], replacements: [(from: String, to: String)]) {
        var vocabulary: [String] = []
        var replacements: [(String, String)] = []
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            if let arrowRange = trimmed.range(of: "->") {
                let from = trimmed[..<arrowRange.lowerBound].trimmingCharacters(in: .whitespaces)
                let to = trimmed[arrowRange.upperBound...].trimmingCharacters(in: .whitespaces)
                if !from.isEmpty && !to.isEmpty { replacements.append((from, to)) }
            } else {
                vocabulary.append(trimmed)
            }
        }
        return (vocabulary, replacements)
    }

    /// Persists structured edits (from the Dictionary UI) back to the file.
    func save(vocabulary newVocabulary: [String], replacements newReplacements: [(from: String, to: String)]) {
        var content = """
        # Wisper personal dictionary.
        #   SomeWord            → tells the cleanup model to prefer this word
        #   wrong -> right      → always replace "wrong" with "right" in transcripts

        """
        let vocab = newVocabulary.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let repls = newReplacements.filter { !$0.from.trimmingCharacters(in: .whitespaces).isEmpty && !$0.to.trimmingCharacters(in: .whitespaces).isEmpty }
        if !vocab.isEmpty {
            content += vocab.joined(separator: "\n") + "\n"
        }
        if !repls.isEmpty {
            content += "\n" + repls.map { "\($0.from.trimmingCharacters(in: .whitespaces)) -> \($0.to.trimmingCharacters(in: .whitespaces))" }.joined(separator: "\n") + "\n"
        }
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
        reload()
    }

    /// Deterministic replacement pass, applied to every transcript before any
    /// LLM involvement. Case-insensitive, word-boundary matched.
    func applyReplacements(to text: String) -> String {
        var result = text
        for (from, to) in replacements {
            let escaped = NSRegularExpression.escapedPattern(for: from)
            result = result.replacingOccurrences(
                of: "(?i)\\b\(escaped)\\b",
                with: to,
                options: .regularExpression
            )
        }
        return result
    }

    // MARK: - Auto-learning

    /// Scans dictation history for words this person uses repeatedly that are
    /// not ordinary English — names, tools, jargon — and adds them to the
    /// vocabulary so future cleanups prefer them over mishearings.
    func learn(from rows: [TranscriptStore.Row]) {
        guard let systemWords = Self.systemWordList() else { return }
        let known = Set(vocabulary.map { $0.lowercased() })

        var counts: [String: Int] = [:]
        var casing: [String: String] = [:]
        for row in rows {
            let words = row.raw.components(
                separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            for word in words where word.count >= 3 && word.count <= 30 {
                let lower = word.lowercased()
                guard !systemWords.contains(lower),
                      !known.contains(lower),
                      word.rangeOfCharacter(from: .decimalDigits) == nil else { continue }
                counts[lower, default: 0] += 1
                // Keep the most informative casing we've seen (prefer capitalized).
                if casing[lower] == nil || (word.first?.isUppercase == true && casing[lower]?.first?.isUppercase != true) {
                    casing[lower] = word
                }
            }
        }

        let newWords = counts.filter { $0.value >= 3 }.keys.compactMap { casing[$0] }.sorted()
        guard !newWords.isEmpty else { return }

        var content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        if !content.contains(learnedMarker) {
            content += "\n\(learnedMarker)\n"
        }
        content += newWords.joined(separator: "\n") + "\n"
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
        reload()
        wlog("dictionary: learned \(newWords.count) new words: \(newWords.joined(separator: ", "))")
    }

    private static func systemWordList() -> Set<String>? {
        guard let content = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return nil }
        var set = Set<String>()
        content.enumerateLines { line, _ in set.insert(line.lowercased()) }
        return set
    }
}
