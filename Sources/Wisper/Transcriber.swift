import Foundation
import FluidAudio

/// Wraps FluidAudio's Parakeet TDT v3 ASR. Models (~600 MB) are downloaded on
/// first launch and cached by FluidAudio; the manager stays warm afterwards.
actor Transcriber {
    private var manager: AsrManager?

    func load() async throws {
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager else {
            throw NSError(domain: "Wisper", code: 2, userInfo: [NSLocalizedDescriptionKey: "Model not loaded"])
        }
        // Each dictation is independent, so start from a fresh decoder state.
        var decoderState = TdtDecoderState.make()
        let result = try await manager.transcribe(samples, decoderState: &decoderState)
        return result.text
    }
}
