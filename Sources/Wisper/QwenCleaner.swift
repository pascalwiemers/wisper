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
    func clean(_ raw: String, vocabulary: [String], options: OutputOptions = .allOn) async -> String? {
        let input = CleanupText.stripLeadingFillers(from: raw, options: options)
        guard let output = await respond(
            instructions: CleanupText.instructions(options: options),
            prompt: CleanupText.prompt(for: input, vocabulary: vocabulary)
        ) else { return nil }
        return CleanupText.postprocess(output, input: input, options: options)
    }

    /// Command mode: apply an instruction to text ("make it more formal").
    func transform(text: String, instruction: String) async -> String? {
        let result = await respond(
            instructions: CleanupText.transformInstructions,
            prompt: CleanupText.transformPrompt(text: text, instruction: instruction)
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (result?.isEmpty ?? true) ? nil : result
    }

    private func respond(instructions: String, prompt: String) async -> String? {
        if container == nil, let loadTask {
            try? await loadTask.value
        }
        guard let container else { return nil }

        // Runaway protection: a derailed generation once pinned the GPU at
        // 100% for minutes and queued every following dictation behind it.
        // Cap output tokens (cleanup output ≈ input size) and hard-stop via
        // cancellation after 30s — the MLX generate loop honors Task.isCancelled.
        var parameters = GenerateParameters(temperature: 0.0)
        parameters.maxTokens = max(256, min(1500, prompt.count / 3))

        let generation = Task {
            let session = ChatSession(container, instructions: instructions, generateParameters: parameters)
            return try await session.respond(to: prompt)
        }
        let watchdog = Task {
            try await Task.sleep(nanoseconds: 30_000_000_000)
            generation.cancel()
            wlog("qwen: generation timed out after 30s — cancelled")
        }
        defer { watchdog.cancel() }

        do {
            var output = try await generation.value
            // Defensive: strip any reasoning block a Qwen variant might emit.
            output = output.replacingOccurrences(
                of: #"(?s)<think>.*?</think>"#,
                with: "", options: .regularExpression)
            return output
        } catch {
            wlog("qwen: respond failed (\(error))")
            return nil
        }
    }
}
