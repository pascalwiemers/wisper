import AppKit

/// Runs async work from the CLI while keeping the main run loop alive —
/// blocking main with a semaphore deadlocks libraries that hop to it
/// (MLX's downloader does).
func runBlockingOnRunLoop(_ work: @escaping @Sendable () async -> Void) {
    final class Flag: @unchecked Sendable { var done = false }
    let flag = Flag()
    Task.detached {
        await work()
        flag.done = true
    }
    while !flag.done {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
}

// Developer test mode: `Wisper --clean-best "um so uh some raw text"` runs the
// Qwen "Best" tier (downloading the model if needed) and exits.
if let flagIndex = CommandLine.arguments.firstIndex(of: "--clean-best"),
   CommandLine.arguments.count > flagIndex + 1 {
    let input = CommandLine.arguments[(flagIndex + 1)...].joined(separator: " ")
    let dictionary = PersonalDictionary()
    let raw = dictionary.applyReplacements(to: input)
    let vocabulary = dictionary.vocabulary
    runBlockingOnRunLoop {
        let qwen = QwenCleaner()
        do {
            try await qwen.load()
            let cleaned = await qwen.clean(raw, vocabulary: vocabulary)
            print(cleaned ?? raw)
        } catch {
            print("qwen load failed: \(error)")
        }
    }
    exit(0)
}

// Developer test mode: `Wisper --clean "um so uh some raw text"` prints the
// cleaned version and exits, without starting the app.
if let flagIndex = CommandLine.arguments.firstIndex(of: "--clean"),
   CommandLine.arguments.count > flagIndex + 1 {
    let input = CommandLine.arguments[(flagIndex + 1)...].joined(separator: " ")
    let dictionary = PersonalDictionary()
    let raw = dictionary.applyReplacements(to: input)
    let vocabulary = dictionary.vocabulary
    if #available(macOS 26.0, *) {
        runBlockingOnRunLoop {
            let cleaner = Cleaner()
            cleaner.prepare()
            let cleaned = await cleaner.clean(raw, vocabulary: vocabulary)
            print(cleaned)
        }
    } else {
        print(raw)
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
