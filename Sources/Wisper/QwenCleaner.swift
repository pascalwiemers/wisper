import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// The "Best" cleanup tier: Qwen3-4B-Instruct (4-bit) running locally via
/// MLX on the GPU. Slower and heavier than Apple's model (~2.3 GB download,
/// ~4 GB RAM while loaded) but markedly better at self-correction repair,
/// and it has no content guardrails to false-positive on dictation.
actor QwenCleaner {
    static let modelID = "mlx-community/Qwen3-4B-Instruct-2507-4bit"

    private var container: ModelContainer?
    private var loadTask: Task<Void, Error>?

    var isReady: Bool { container != nil }

    /// Kicks off a background load without waiting — called on Fn-down in
    /// lazy mode so the reload hides behind the user's own speaking time.
    func ensureLoading() {
        guard container == nil, loadTask == nil else { return }
        loadTask = Task { [weak self] in try await self?.performLoad() }
    }

    /// Loads and waits until ready.
    func load() async throws {
        if container != nil { return }
        ensureLoading()
        try await loadTask?.value
    }

    private func performLoad() async throws {
        wlog("qwen: loading \(Self.modelID)…")
        let start = Date()
        do {
            container = try await loadModelContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                configuration: ModelConfiguration(id: Self.modelID)
            )
            wlog("qwen: ready in \(Int(Date().timeIntervalSince(start)))s")
        } catch {
            loadTask = nil
            throw error
        }
        loadTask = nil
    }

    /// Frees the ~4 GB of weights (tier switched to Fast, or idle unload).
    func unload() {
        loadTask?.cancel()
        loadTask = nil
        guard container != nil else { return }
        container = nil
        wlog("qwen: unloaded")
    }

    /// Returns cleaned text, or nil if the model isn't loaded or fails —
    /// the caller falls back to the Fast tier. If a load is in flight
    /// (lazy mode), waits for it rather than falling back.
    func clean(_ raw: String, vocabulary: [String]) async -> String? {
        if container == nil, let loadTask {
            try? await loadTask.value
        }
        guard let container else { return nil }
        let input = CleanupText.stripLeadingFillers(from: raw)
        do {
            let session = ChatSession(
                container,
                instructions: CleanupText.instructions,
                generateParameters: GenerateParameters(temperature: 0.0)
            )
            var output = try await session.respond(to: CleanupText.prompt(for: input, vocabulary: vocabulary))
            // Defensive: strip any reasoning block a Qwen variant might emit.
            output = output.replacingOccurrences(
                of: #"(?s)<think>.*?</think>"#,
                with: "", options: .regularExpression)
            return CleanupText.postprocess(output, input: input)
        } catch {
            wlog("qwen: clean failed (\(error))")
            return nil
        }
    }
}
