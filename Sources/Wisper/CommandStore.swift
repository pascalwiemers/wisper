import Foundation

struct VoiceCommand: Identifiable, Codable, Equatable {
    var id = UUID()
    var trigger: String
    var prompt: String
}

/// User-configurable voice commands for command mode (hold Fn+Shift).
/// A spoken utterance containing a trigger phrase runs its prompt against
/// the selected text (or the last dictation). Utterances matching nothing
/// are treated as free-form instructions themselves.
final class CommandStore {
    private(set) var commands: [VoiceCommand] = []
    private let fileURL: URL

    static let defaults: [VoiceCommand] = [
        VoiceCommand(trigger: "fix grammar", prompt: "Fix grammar, spelling, and punctuation. Change wording only where needed."),
        VoiceCommand(trigger: "more formal", prompt: "Rewrite in a more formal, professional tone. Keep all content."),
        VoiceCommand(trigger: "more casual", prompt: "Rewrite in a relaxed, casual tone. Keep all content."),
        VoiceCommand(trigger: "shorter", prompt: "Make it significantly more concise while keeping every key point."),
        VoiceCommand(trigger: "bullet points", prompt: "Convert into concise bullet points, one point per line starting with '- '."),
        VoiceCommand(trigger: "translate to english", prompt: "Translate to natural English."),
        VoiceCommand(trigger: "translate to german", prompt: "Translate to natural German."),
    ]

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wisper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("commands.json")
        reload()
    }

    var fileURLForSync: URL { fileURL }

    func reload() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([VoiceCommand].self, from: data) {
            commands = decoded
        } else {
            commands = Self.defaults
            persist()
        }
    }

    func save(_ newCommands: [VoiceCommand]) {
        commands = newCommands.filter {
            !$0.trigger.trimmingCharacters(in: .whitespaces).isEmpty
                && !$0.prompt.trimmingCharacters(in: .whitespaces).isEmpty
        }
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(commands) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Finds the command whose trigger phrase appears in the utterance;
    /// the longest trigger wins ("translate to german" over "translate").
    func match(_ utterance: String) -> VoiceCommand? {
        let normalized = Self.normalize(utterance)
        return commands
            .filter { normalized.contains(Self.normalize($0.trigger)) }
            .max { $0.trigger.count < $1.trigger.count }
    }

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
