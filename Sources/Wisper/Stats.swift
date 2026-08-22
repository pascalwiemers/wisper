import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Stats computation

struct StatsSummary {
    var totalDictations = 0
    var wordsToday = 0
    var wordsThisWeek = 0
    var wordsAllTime = 0
    var totalSpeechSeconds = 0.0
    var speakingWPM = 0.0
    var minutesSaved = 0.0
    var topApps: [(name: String, count: Int)] = []
    var topFillers: [(word: String, count: Int)] = []
    var fillerPer100Words = 0.0
    var totalFillers = 0
    var vocabularyRichness = 0.0
    var medianAsrMs = 0
    var medianCleanupMs = 0

    /// Words-per-minute a person types on average; Wispr uses a similar
    /// assumption for its "time saved" number.
    static let assumedTypingWPM = 45.0

    static let fillerSingles = ["um", "uh", "er", "ah", "hmm", "like", "basically", "actually", "literally"]
    static let fillerPhrases = ["you know", "i mean", "sort of", "kind of"]

    static func compute(from rows: [TranscriptStore.Row]) -> StatsSummary {
        var s = StatsSummary()
        guard !rows.isEmpty else { return s }

        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfWeek = calendar.date(byAdding: .day, value: -6, to: startOfToday)!

        var appCounts: [String: Int] = [:]
        var fillerCounts: [String: Int] = [:]
        var uniqueWords = Set<String>()
        var asrTimes: [Int] = []
        var cleanupTimes: [Int] = []

        for row in rows {
            s.totalDictations += 1
            s.wordsAllTime += row.wordCount
            s.totalSpeechSeconds += row.durationSeconds
            if row.timestamp >= startOfToday { s.wordsToday += row.wordCount }
            if row.timestamp >= startOfWeek { s.wordsThisWeek += row.wordCount }
            if let app = row.appBundleID { appCounts[app, default: 0] += 1 }
            if let ms = row.asrMs { asrTimes.append(ms) }
            if let ms = row.cleanupMs { cleanupTimes.append(ms) }

            let words = row.raw.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
                .filter { !$0.isEmpty }
            for word in words {
                uniqueWords.insert(word)
                if fillerSingles.contains(word) { fillerCounts[word, default: 0] += 1 }
            }
            let joined = words.joined(separator: " ")
            for phrase in fillerPhrases {
                var searchRange = joined.startIndex..<joined.endIndex
                while let found = joined.range(of: phrase, range: searchRange) {
                    fillerCounts[phrase, default: 0] += 1
                    searchRange = found.upperBound..<joined.endIndex
                }
            }
        }

        if s.totalSpeechSeconds > 0 {
            s.speakingWPM = Double(s.wordsAllTime) / (s.totalSpeechSeconds / 60)
        }
        s.minutesSaved = Double(s.wordsAllTime) / Self.assumedTypingWPM - s.totalSpeechSeconds / 60
        s.topApps = appCounts.sorted { $0.value > $1.value }.prefix(5)
            .map { (friendlyAppName($0.key), $0.value) }
        s.topFillers = fillerCounts.sorted { $0.value > $1.value }.prefix(6)
            .map { ($0.key, $0.value) }
        let totalFillers = fillerCounts.values.reduce(0, +)
        s.totalFillers = totalFillers
        if s.wordsAllTime > 0 {
            s.fillerPer100Words = Double(totalFillers) / Double(s.wordsAllTime) * 100
            s.vocabularyRichness = Double(uniqueWords.count) / Double(s.wordsAllTime)
        }
        s.medianAsrMs = median(of: asrTimes)
        s.medianCleanupMs = median(of: cleanupTimes)
        return s
    }

    private static func median(of values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func friendlyAppName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let name = Bundle(url: url)?.infoDictionary?["CFBundleName"] as? String {
            return name
        }
        return bundleID
    }
}

// MARK: - Stats window content

struct StatsView: View {
    let summary: StatsSummary
    let rows: [TranscriptStore.Row]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // The app's one boast, in its own words.
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(summary.wordsAllTime) words spoken")
                        .font(.system(.largeTitle, design: .serif).weight(.medium))
                    Text(heroLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 10)

                card("Usage") {
                    statRow("Dictations", "\(summary.totalDictations)")
                    statRow("Words today", "\(summary.wordsToday)")
                    statRow("Words this week", "\(summary.wordsThisWeek)")
                    statRow("Speaking pace", String(format: "%.0f words/min", summary.speakingWPM))
                    statRow("Time saved vs typing", formatMinutes(summary.minutesSaved))
                    statRow("Median transcription", "\(summary.medianAsrMs) ms")
                    if summary.medianCleanupMs > 0 {
                        statRow("Median cleanup", "\(summary.medianCleanupMs) ms")
                    }
                }

                card("Style") {
                    statRow("Filler words per 100", String(format: "%.1f", summary.fillerPer100Words))
                    statRow("Vocabulary richness", String(format: "%.0f%% unique words", summary.vocabularyRichness * 100))
                    if summary.topFillers.isEmpty {
                        Text("No filler words yet — impressive.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(summary.topFillers, id: \.word) { filler in
                            statRow("“\(filler.word)”", "\(filler.count)×")
                        }
                    }
                }

                card("Apps you dictate into") {
                    if summary.topApps.isEmpty {
                        Text("Nothing yet.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(summary.topApps, id: \.name) { app in
                            statRow(app.name, "\(app.count)")
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button("Export JSONL…") { export(format: .jsonl) }
                    Button("Export CSV…") { export(format: .csv) }
                }
            }
            .padding(20)
        }
    }

    private var heroLine: String {
        var parts: [String] = []
        if summary.minutesSaved > 1 {
            parts.append("about \(formatMinutes(summary.minutesSaved)) you didn't spend typing")
        }
        if summary.totalFillers > 0 {
            parts.append("\(summary.totalFillers) filler words never made it out")
        }
        return parts.isEmpty ? "Hold Fn and start talking." : parts.joined(separator: " — ")
    }

    @ViewBuilder
    private func card(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.35)))
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.callout)
    }

    private func formatMinutes(_ minutes: Double) -> String {
        guard minutes > 0 else { return "—" }
        if minutes < 60 { return String(format: "%.0f min", minutes) }
        return String(format: "%.1f h", minutes / 60)
    }

    // MARK: - Export

    private enum ExportFormat { case jsonl, csv }

    private func export(format: ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = format == .jsonl ? "wisper-transcripts.jsonl" : "wisper-transcripts.csv"
        panel.allowedContentTypes = [format == .jsonl ? UTType(filenameExtension: "jsonl") ?? .plainText : .commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let iso = ISO8601DateFormatter()
        var out = format == .csv ? "timestamp,app,delivery,duration_s,word_count,asr_ms,cleanup_ms,raw,clean\n" : ""
        for row in rows {
            switch format {
            case .jsonl:
                let object: [String: Any?] = [
                    "ts": iso.string(from: row.timestamp),
                    "raw": row.raw,
                    "clean": row.clean,
                    "duration_s": row.durationSeconds,
                    "word_count": row.wordCount,
                    "app": row.appBundleID,
                    "delivery": row.delivery,
                    "asr_ms": row.asrMs,
                    "cleanup_ms": row.cleanupMs,
                ]
                if let data = try? JSONSerialization.data(withJSONObject: object.compactMapValues { $0 }),
                   let line = String(data: data, encoding: .utf8) {
                    out += line + "\n"
                }
            case .csv:
                let fields: [String] = [
                    iso.string(from: row.timestamp),
                    row.appBundleID ?? "",
                    row.delivery,
                    String(format: "%.2f", row.durationSeconds),
                    "\(row.wordCount)",
                    row.asrMs.map(String.init) ?? "",
                    row.cleanupMs.map(String.init) ?? "",
                    csvEscape(row.raw),
                    csvEscape(row.clean ?? ""),
                ]
                out += fields.joined(separator: ",") + "\n"
            }
        }
        try? out.write(to: url, atomically: true, encoding: .utf8)
    }

    private func csvEscape(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
