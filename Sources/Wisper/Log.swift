import Foundation

/// Appends to ~/Library/Application Support/Wisper/wisper.log (and NSLog),
/// since unified-log privacy makes NSLog hard to read back during development.
private let logRotationCheck: Void = {
    // Once per launch: keep the log from growing forever (5 MB cap).
    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Wisper/wisper.log")
    if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
       size > 5_000_000 {
        try? FileManager.default.removeItem(at: url)
    }
}()

func wlog(_ message: String) {
    _ = logRotationCheck
    NSLog("Wisper: %@", message)
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Wisper", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("wisper.log")

    let formatter = ISO8601DateFormatter()
    let line = "\(formatter.string(from: Date())) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: url)
    }
}
