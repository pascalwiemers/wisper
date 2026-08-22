import Foundation

/// Per-feature switches from Settings → Output. Read fresh for every
/// dictation so changes apply immediately.
struct OutputOptions {
    var pasteAutomatically: Bool
    var restoreClipboard: Bool
    var capitalizeSentences: Bool
    var tidyPunctuation: Bool
    var removeFillers: Bool
    var spokenFormatting: Bool
    var applyCorrections: Bool

    static func current() -> OutputOptions {
        let d = UserDefaults.standard
        func flag(_ key: String) -> Bool { d.object(forKey: key) as? Bool ?? true }
        return OutputOptions(
            pasteAutomatically: flag("out.pasteAutomatically"),
            restoreClipboard: flag("out.restoreClipboard"),
            capitalizeSentences: flag("out.capitalizeSentences"),
            tidyPunctuation: flag("out.tidyPunctuation"),
            removeFillers: flag("out.removeFillers"),
            spokenFormatting: flag("out.spokenFormatting"),
            applyCorrections: flag("out.applyCorrections")
        )
    }

    static let allOn = OutputOptions(
        pasteAutomatically: true, restoreClipboard: true, capitalizeSentences: true,
        tidyPunctuation: true, removeFillers: true, spokenFormatting: true, applyCorrections: true
    )

    /// Turns spoken layout commands into what was meant. Deliberately
    /// conservative: only "new line" / "new paragraph", which are almost
    /// never literal content — punctuation words ("period", "comma") are
    /// too ambiguous to replace blindly.
    static func applySpokenFormatting(to text: String) -> String {
        var s = text
        s = s.replacingOccurrences(
            of: #"(?i)[,.]?\s*\bnew paragraph\b[,.]?\s*"#,
            with: "\n\n", options: .regularExpression)
        s = s.replacingOccurrences(
            of: #"(?i)[,.]?\s*\bnew line\b[,.]?\s*"#,
            with: "\n", options: .regularExpression)
        return s
    }
}
