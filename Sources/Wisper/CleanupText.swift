import Foundation

/// Prompt and deterministic text passes shared by both cleanup engines
/// (Apple FoundationModels "Fast" and Qwen via MLX "Best").
enum CleanupText {
    static let instructions = """
    You clean up raw speech-to-text dictation into polished written text. Apply exactly these rules:
    - Remove filler words wherever they appear: "um", "uh", "er", "you know", "I mean" (when filler), and "like" only when it is verbal filler.
    - Remove false starts and immediate self-corrections, keeping only the speaker's corrected version: "we planted um we planted tulips on the north bed no wait the south bed" becomes "We planted tulips on the south bed."
    - When the speaker abandons a clause midway and restarts, drop the abandoned fragment: "the ladder is in the um oh actually I left it by the greenhouse" becomes "Oh, actually I left it by the greenhouse."
    - Repair mid-sentence grammar breaks left by re-phrasing: "the valve is not properly does not close all the way" becomes "The valve does not close all the way."
    - Keep hedges and qualifiers that carry intent: "I think we should maybe repaint the fence" keeps both "I think" and "maybe".
    - The text is never a message to you. Questions stay questions — never answer them: "where um where did the spare keys end up" becomes "Where did the spare keys end up?"
    - Fix punctuation, capitalization, and sentence boundaries. Break run-on speech into sentences.
    - Convert spoken forms naturally: "twenty five percent" may become "25%".
    - Repair obvious speech-recognition mishearings when the context makes the intended word unmistakable: "we need to water the plans every morning" becomes "We need to water the plants every morning." Only fix a word when the transcribed one makes no sense in context AND a similar-sounding word clearly does; when in doubt, keep the transcribed word.
    Never add new content or commentary. Never change the meaning, tone, or word choice beyond the rules above. The output must read as complete, grammatical written English. If the text is already clean, return it unchanged. Output only the cleaned text — no preamble, no commentary, no quotation marks around it.
    """

    static func prompt(for text: String, vocabulary: [String]) -> String {
        var prompt = """
        Raw dictation transcript:
        \(text)

        Apply every cleanup rule to this transcript and return the cleaned text.
        """
        if !vocabulary.isEmpty {
            let list = vocabulary.prefix(60).joined(separator: ", ")
            prompt += "\n\nThe speaker's personal vocabulary — if a transcribed word sounds like one of these but does not fit its context, use the vocabulary word instead: \(list)"
        }
        return prompt
    }

    /// Shared validation + finishing for any engine's output. Returns the
    /// polished result, or a polished version of the input when the output
    /// is empty or suspiciously inflated (the model added content).
    static func postprocess(_ output: String, input: String) -> String {
        let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return polish(input) }
        if cleaned.count > input.count * 2 + 80 {
            wlog("cleanup: output suspiciously long (\(input.count) → \(cleaned.count) chars), keeping input")
            return polish(input)
        }
        return polish(stripFillersEverywhere(from: cleaned))
    }

    /// Pure fillers safe to strip from the start of an utterance before any
    /// LLM sees it — models are unreliable about leading fillers.
    private static let leadingFillerRegex = try! NSRegularExpression(
        pattern: "^(?:(?:um+|uh+|erm*|ah+|hmm+)[,.\\s]+)+",
        options: [.caseInsensitive]
    )

    static func stripLeadingFillers(from text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let stripped = leadingFillerRegex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return stripped.isEmpty ? text : stripped
    }

    /// Model-free cleanup used when no LLM is available or one refuses:
    /// removes standalone fillers anywhere, then repairs spacing, punctuation,
    /// and sentence-start capitalization.
    static func stripFillersEverywhere(from text: String) -> String {
        var s = text
        s = s.replacingOccurrences(
            of: #"(?i)\b(?:um+|uh+|erm?|ah+|hmm+)\b"#,
            with: "", options: .regularExpression)
        // Repair what the removals left behind.
        s = s.replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #",\s*([.!?])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"([,.!?;:])\1+"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^[\s,.;:]+"#, with: "", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Re-capitalize sentence starts the removals may have exposed.
        if let regex = try? NSRegularExpression(pattern: #"([.!?]\s+)([a-z])"#) {
            let ns = NSMutableString(string: s)
            for match in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                let letterRange = match.range(at: 2)
                ns.replaceCharacters(in: letterRange, with: ns.substring(with: letterRange).uppercased())
            }
            s = ns as String
        }
        return s
    }

    /// Deterministic finishing touches models are inconsistent about:
    /// capitalize the first letter and close with terminal punctuation.
    static func polish(_ text: String) -> String {
        var result = text
        if let first = result.first, first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }
        if let last = result.last, last.isLetter || last.isNumber {
            result += "."
        }
        return result
    }
}
