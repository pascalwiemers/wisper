import Foundation
import FoundationModels

/// The "Fast" cleanup tier: Apple's on-device model (FoundationModels,
/// macOS 26+). Falls back to regex cleanup on any failure — losing the
/// user's words is never acceptable.
@available(macOS 26.0, *)
@Generable
struct CleanedDictation {
    @Guide(description: "The cleaned dictation text and absolutely nothing else — no preamble, no commentary.")
    var text: String
}

@available(macOS 26.0, *)
final class Cleaner {
    /// Relaxed guardrails intended for apps that transform user-authored
    /// content (our case: the user's own dictation). The default guardrails
    /// false-positive on harmless dictations ("test if this pill works").
    private static let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)

    private var available = false

    func prepare() {
        switch Self.model.availability {
        case .available:
            available = true
            // Warm the model so the first dictation doesn't pay load latency.
            let session = LanguageModelSession(model: Self.model, instructions: CleanupText.instructions(options: .allOn))
            session.prewarm()
            wlog("cleaner: FoundationModels available, prewarmed")
        case .unavailable(let reason):
            available = false
            wlog("cleaner: FoundationModels unavailable (\(reason)) — dictations will be delivered raw")
        }
    }

    var isAvailable: Bool { available }

    /// Returns the cleaned text, or a regex-cleaned fallback if the LLM is
    /// unavailable or refuses. `vocabulary` is the personal dictionary: words
    /// this speaker actually uses, preferred over similar-sounding mishearings.
    func clean(_ raw: String, vocabulary: [String] = [], options: OutputOptions = .allOn) async -> String {
        let raw = CleanupText.stripLeadingFillers(from: raw, options: options)
        guard available else {
            return CleanupText.polish(CleanupText.stripFillersEverywhere(from: raw, options: options), options: options)
        }

        if let cleaned = await attempt(raw, vocabulary: vocabulary, options: options) {
            return cleaned
        }
        // Apple's guardrails false-positive on harmless dictations even in
        // permissive mode (e.g. "cut out my ums" misheard as "my arms").
        // Retry once on filler-stripped text, then fall back to regex-only —
        // never lose the words.
        let stripped = CleanupText.stripFillersEverywhere(from: raw, options: options)
        if let cleaned = await attempt(stripped, vocabulary: vocabulary, options: options) {
            wlog("cleaner: retry on stripped text succeeded")
            return cleaned
        }
        wlog("cleaner: LLM refused this text twice, using regex fallback")
        return CleanupText.polish(stripped, options: options)
    }

    private func attempt(_ text: String, vocabulary: [String], options: OutputOptions) async -> String? {
        do {
            // A fresh session per dictation: each cleanup is independent, and
            // reusing a session would grow its transcript context forever.
            let session = LanguageModelSession(model: Self.model, instructions: CleanupText.instructions(options: options))
            let response = try await session.respond(
                to: CleanupText.prompt(for: text, vocabulary: vocabulary),
                generating: CleanedDictation.self,
                options: GenerationOptions(temperature: 0.0)
            )
            return CleanupText.postprocess(response.content.text, input: text, options: options)
        } catch {
            wlog("cleaner: attempt failed (\(error))")
            return nil
        }
    }

    /// Command mode: apply an instruction to text ("make it more formal").
    /// Returns nil on failure so the caller can fall back or report.
    func transform(text: String, instruction: String) async -> String? {
        guard available else { return nil }
        do {
            let session = LanguageModelSession(model: Self.model, instructions: CleanupText.transformInstructions)
            let response = try await session.respond(
                to: CleanupText.transformPrompt(text: text, instruction: instruction),
                generating: CleanedDictation.self,
                options: GenerationOptions(temperature: 0.0)
            )
            let result = response.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return result.isEmpty ? nil : result
        } catch {
            wlog("cleaner: transform failed (\(error))")
            return nil
        }
    }
}
