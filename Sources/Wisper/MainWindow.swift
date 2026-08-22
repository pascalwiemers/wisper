import SwiftUI
import AppKit
import AVFoundation
import ServiceManagement

enum CleanupTier: String {
    case fast
    case best
}

enum QwenResidency: String {
    /// Model stays in memory (~4 GB) while the Best tier is selected.
    case resident
    /// Model unloads after an idle period and reloads on the next dictation.
    case lazyUnload
}

/// Shared app state the window observes (model status in the sidebar footer,
/// cleanup engine selection).
final class AppState: ObservableObject {
    @Published var modelReady = false
    @Published var modelStatus = "Loading model…"
    @Published var cleanupTier = CleanupTier(rawValue: UserDefaults.standard.string(forKey: "cleanupTier") ?? "") ?? .fast
    @Published var bestTierStatus = ""
    @Published var qwenResidency = QwenResidency(rawValue: UserDefaults.standard.string(forKey: "qwenResidency") ?? "") ?? .resident
    @Published var qwenIdleMinutes = UserDefaults.standard.object(forKey: "qwenIdleMinutes") as? Int ?? 15
}

/// The app's main window: a native sidebar layout. The waveform mark is the
/// app's identity — the same shape as the recording pill.
struct MainWindowView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case history = "History"
        case stats = "Stats"
        case dictionary = "Dictionary"
        case commands = "Commands"
        case skills = "Skills"
        case settings = "Settings"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .history: "quote.bubble"
            case .stats: "chart.bar.xaxis"
            case .dictionary: "character.book.closed"
            case .commands: "wand.and.stars"
            case .skills: "sparkles.rectangle.stack"
            case .settings: "gearshape"
            }
        }
    }

    @State var selectedTab: Tab
    @ObservedObject var appState: AppState
    let rowsProvider: () -> [TranscriptStore.Row]
    let dictionary: PersonalDictionary
    let commandStore: CommandStore
    let skillStore: SkillStore
    let deleteHistory: () -> Void
    let analyzeStyle: (String) async -> String?

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    WaveformMark()
                        .frame(width: 26, height: 20)
                    Text("Wisper")
                        .font(.title3.weight(.semibold))
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 10)

                List(Tab.allCases, selection: $selectedTab) { tab in
                    Label(tab.rawValue, systemImage: tab.symbol)
                        .tag(tab)
                }
                .listStyle(.sidebar)

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    Circle()
                        .fill(appState.modelReady ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(appState.modelStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            switch selectedTab {
            case .history: HistoryView(rowsProvider: rowsProvider)
            case .stats: StatsTab(rowsProvider: rowsProvider, analyzeStyle: analyzeStyle)
            case .dictionary: DictionaryView(dictionary: dictionary)
            case .commands: CommandsView(store: commandStore)
            case .skills: SkillsView(store: skillStore)
            case .settings: SettingsView(appState: appState, deleteHistory: deleteHistory)
            }
        }
        .frame(minWidth: 700, minHeight: 480)
    }
}

/// The app's mark: the recording pill's bars, frozen mid-word.
struct WaveformMark: View {
    private let heights: [CGFloat] = [0.35, 0.7, 1.0, 0.55, 0.8, 0.4]

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: geo.size.width / 14) {
                ForEach(heights.indices, id: \.self) { i in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(height: geo.size.height * heights[i])
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}

// MARK: - History

private struct HistoryView: View {
    let rowsProvider: () -> [TranscriptStore.Row]
    @State private var sections: [(title: String, rows: [TranscriptStore.Row])] = []

    var body: some View {
        Group {
            if sections.isEmpty {
                VStack(spacing: 14) {
                    WaveformMark()
                        .frame(width: 44, height: 32)
                        .opacity(0.5)
                    Text("Nothing here yet")
                        .font(.title3.weight(.medium))
                    Text("Hold **Fn** anywhere and say something.\nEvery dictation shows up here — the delivered text and what you actually said.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8, pinnedViews: []) {
                        ForEach(sections, id: \.title) { section in
                            Text(section.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .padding(.horizontal, 4)
                                .padding(.top, 14)
                            ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                                HistoryCard(row: row)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
        .navigationTitle("History")
        .toolbar {
            Button {
                reload()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        let rows = rowsProvider().reversed()
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateStyle = .medium

        var grouped: [(String, [TranscriptStore.Row])] = []
        for row in rows {
            let title: String
            if calendar.isDateInToday(row.timestamp) {
                title = "Today"
            } else if calendar.isDateInYesterday(row.timestamp) {
                title = "Yesterday"
            } else {
                title = formatter.string(from: row.timestamp)
            }
            if grouped.last?.0 == title {
                grouped[grouped.count - 1].1.append(row)
            } else {
                grouped.append((title, [row]))
            }
        }
        sections = grouped
    }
}

private struct HistoryCard: View {
    let row: TranscriptStore.Row
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(row.clean ?? row.raw)
                .font(.system(.body, design: .serif))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if let clean = row.clean, clean != row.raw {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(row.raw)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                Text(row.timestamp, format: .dateTime.hour().minute())
                if let app = row.appBundleID {
                    Text(Self.appName(app))
                }
                Text(row.delivery == "pasted" ? "pasted" : "copied")
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary.opacity(0.6)))
                Spacer()
                if hovering {
                    if let ms = row.asrMs {
                        Text("\(ms + (row.cleanupMs ?? 0)) ms")
                    }
                    Button("Copy") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(row.clean ?? row.raw, forType: .string)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(height: 16)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(hovering ? AnyShapeStyle(.quaternary.opacity(0.55)) : AnyShapeStyle(.quaternary.opacity(0.35)))
        )
        .onHover { hovering = $0 }
    }

    static func appName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let name = Bundle(url: url)?.infoDictionary?["CFBundleName"] as? String {
            return name
        }
        return bundleID
    }
}

// MARK: - Stats

private struct StatsTab: View {
    let rowsProvider: () -> [TranscriptStore.Row]
    let analyzeStyle: (String) async -> String?
    @State private var rows: [TranscriptStore.Row] = []
    @State private var analysis: String?
    @State private var analyzing = false

    var body: some View {
        VStack(spacing: 0) {
            StatsView(summary: StatsSummary.compute(from: rows), rows: rows)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button {
                        runAnalysis()
                    } label: {
                        Label(analyzing ? "Analyzing…" : "Analyze my style", systemImage: "wand.and.stars")
                    }
                    .disabled(analyzing || rows.count < 5)
                    if rows.count < 5 {
                        Text("Needs at least 5 dictations.").font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                if let analysis {
                    ScrollView {
                        Text(analysis)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.35)))
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .navigationTitle("Stats")
        .onAppear { rows = rowsProvider() }
    }

    private func runAnalysis() {
        analyzing = true
        let sample = rows.suffix(40).map(\.raw).joined(separator: "\n").suffix(6000)
        Task {
            let result = await analyzeStyle(String(sample))
            await MainActor.run {
                analysis = result ?? "Analysis needs a cleanup engine (Apple Intelligence or the Qwen tier)."
                analyzing = false
            }
        }
    }
}

// MARK: - Commands

private struct CommandsView: View {
    let store: CommandStore
    @State private var items: [VoiceCommand] = []
    @State private var loaded = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hold **Fn + Shift** and speak to edit text instead of dictating: the command runs on your selected text, or on your last dictation.")
                        .font(.callout)
                    Text("Say a trigger phrase below, or any free-form instruction (“translate this to French”). “Scratch that” deletes the last thing Wisper pasted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    ForEach($items) { $item in
                        HStack(spacing: 8) {
                            TextField("trigger phrase…", text: $item.trigger)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 170)
                            Image(systemName: "arrow.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("what to do with the text…", text: $item.prompt)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                items.removeAll { $0.id == item.id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove this command")
                        }
                    }
                    Button {
                        items.append(VoiceCommand(trigger: "", prompt: ""))
                    } label: {
                        Label("Add command", systemImage: "plus")
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.35)))

                Text("Changes save automatically.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(20)
        }
        .navigationTitle("Commands")
        .onAppear {
            items = store.commands
            loaded = true
        }
        .onChange(of: items) { _, _ in
            guard loaded else { return }
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run { store.save(items) }
            }
        }
    }
}

// MARK: - Dictionary

private struct ReplacementItem: Identifiable, Equatable {
    let id = UUID()
    var from: String
    var to: String
}

private struct DictionaryView: View {
    let dictionary: PersonalDictionary

    @State private var words: [String] = []
    @State private var replacements: [ReplacementItem] = []
    @State private var newWord = ""
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Vocabulary
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader(
                        "Your words",
                        "Names and jargon you actually say. Cleanup prefers these over similar-sounding mishearings; frequent words are added automatically."
                    )

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(words, id: \.self) { word in
                            WordChip(word: word) {
                                words.removeAll { $0 == word }
                                save()
                            }
                        }
                    }

                    TextField("Add a word…", text: $newWord)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                        .onSubmit {
                            let word = newWord.trimmingCharacters(in: .whitespaces)
                            guard !word.isEmpty, !words.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) else {
                                newWord = ""
                                return
                            }
                            words.append(word)
                            words.sort { $0.lowercased() < $1.lowercased() }
                            newWord = ""
                            save()
                        }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.35)))

                // Replacements
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader(
                        "Replacements",
                        "For mishearings that keep coming back: whenever the left side is transcribed, the right side is used instead."
                    )

                    if replacements.isEmpty {
                        Text("None yet. When a word keeps getting misheard, add the fix here.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }

                    ForEach($replacements) { $item in
                        HStack(spacing: 8) {
                            TextField("heard as…", text: $item.from)
                                .textFieldStyle(.roundedBorder)
                            Image(systemName: "arrow.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("should be…", text: $item.to)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                replacements.removeAll { $0.id == item.id }
                                save()
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove this replacement")
                        }
                    }

                    Button {
                        replacements.append(ReplacementItem(from: "", to: ""))
                    } label: {
                        Label("Add replacement", systemImage: "plus")
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.35)))

                Text("Changes save automatically and apply to your next dictation.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(20)
        }
        .navigationTitle("Dictionary")
        .onAppear { load() }
        .onChange(of: replacements) { _, _ in
            guard loaded else { return }
            scheduleSave()
        }
    }

    private func sectionHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func load() {
        dictionary.reload()
        words = dictionary.vocabulary.sorted { $0.lowercased() < $1.lowercased() }
        replacements = dictionary.replacements.map { ReplacementItem(from: $0.from, to: $0.to) }
        loaded = true
    }

    @State private var saveTask: Task<Void, Never>?

    /// Debounced save while the user is typing in a replacement field.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { save() }
        }
    }

    private func save() {
        dictionary.save(
            vocabulary: words,
            replacements: replacements.map { (from: $0.from, to: $0.to) }
        )
    }
}

private struct WordChip: View {
    let word: String
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(word)
                .font(.callout)
                .lineLimit(1)
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("Remove “\(word)”")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(.quaternary.opacity(hovering ? 0.7 : 0.5)))
        .onHover { hovering = $0 }
    }
}

// MARK: - Skills

private struct SkillsView: View {
    let store: SkillStore

    @State private var skills: [Skill] = []
    @State private var selectedName: String?
    @State private var editorContent = ""
    @State private var editorName = ""
    @State private var importRepo = ""
    @State private var importStatus = ""
    @State private var importing = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hold **Fn + Control** and say a skill's name — “tdd”, “use the code review skill” — and its full text is pasted. Handy for dropping reusable prompts into LLM chats.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HSplitView {
                VStack(spacing: 6) {
                    List(skills, id: \.name, selection: $selectedName) { skill in
                        Text(skill.name).tag(skill.name)
                    }
                    HStack(spacing: 8) {
                        Button {
                            let skill = Skill(name: "new skill \(skills.count + 1)", content: "")
                            store.save(skill)
                            refresh(selecting: skill.name)
                        } label: { Image(systemName: "plus") }
                        Button {
                            if let selectedName { store.delete(selectedName) }
                            refresh(selecting: nil)
                        } label: { Image(systemName: "minus") }
                        .disabled(selectedName == nil)
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
                }
                .frame(minWidth: 150, maxWidth: 220)

                VStack(alignment: .leading, spacing: 8) {
                    if selectedName != nil {
                        TextField("Skill name (what you say)", text: $editorName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { commitRename() }
                        TextEditor(text: $editorContent)
                            .font(.system(.callout, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.35)))
                    } else {
                        Spacer()
                        Text(skills.isEmpty ? "No skills yet — add one, or import a repo below." : "Select a skill to edit it.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                        Spacer()
                    }
                }
                .padding(.leading, 10)
                .frame(minWidth: 320)
            }

            HStack(spacing: 8) {
                TextField("owner/repo or GitHub URL to import (looks for SKILL.md files)", text: $importRepo)
                    .textFieldStyle(.roundedBorder)
                Button(importing ? "Importing…" : "Import") { runImport(importRepo) }
                    .disabled(importing || importRepo.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Import mattpocock/skills") { runImport("mattpocock/skills") }
                    .disabled(importing)
            }
            if !importStatus.isEmpty {
                Text(importStatus).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .navigationTitle("Skills")
        .onAppear { refresh(selecting: nil) }
        .onChange(of: selectedName) { _, newValue in
            saveTask?.cancel()
            if let newValue, let skill = skills.first(where: { $0.name == newValue }) {
                editorName = skill.name
                editorContent = skill.content
            }
        }
        .onChange(of: editorContent) { _, newValue in
            guard let selectedName, skills.first(where: { $0.name == selectedName })?.content != newValue else { return }
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    store.save(Skill(name: selectedName, content: newValue))
                    skills = store.skills
                }
            }
        }
    }

    private func commitRename() {
        guard let selectedName, editorName != selectedName else { return }
        store.rename(selectedName, to: editorName)
        refresh(selecting: editorName)
    }

    private func refresh(selecting: String?) {
        store.reload()
        skills = store.skills
        selectedName = selecting ?? skills.first?.name
        if let selectedName, let skill = skills.first(where: { $0.name == selectedName }) {
            editorName = skill.name
            editorContent = skill.content
        }
    }

    private func runImport(_ repo: String) {
        importing = true
        importStatus = "Downloading \(repo)…"
        Task {
            do {
                let count = try await store.importFromGitHub(repo: repo)
                await MainActor.run {
                    importStatus = count > 0 ? "Imported \(count) skills." : "No SKILL.md files found in that repo."
                    importing = false
                    refresh(selecting: nil)
                }
            } catch {
                await MainActor.run {
                    importStatus = error.localizedDescription
                    importing = false
                }
            }
        }
    }
}

// MARK: - Settings

private struct SettingsView: View {
    @ObservedObject var appState: AppState
    let deleteHistory: () -> Void
    @AppStorage("cleanupEnabled") private var cleanupEnabled = true
    @AppStorage("preferBuiltInMic") private var preferBuiltInMic = true
    @AppStorage("out.pasteAutomatically") private var pasteAutomatically = true
    @AppStorage("out.restoreClipboard") private var restoreClipboard = true
    @AppStorage("out.capitalizeSentences") private var capitalizeSentences = true
    @AppStorage("out.tidyPunctuation") private var tidyPunctuation = true
    @AppStorage("out.removeFillers") private var removeFillers = true
    @AppStorage("out.spokenFormatting") private var spokenFormatting = true
    @AppStorage("out.applyCorrections") private var applyCorrections = true
    @AppStorage("out.editStrength") private var editStrength = EditStrength.standard.rawValue
    @AppStorage("historyEnabled") private var historyEnabled = true
    @State private var startAtLogin = SMAppService.mainApp.status == .enabled
    @State private var confirmDelete = false
    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var axTrusted = AXIsProcessTrusted()

    var body: some View {
        Form {
            Section("Dictation") {
                Toggle("Clean up text with on-device AI", isOn: $cleanupEnabled)
                Text("The full cleanup pass. Dictations under 4 words skip it for zero latency. The raw words are always kept in History.")
                    .font(.caption).foregroundStyle(.secondary)

                Picker("Cleanup strength", selection: $editStrength) {
                    Text("Light").tag(EditStrength.light.rawValue)
                    Text("Standard").tag(EditStrength.standard.rawValue)
                    Text("Heavy").tag(EditStrength.heavy.rawValue)
                }
                .pickerStyle(.segmented)
                Text("How much the cleanup may change. Light: fillers and punctuation only — wording stays exactly as spoken. Standard: also collapses false starts and self-corrections. Heavy: additionally tightens rambling phrasing. Deliberate repetition (“for real, for real”) is kept at every strength.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Prefer built-in microphone", isOn: $preferBuiltInMic)
                Text("Keeps AirPods out of low-quality call mode while you dictate.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Output") {
                toggleRow("Paste automatically", $pasteAutomatically,
                          "Paste into whatever has focus. Off: only copy to the clipboard.")
                toggleRow("Restore my clipboard", $restoreClipboard,
                          "Put back what was on the clipboard after pasting. Turn off if pastes arrive empty in a particular app.")
                toggleRow("Capitalize sentences", $capitalizeSentences,
                          "Start each sentence with a capital letter.")
                toggleRow("Tidy punctuation", $tidyPunctuation,
                          "Normalize spacing and add terminal punctuation.")
                toggleRow("Remove filler words", $removeFillers,
                          "Drop “um”, “uh” and similar so speech reads like writing.")
                toggleRow("Spoken formatting", $spokenFormatting,
                          "Turn “new line” and “new paragraph” into the thing you said.")
                toggleRow("Apply spoken corrections", $applyCorrections,
                          "When you correct yourself out loud — “Monday, no wait, Tuesday” — keep only the correction.")
            }

            Section("Cleanup engine") {
                Picker("Engine", selection: $appState.cleanupTier) {
                    Text("Fast — Apple on-device").tag(CleanupTier.fast)
                    Text("Best — Qwen 4B via MLX").tag(CleanupTier.best)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text("Best fixes tangled self-corrections the Fast engine can't, at the cost of ~1 s extra per dictation and ~4 GB of memory while loaded. Downloads ~2.3 GB once.")
                    .font(.caption).foregroundStyle(.secondary)

                if appState.cleanupTier == .best {
                    Picker("Memory", selection: $appState.qwenResidency) {
                        Text("Keep loaded — fastest").tag(QwenResidency.resident)
                        Text("Unload when idle").tag(QwenResidency.lazyUnload)
                    }
                    if appState.qwenResidency == .lazyUnload {
                        Picker("Unload after", selection: $appState.qwenIdleMinutes) {
                            Text("5 minutes").tag(5)
                            Text("15 minutes").tag(15)
                            Text("30 minutes").tag(30)
                            Text("1 hour").tag(60)
                        }
                        Text("Reloading starts the moment you press Fn, so most of the ~4 s reload hides behind your speaking. A very short first dictation after idle may wait briefly.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if !appState.bestTierStatus.isEmpty {
                    Text(appState.bestTierStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("App") {
                Toggle("Start at login", isOn: $startAtLogin)
                    .onChange(of: startAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            wlog("login item toggle failed: \(error)")
                            startAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section("Permissions") {
                permissionRow("Microphone", granted: micGranted,
                              pane: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                permissionRow("Accessibility (Fn key + pasting)", granted: axTrusted,
                              pane: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            }

            Section("Privacy") {
                Toggle("Save transcript history", isOn: $historyEnabled)
                Text("History powers the Stats tab and dictation recovery. It never leaves this Mac either way.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Delete All History…", role: .destructive) { confirmDelete = true }
                    Button("Reveal Data Folder") {
                        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                            .appendingPathComponent("Wisper")
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    }
                }
                .confirmationDialog("Delete every saved transcript? This cannot be undone.", isPresented: $confirmDelete) {
                    Button("Delete All History", role: .destructive) { deleteHistory() }
                }
            }

            Section("How to dictate") {
                Text("Hold **Fn**, speak, release. **Esc** while holding cancels. **Fn + Shift** = command mode (Commands tab). **Fn + Control** = paste a skill by name (Skills tab). Recordings cap at 5 minutes. If no text field is focused, the text lands on your clipboard. Everything runs on this Mac — nothing is sent anywhere.")
                    .font(.callout)
            }

            Section("About") {
                HStack {
                    WaveformMark().frame(width: 22, height: 16)
                    Text("Wisper \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                    Spacer()
                    Button("GitHub") {
                        NSWorkspace.shared.open(URL(string: "https://github.com/pascalwiemers/wisper")!)
                    }
                    .buttonStyle(.link)
                }
                Text("Parakeet TDT v3 for speech, Apple Intelligence or Qwen 4B for cleanup — all on-device.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear {
            micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            axTrusted = AXIsProcessTrusted()
        }
    }

    private func permissionRow(_ title: String, granted: Bool, pane: String) -> some View {
        HStack {
            Circle().fill(granted ? Color.green : Color.orange).frame(width: 8, height: 8)
            Text(title)
            Spacer()
            if granted {
                Text("Granted").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Open Settings…") { NSWorkspace.shared.open(URL(string: pane)!) }
            }
        }
    }

    private func toggleRow(_ title: String, _ binding: Binding<Bool>, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: binding)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
