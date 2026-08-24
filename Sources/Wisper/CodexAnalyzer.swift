import Foundation

/// Runs the user's Codex CLI subscription headlessly (`codex exec`) for the
/// fun "Dictation Wrapped" analysis — a bigger model than anything we run
/// locally, triggered explicitly by a button press. Read-only sandbox.
enum CodexAnalyzer {
    static func findBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            NSHomeDirectory() + "/.local/bin/codex",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func wrappedPrompt(rows: [TranscriptStore.Row]) -> String {
        let sample = rows.suffix(120).map { row -> String in
            let time = row.timestamp.formatted(date: .abbreviated, time: .shortened)
            return "[\(time)] \(row.raw)"
        }.joined(separator: "\n")

        return """
        Below are raw voice-dictation transcripts from one person (me), captured by my dictation app before any cleanup — fillers, stutters, and mishearings included. Write me a fun "Dictation Wrapped" report in markdown:

        1. **Personality read** — what my dictation style says about me (2-3 sentences, playful but perceptive).
        2. **Signature moves** — my recurring phrases, verbal tics, and habits, with rough counts and a short quote each.
        3. **The awards** — three superlatives (e.g. Most Chaotic Dictation, Politest Command, Best Mishearing), each with the winning quote.
        4. **The roast** — one gentle roast paragraph.
        5. **One real tip** — a single genuinely useful suggestion for dictating clearer.

        Under 400 words total. Address me as "you". Quote my actual words.

        TRANSCRIPTS:
        \(sample)
        """
    }

    /// Runs `codex exec` and returns the final message, or an error string.
    static func run(prompt: String) async -> String {
        guard let binary = findBinary() else {
            return "Codex CLI not found — install it (brew install codex) and sign in first."
        }
        let outFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisper-codex-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: outFile) }

        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["exec", "--sandbox", "read-only", "--skip-git-repo-check", "-o", outFile.path, "-"]
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            let stdin = Pipe()
            process.standardInput = stdin
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 240, execute: timeout)

            process.terminationHandler = { _ in
                timeout.cancel()
                let result = (try? String(contentsOf: outFile, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let result, !result.isEmpty {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(returning: "Codex returned nothing — is the CLI signed in? Try `codex exec \"hi\"` in a terminal.")
                }
            }
            do {
                try process.run()
                stdin.fileHandleForWriting.write(Data(prompt.utf8))
                stdin.fileHandleForWriting.closeFile()
            } catch {
                timeout.cancel()
                continuation.resume(returning: "Could not launch Codex: \(error.localizedDescription)")
            }
        }
    }
}
