import AppKit
import AVFoundation
import Combine
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hotkey = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let injector = Injector()
    private var store: TranscriptStore?
    private let indicator = IndicatorPanel()
    private let dictionary = PersonalDictionary()
    private let commandStore = CommandStore()
    private let skillStore = SkillStore()
    private let appState = AppState()
    private let qwenCleaner = QwenCleaner()
    private var cancellables = Set<AnyCancellable>()
    private var cleanerBox: Any?

    private var modelReady = false
    private var isProcessing = false
    private var recordingStartedAt: Date?
    private var lastTranscript: String?
    private var escapeMonitors: [Any] = []
    private var maxDurationTimer: Timer?
    private var qwenIdleTimer: Timer?
    private var partialTimer: Timer?
    private var partialInFlight = false
    private var recordingMode: RecordingMode = .dictation
    private var mainWindow: NSWindow?

    private var modelStatusItem: NSMenuItem!
    private var copyLastItem: NSMenuItem!
    private var pasteLastItem: NSMenuItem!
    private var cleanupItem: NSMenuItem!
    private var builtInMicItem: NSMenuItem!
    private var loginItem: NSMenuItem!

    // Ignore accidental taps shorter than this.
    private let minimumHoldSeconds: TimeInterval = 0.25
    /// A stuck Fn key must not record forever.
    private let maximumRecordingSeconds: TimeInterval = 300
    /// Utterances this short have nothing worth cleaning; skipping the LLM
    /// saves its latency entirely.
    private let minimumWordsForCleanup = 4

    private var cleanupEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "cleanupEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "cleanupEnabled") }
    }

    private var preferBuiltInMic: Bool {
        get { UserDefaults.standard.object(forKey: "preferBuiltInMic") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "preferBuiltInMic") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        store = TranscriptStore()
        requestPermissions()

        recorder.preferBuiltInMic = preferBuiltInMic
        recorder.onLevel = { [weak self] level in self?.indicator.setLevel(level) }

        hotkey.onFnDown = { [weak self] mode in self?.startDictation(mode: mode) }
        hotkey.onModeUpgrade = { [weak self] mode in
            if self?.recorder.isRecording == true { self?.recordingMode = mode }
        }
        hotkey.onFnUp = { [weak self] in self?.finishDictation() }
        hotkey.start()

        if #available(macOS 26.0, *) {
            let cleaner = Cleaner()
            cleanerBox = cleaner
            Task.detached { cleaner.prepare() }
        }

        // Cleanup tier: persist changes and manage the Qwen model lifecycle.
        appState.$cleanupTier
            .removeDuplicates()
            .sink { [weak self] tier in
                UserDefaults.standard.set(tier.rawValue, forKey: "cleanupTier")
                self?.handleTierChange(tier)
            }
            .store(in: &cancellables)

        appState.$qwenResidency
            .removeDuplicates()
            .sink { [weak self] residency in
                UserDefaults.standard.set(residency.rawValue, forKey: "qwenResidency")
                guard let self, self.appState.cleanupTier == .best else { return }
                switch residency {
                case .resident:
                    self.qwenIdleTimer?.invalidate()
                    self.handleTierChange(.best)
                case .lazyUnload:
                    self.scheduleQwenIdleUnload()
                }
            }
            .store(in: &cancellables)

        appState.$qwenIdleMinutes
            .removeDuplicates()
            .sink { [weak self] minutes in
                UserDefaults.standard.set(minutes, forKey: "qwenIdleMinutes")
                guard let self, self.appState.cleanupTier == .best,
                      self.appState.qwenResidency == .lazyUnload else { return }
                self.scheduleQwenIdleUnload()
            }
            .store(in: &cancellables)

        Task { await loadModel() }

        // Personalization: learn recurring names/jargon from dictation history.
        if let store {
            let rows = store.allRows()
            let dictionary = dictionary
            Task.detached(priority: .background) { dictionary.learn(from: rows) }
        }
    }

    /// Launching the app again (Spotlight, Finder, Dock) while it's running
    /// opens the main window — the natural "open the app" gesture.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow(tab: .history)
        return true
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(state: .loading)

        let menu = NSMenu()
        menu.delegate = self
        modelStatusItem = NSMenuItem(title: "Downloading model…", action: nil, keyEquivalent: "")
        modelStatusItem.isEnabled = false
        menu.addItem(modelStatusItem)
        menu.addItem(.separator())

        let openItem = NSMenuItem(title: "Open Wisper…", action: #selector(openWisperWindow), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())

        copyLastItem = NSMenuItem(title: "Copy Last Transcript", action: #selector(copyLast), keyEquivalent: "")
        copyLastItem.target = self
        copyLastItem.isEnabled = false
        menu.addItem(copyLastItem)

        pasteLastItem = NSMenuItem(title: "Paste Last Transcript", action: #selector(pasteLast), keyEquivalent: "")
        pasteLastItem.target = self
        pasteLastItem.isEnabled = false
        menu.addItem(pasteLastItem)
        menu.addItem(.separator())

        cleanupItem = NSMenuItem(title: "Clean Up Text", action: #selector(toggleCleanup), keyEquivalent: "")
        cleanupItem.target = self
        cleanupItem.state = cleanupEnabled ? .on : .off
        menu.addItem(cleanupItem)

        builtInMicItem = NSMenuItem(title: "Prefer Built-In Microphone", action: #selector(toggleBuiltInMic), keyEquivalent: "")
        builtInMicItem.target = self
        builtInMicItem.state = preferBuiltInMic ? .on : .off
        menu.addItem(builtInMicItem)

        loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())

        let statsMenuItem = NSMenuItem(title: "Stats…", action: #selector(openStats), keyEquivalent: "")
        statsMenuItem.target = self
        menu.addItem(statsMenuItem)

        let dictionaryMenuItem = NSMenuItem(title: "Edit Personal Dictionary…", action: #selector(openDictionary), keyEquivalent: "")
        dictionaryMenuItem.target = self
        menu.addItem(dictionaryMenuItem)

        let permsItem = NSMenuItem(title: "Open Accessibility Settings…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        permsItem.target = self
        menu.addItem(permsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Wisper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private enum IconState { case loading, idle, recording, processing }

    private func setIcon(state: IconState) {
        let (symbol, description): (String, String)
        switch state {
        case .loading: (symbol, description) = ("arrow.down.circle", "Wisper loading")
        case .idle: (symbol, description) = ("mic", "Wisper idle")
        case .recording: (symbol, description) = ("mic.fill", "Wisper recording")
        case .processing: (symbol, description) = ("waveform", "Wisper processing")
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        image?.isTemplate = state != .recording
        statusItem.button?.image = image
        statusItem.button?.contentTintColor = state == .recording ? .systemRed : nil
    }

    // MARK: - Permissions

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            guard granted else {
                wlog("microphone access not granted")
                return
            }
            // Touching AVAudioEngine.inputNode blocks on CoreAudio until mic
            // permission is resolved, so only pre-warm once we're granted.
            DispatchQueue.main.async { self?.recorder.prepare() }
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        wlog("launch: accessibility trusted=\(trusted)")
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Menu actions

    @objc private func toggleCleanup() {
        cleanupEnabled.toggle()
        cleanupItem.state = cleanupEnabled ? .on : .off
    }

    @objc private func toggleBuiltInMic() {
        preferBuiltInMic.toggle()
        recorder.preferBuiltInMic = preferBuiltInMic
        builtInMicItem.state = preferBuiltInMic ? .on : .off
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            wlog("login item toggle failed: \(error)")
        }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func openWisperWindow() {
        openMainWindow(tab: .history)
    }

    @objc private func openDictionary() {
        openMainWindow(tab: .dictionary)
    }

    @objc private func openStats() {
        openMainWindow(tab: .stats)
    }

    private func openMainWindow(tab: MainWindowView.Tab) {
        appState.selectedTab = tab

        if mainWindow == nil {
            let view = MainWindowView(
                appState: appState,
                rowsProvider: { [weak self] in self?.store?.allRows() ?? [] },
                dictionary: dictionary,
                commandStore: commandStore,
                skillStore: skillStore,
                deleteHistory: { [weak self] in self?.store?.deleteAll() },
                analyzeStyle: { [weak self] sample in
                    await self?.transform(
                        text: sample,
                        instruction: """
                        These are raw dictation transcripts from one speaker. Describe their speaking style: tone, sentence structure, recurring habits, filler patterns. Then give three short, concrete suggestions for clearer dictation. Address the speaker as "you". Under 200 words, plain prose.
                        """
                    )
                }
            )
            let controller = NSHostingController(rootView: view)
            // The window's size belongs to the user: never let a tab's ideal
            // size resize the window when the detail view swaps.
            controller.sizingOptions = []
            let window = NSWindow(contentViewController: controller)
            window.title = "Wisper"
            window.setContentSize(NSSize(width: 760, height: 560))
            window.isReleasedWhenClosed = false
            window.center()
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func copyLast() {
        guard let lastTranscript else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(lastTranscript, forType: .string)
        indicator.showMessage("Copied")
    }

    @objc private func pasteLast() {
        guard let lastTranscript else { return }
        // Give the user a beat to focus the target field after the menu closes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if self.injector.deliver(lastTranscript) == .clipboard {
                self.indicator.showMessage("Copied — paste anywhere")
            }
        }
    }

    // MARK: - Model

    private func handleTierChange(_ tier: CleanupTier) {
        qwenIdleTimer?.invalidate()
        switch tier {
        case .best:
            if appState.qwenResidency == .lazyUnload {
                appState.bestTierStatus = "Qwen loads on your next dictation."
                return
            }
            appState.bestTierStatus = "Preparing Qwen — downloading on first use (~2.3 GB)…"
            Task {
                do {
                    try await qwenCleaner.load()
                    await MainActor.run { self.appState.bestTierStatus = "Qwen ready." }
                } catch {
                    wlog("qwen: load failed: \(error)")
                    await MainActor.run {
                        self.appState.bestTierStatus = "Qwen failed to load — using Fast engine. See wisper.log."
                    }
                }
            }
        case .fast:
            appState.bestTierStatus = ""
            Task { await qwenCleaner.unload() }
        }
    }

    /// In lazy mode, unload Qwen after the configured quiet period.
    private func scheduleQwenIdleUnload() {
        qwenIdleTimer?.invalidate()
        guard appState.cleanupTier == .best, appState.qwenResidency == .lazyUnload else { return }
        let minutes = max(1, appState.qwenIdleMinutes)
        qwenIdleTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.qwenCleaner.unload()
                await MainActor.run {
                    if self.appState.cleanupTier == .best {
                        self.appState.bestTierStatus = "Qwen idle — loads on your next dictation."
                    }
                }
            }
        }
    }

    private func loadModel() async {
        do {
            try await transcriber.load()
            await MainActor.run {
                modelReady = true
                modelStatusItem.title = "Model: Parakeet TDT v3 (ready)"
                setIcon(state: .idle)
                appState.modelReady = true
                appState.modelStatus = "Parakeet v3 · ready"
            }
            wlog("model loaded and ready")
        } catch {
            await MainActor.run {
                modelStatusItem.title = "Model failed to load — see log"
                setIcon(state: .loading)
                appState.modelStatus = "Model failed to load"
            }
            wlog("model load failed: \(error)")
        }
    }

    // MARK: - Dictation flow

    private func startDictation(mode: RecordingMode = .dictation) {
        guard modelReady, !isProcessing, !recorder.isRecording else { return }
        self.recordingMode = mode
        // Lazy Qwen: start reloading now so it happens while the user speaks.
        if appState.cleanupTier == .best, appState.qwenResidency == .lazyUnload {
            qwenIdleTimer?.invalidate()
            Task { await qwenCleaner.ensureLoading() }
        }
        do {
            // Re-read: the Settings window may have changed it.
            recorder.preferBuiltInMic = preferBuiltInMic
            try recorder.start()
            recordingStartedAt = Date()
            setIcon(state: .recording)
            indicator.showRecording(mode: mode)
            playTick(named: "Tink")
            installEscapeMonitors()
            startPartialTranscripts()
            maxDurationTimer = Timer.scheduledTimer(withTimeInterval: maximumRecordingSeconds, repeats: false) { [weak self] _ in
                wlog("recording hit \(Int(self?.maximumRecordingSeconds ?? 0))s cap — finishing")
                self?.indicator.showMessage("5-minute limit reached — transcribing what you said", for: 2.2)
                self?.finishDictation()
            }
        } catch {
            wlog("could not start recording: \(error)")
        }
    }

    /// Live partial transcripts in the pill: re-transcribe the buffer every
    /// second while recording — Parakeet is fast enough to just redo it.
    private func startPartialTranscripts() {
        partialTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, self.recorder.isRecording, !self.partialInFlight else { return }
            let samples = self.recorder.snapshotSamples()
            guard samples.count > 12000 else { return }
            self.partialInFlight = true
            Task {
                if let text = try? await self.transcriber.transcribe(samples) {
                    await MainActor.run { self.indicator.setPartial(text) }
                }
                self.partialInFlight = false
            }
        }
    }

    private func cancelDictation() {
        guard recorder.isRecording else { return }
        _ = recorder.stop()
        tearDownRecordingState()
        setIcon(state: .idle)
        indicator.showMessage("Canceled", for: 0.9)
        wlog("dictation canceled via Esc")
    }

    private func finishDictation() {
        guard recorder.isRecording else { return }
        let samples = recorder.stop()
        tearDownRecordingState()
        let held = Date().timeIntervalSince(recordingStartedAt ?? Date())
        recordingStartedAt = nil

        guard held >= minimumHoldSeconds, !samples.isEmpty else {
            setIcon(state: .idle)
            indicator.hide()
            return
        }

        playTick(named: "Pop")
        isProcessing = true
        setIcon(state: .processing)
        indicator.showProcessing()
        let duration = Double(samples.count) / 16000.0
        let wantCleanup = cleanupEnabled
        let mode = recordingMode
        recordingMode = .dictation
        let options = OutputOptions.current()

        Task {
            let asrStart = Date()
            do {
                let text = try await transcriber.transcribe(samples)
                let asrMs = Int(Date().timeIntervalSince(asrStart) * 1000)
                var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)

                // Personal dictionary: pick up user edits, then apply the
                // deterministic replacement rules to every transcript.
                self.dictionary.reload()
                raw = self.dictionary.applyReplacements(to: raw)

                // Skill mode (Fn+Control): the utterance names a skill whose
                // full text gets pasted.
                if mode == .skill {
                    let utterance = raw
                    self.skillStore.reload()
                    let skill = self.skillStore.match(utterance)
                    await MainActor.run {
                        self.isProcessing = false
                        self.setIcon(state: .idle)
                        guard let skill else {
                            self.indicator.showMessage("No skill named “\(utterance)”")
                            return
                        }
                        self.lastTranscript = skill.content
                        self.copyLastItem.isEnabled = true
                        self.pasteLastItem.isEnabled = true
                        let delivery = self.injector.deliver(skill.content, options: options)
                        self.indicator.showMessage(
                            delivery == .clipboard ? "Skill “\(skill.name)” copied — paste anywhere" : "Skill “\(skill.name)”"
                        )
                        if UserDefaults.standard.object(forKey: "historyEnabled") as? Bool ?? true {
                            self.store?.save(
                                raw: utterance, clean: nil, durationSeconds: duration,
                                appBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                                delivery: "skill", asrMs: asrMs
                            )
                        }
                    }
                    return
                }

                if mode == .command {
                    await MainActor.run { self.handleCommand(utterance: raw, options: options) }
                    return
                }

                if options.spokenFormatting {
                    raw = OutputOptions.applySpokenFormatting(to: raw)
                }

                var cleaned: String? = nil
                var cleanupMs: Int? = nil
                if wantCleanup,
                   raw.split(whereSeparator: \.isWhitespace).count >= self.minimumWordsForCleanup {
                    let cleanupStart = Date()
                    var result: String? = nil

                    // Best tier first; falls through to Fast if not ready.
                    if self.appState.cleanupTier == .best {
                        result = await self.qwenCleaner.clean(raw, vocabulary: self.dictionary.vocabulary, options: options)
                    }
                    if result == nil,
                       #available(macOS 26.0, *),
                       let cleaner = self.cleanerBox as? Cleaner, cleaner.isAvailable {
                        result = await cleaner.clean(raw, vocabulary: self.dictionary.vocabulary, options: options)
                    }

                    if let result {
                        cleanupMs = Int(Date().timeIntervalSince(cleanupStart) * 1000)
                        if result != raw { cleaned = result }
                    }
                }

                let finalCleaned = cleaned
                let finalCleanupMs = cleanupMs
                await MainActor.run {
                    self.handleTranscript(raw: raw, cleaned: finalCleaned, duration: duration, asrMs: asrMs, cleanupMs: finalCleanupMs, options: options)
                }
            } catch {
                wlog("transcription failed: \(error)")
                await MainActor.run {
                    self.isProcessing = false
                    self.setIcon(state: .idle)
                    self.indicator.showMessage("Transcription failed")
                }
            }
        }
    }

    // MARK: - Command mode (Fn+Shift)

    /// Applies the active cleanup engine as a text transformer.
    private func transform(text: String, instruction: String) async -> String? {
        if appState.cleanupTier == .best,
           let result = await qwenCleaner.transform(text: text, instruction: instruction) {
            return result
        }
        if #available(macOS 26.0, *), let cleaner = cleanerBox as? Cleaner, cleaner.isAvailable {
            return await cleaner.transform(text: text, instruction: instruction)
        }
        return nil
    }

    private func handleCommand(utterance: String, options: OutputOptions) {
        let normalized = CommandStore.normalize(utterance)
        guard !normalized.isEmpty else {
            isProcessing = false
            setIcon(state: .idle)
            indicator.showMessage("Heard nothing")
            return
        }

        // "Scratch that": delete the text we just pasted.
        let scratchPhrases = ["scratch that", "delete that", "undo that", "scratch it"]
        if scratchPhrases.contains(where: { normalized.contains($0) }) {
            isProcessing = false
            setIcon(state: .idle)
            indicator.showMessage(injector.deleteLastPaste() ? "Deleted" : "Nothing to delete")
            return
        }

        // Target: current selection, else the last dictation.
        let selection = injector.selectedText()
        guard let target = selection ?? lastTranscript else {
            isProcessing = false
            setIcon(state: .idle)
            indicator.showMessage("Select text first, or dictate something")
            return
        }

        let instruction = commandStore.match(utterance)?.prompt ?? utterance
        wlog("command: \"\(utterance)\" → instruction \"\(instruction)\" on \(selection != nil ? "selection" : "last transcript") (\(target.count) chars)")

        Task {
            let result = await transform(text: target, instruction: instruction)
            await MainActor.run {
                self.isProcessing = false
                self.setIcon(state: .idle)
                guard let result else {
                    self.indicator.showMessage("Command needs a cleanup engine")
                    return
                }
                self.lastTranscript = result
                // Pasting over a selection replaces it; with no selection the
                // result lands at the cursor or on the clipboard.
                if self.injector.deliver(result, options: options) == .clipboard {
                    self.indicator.showMessage("Copied — paste anywhere")
                } else {
                    self.indicator.hide()
                }
            }
        }
    }

    private func handleTranscript(raw: String, cleaned: String?, duration: Double, asrMs: Int, cleanupMs: Int?, options: OutputOptions) {
        isProcessing = false
        setIcon(state: .idle)

        guard !raw.isEmpty else {
            indicator.showMessage("Heard nothing")
            return
        }

        let finalText = cleaned ?? raw
        lastTranscript = finalText
        copyLastItem.isEnabled = true
        pasteLastItem.isEnabled = true

        let targetApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let delivery = injector.deliver(finalText, options: options)
        if delivery == .clipboard {
            indicator.showMessage("Copied — paste anywhere")
        } else {
            indicator.hide()
        }

        if UserDefaults.standard.object(forKey: "historyEnabled") as? Bool ?? true {
            store?.save(
                raw: raw,
                clean: cleaned,
                durationSeconds: duration,
                appBundleID: targetApp,
                delivery: delivery.rawValue,
                asrMs: asrMs,
                cleanupMs: cleanupMs
            )
        }

        // Lazy Qwen: the idle countdown starts after each dictation.
        scheduleQwenIdleUnload()
    }

    // MARK: - Recording helpers

    private func tearDownRecordingState() {
        maxDurationTimer?.invalidate()
        maxDurationTimer = nil
        partialTimer?.invalidate()
        partialTimer = nil
        removeEscapeMonitors()
    }

    /// Esc while holding Fn discards the take.
    private func installEscapeMonitors() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            if event.keyCode == 53 { self?.cancelDictation() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler) {
            escapeMonitors.append(global)
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { handler(event); return nil }
            return event
        }
        if let local { escapeMonitors.append(local) }
    }

    private func removeEscapeMonitors() {
        escapeMonitors.forEach { NSEvent.removeMonitor($0) }
        escapeMonitors.removeAll()
    }

    private func playTick(named name: String) {
        guard let sound = NSSound(named: name) else { return }
        sound.volume = 0.18
        sound.play()
    }
}

extension AppDelegate: NSMenuDelegate {
    // Keep menu checkmarks in sync with changes made in the Settings tab.
    func menuWillOpen(_ menu: NSMenu) {
        cleanupItem.state = cleanupEnabled ? .on : .off
        builtInMicItem.state = preferBuiltInMic ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}
