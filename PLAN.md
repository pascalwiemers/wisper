# Wisper — Local Wispr Flow Clone for macOS

A menu bar app for macOS: **hold the Fn key → speak → release → clean text appears in whatever text field you're in.** Everything runs on-device (M5 Pro, 64 GB RAM — massive headroom for this).

## Target UX

1. Hold **Fn** anywhere in macOS. A small floating pill appears at the bottom-center of the screen with a live waveform, exactly like Wispr Flow's indicator.
2. Speak. Release **Fn**.
3. Audio is transcribed locally, then cleaned by a small local LLM (fillers like "um"/"uh" removed, punctuation/capitalization fixed, intent preserved).
4. If a text field has focus → the text is pasted into it. If not → it lands on the clipboard and a subtle notification says "Copied — paste anywhere."
5. Target end-to-end latency after key release: **under ~1 second** for a typical utterance (transcription is nearly instant; the cleanup LLM is the main cost).

## Model choices (the "latest and greatest," as of August 2026)

### Speech-to-text: NVIDIA Parakeet TDT 0.6B v3

This is the current best pick for English dictation on Apple Silicon, and it's what the leading Wispr alternatives (Whisper Notes, Muesli, VoiceInk) have converged on:

- **Faster than Whisper by a wide margin**: ~3,000× real-time factor on Apple Silicon vs ~130× for Whisper large-v3-turbo. A 15-second utterance transcribes in well under 100 ms — release the key and the text is effectively already there.
- **More accurate than Whisper large-v3-turbo on English** (slightly better WER on English benchmarks, ~12.0% vs 12.6% averaged across languages), and it doesn't have Whisper's notorious hallucination-during-silence problem, which matters a lot for push-to-talk dictation.
- Trade-off: covers 25 European languages vs Whisper's ~100. Fine for our use case; we can add a Whisper large-v3-turbo fallback option later for other languages.

**How we run it:** [FluidAudio](https://github.com/FluidInference/FluidAudio) — a Swift package that runs Parakeet TDT v3 via Core ML on the Neural Engine. Pure Swift, no Python sidecar, low memory, ships as an SPM dependency. (Fallback option if FluidAudio disappoints: `parakeet-mlx` behind a tiny local Python daemon.)

### Text cleanup: two-tier approach

- **Tier 1 (default): Apple Foundation Models framework** (built into macOS 26). The on-device ~3B Apple Intelligence model, invoked via the native `FoundationModels` Swift API. Zero download, zero memory cost when idle, very fast, and more than capable of "remove fillers, fix punctuation, keep intent." This is the pragmatic Wispr-style cleanup pass.
- **Tier 2 (optional, higher quality): Qwen3.5-4B-Instruct via MLX** (4-bit quant, ~3.4 GB). The current consensus best small local LLM. Selectable in settings for people who want stronger rewriting (e.g., "format as email" style modes later). Loaded lazily and kept warm in memory — trivial with 64 GB RAM.

Cleanup prompt contract: *strictly* remove disfluencies ("um", "uh", "like", false starts, immediate self-corrections — keep the corrected version), add punctuation/capitalization/paragraphing, never add or reword content. Skip the LLM entirely for utterances under ~4 words (nothing to clean; saves latency).

## Architecture

Native Swift/SwiftUI menu bar app (`LSUIElement`, no Dock icon). No Electron — key-event capture, Accessibility, and floating windows are all much better native.

```
┌────────────────────────────────────────────────────┐
│ Wisper.app (menu bar)                              │
│                                                    │
│  HotkeyMonitor ── CGEventTap on flagsChanged       │
│      │  (Fn down/up via .maskSecondaryFn)          │
│      ▼                                             │
│  AudioRecorder ── AVAudioEngine, 16 kHz mono float │
│      │            + level meter → indicator UI     │
│      ▼                                             │
│  Transcriber ── FluidAudio / Parakeet TDT v3       │
│      ▼                                             │
│  Cleaner ── FoundationModels (or MLX Qwen3.5-4B)   │
│      ▼                                             │
│  Injector ── AX focus check → paste or clipboard   │
│                                                    │
│  IndicatorPanel ── floating NSPanel, waveform pill │
└────────────────────────────────────────────────────┘
```

### Component details

**HotkeyMonitor.** A `CGEventTap` listening for `flagsChanged` events; Fn is the `.maskSecondaryFn` modifier flag. Key-down starts recording, key-up stops it. Debounce very short taps (< 250 ms) so accidental Fn presses (and the emoji-picker tap) don't trigger anything. Requires the **Input Monitoring / Accessibility** permission. Note: the user may want to set macOS System Settings → Keyboard → "Press 🌐 key" to *Do Nothing* so the emoji picker doesn't fight us; the app should detect and suggest this.

**AudioRecorder.** `AVAudioEngine` input tap, converted to 16 kHz mono Float32 (what Parakeet expects). Keep the engine pre-warmed so recording starts the instant Fn goes down — no missed first syllable. Feed RMS levels to the indicator at ~30 fps. Requires the **Microphone** permission.

**Transcriber.** FluidAudio's `AsrManager` with Parakeet TDT v3, models auto-downloaded on first launch (~600 MB) to `~/Library/Application Support/Wisper/`. Warm the model at app start. Transcribe the full buffer on key release — at Parakeet's speed there's no need for streaming complexity in v1.

**Cleaner.** A `LanguageModelSession` (FoundationModels) with a fixed system prompt implementing the contract above, temperature 0. Falls back to raw transcript if the model is unavailable (Apple Intelligence disabled) or errors. Settings toggle: Off / Fast (Apple) / Best (Qwen via MLX-Swift).

**Injector.** The Wispr trick, done properly:
1. Use the Accessibility API (`AXUIElementCopyAttributeValue` on the system-wide focused element) to check whether focus is a text-input role (`AXTextField`, `AXTextArea`, `AXComboBox`, web text areas).
2. **If focused text input:** save the current pasteboard contents, write our text, synthesize ⌘V via `CGEvent`, then restore the previous pasteboard after ~300 ms. Paste is used (not per-character typing) because it's instant and survives every app.
3. **If no text input focused (or AX is inconclusive):** leave the text on the clipboard *without* restoring the old contents, and show a "Copied to clipboard" notification — that's the requested fallback so nothing is ever lost.
4. Every transcript is also appended to the local transcript store (see below) as a belt-and-suspenders recovery.

**TranscriptStore.** A local SQLite database (via GRDB) at `~/Library/Application Support/Wisper/transcripts.db`, one row per dictation: timestamp, raw transcript, cleaned transcript, audio duration, word count, target app bundle ID, delivery method (pasted vs clipboard), transcription + cleanup latency. Never leaves the machine. This powers the history view, recovery, and the analytics below. Settings include a logging on/off toggle, retention window, and "delete all history."

**IndicatorPanel.** A non-activating, click-through `NSPanel` (`.nonactivatingPanel`, floating window level, `ignoresMouseEvents`, visible on all Spaces/fullscreen via `.canJoinAllSpaces` + `.fullScreenAuxiliary`), positioned bottom-center of the active screen. SwiftUI content: a small dark rounded pill with animated waveform bars driven by mic RMS, then a brief "processing" shimmer state after release, then fades out. Mirrors Wispr's indicator.

**Menu bar item.** Mic icon (fills/tints while recording). Menu: recent transcript history, cleanup mode toggle, launch-at-login, permissions status, quit.

## Build plan

**Phase 1 — Core loop (the whole point).**
Xcode project (SwiftUI, macOS 26 target, menu-bar-only) → permissions onboarding (mic, accessibility) → Fn capture → record → Parakeet transcription → paste-or-clipboard injector. *Milestone: hold Fn in any app, get raw transcribed text pasted.*

**Phase 2 — Cleanup pass.**
FoundationModels cleanup with the strict prompt contract; skip-short-utterance logic; raw-vs-clean A/B in the history view to tune the prompt. *Milestone: "um so uh basically I think we should ship it" → "I think we should ship it."*

**Phase 3 — The Wispr polish.**
Floating waveform pill, processing state, sounds (subtle start/stop tick), menu bar states, transcript history, launch-at-login, settings window (hotkey choice, cleanup tier, language). Plus the small interactions that make it feel finished:

- *Cancel gesture:* press Esc while holding Fn to discard the recording (the pill flashes and fades, nothing is pasted). Also a max-duration cap (~5 min) with a warning state so a stuck Fn key can't record forever.
- *Smart spacing:* before pasting, read the focused element's text and cursor position via AX and add/omit a leading space so dictating mid-sentence doesn't produce "wordword" or double spaces. Capitalize automatically after sentence-ending punctuation.
- *Re-paste last:* a hotkey and menu item that pastes the most recent transcript again — for when a paste lands in the wrong window.
- *Mic device policy:* explicit input-device picker with a "prefer built-in microphone" default. This matters: recording from AirPods drops them into low-quality HFP mode and degrades both your music and the transcription; the built-in mic array is usually the better choice even when AirPods are connected.

**Phase 4 — Transcript logging & style analytics (the Wispr "stats" experience).**
Everything is already being written to the TranscriptStore in Phase 1; this phase turns it into insight. A "Stats" window opened from the menu bar with:

- *Usage stats:* words dictated (today / week / all-time), dictation count, average words per minute of speech, total time saved vs typing (Wispr's favorite vanity metric — speaking WPM vs an assumed ~45 WPM typing rate), streaks, most-dictated-into apps.
- *Style analysis:* computed by diffing raw vs cleaned transcripts — your most common filler words and how often you use them ("um" rate per 100 words, trending over time), average sentence length, vocabulary richness, most-used words and phrases (excluding stopwords), self-correction frequency ("I mean", "actually, no"), politeness/hedging markers ("maybe", "I think", "sort of").
- *Periodic deep-dive (optional):* a "Analyze my style" button that feeds a sample of recent transcripts to the local cleanup LLM for a qualitative writeup — tone, recurring habits, suggestions. Runs fully locally like everything else.
- *Export:* dump the store to JSONL/CSV so we can do ad-hoc analysis in a notebook whenever we feel like it.

The raw/clean pairs also double as tuning data for the cleanup prompt: any dictation where cleanup changed the meaning is one click away from being flagged in the history view.

**Phase 5 — Model upgrades (in progress).**
- ✅ *"Best" cleanup tier*: Qwen3-4B-Instruct (4-bit) via MLX (`mlx-swift-lm` + `mlx-community/Qwen3-4B-Instruct-2507-4bit`, ~2.3 GB download, ~4 GB RAM while enabled). Selectable in Settings; falls back to the Fast (Apple) tier if unavailable; unloads when switched off. Qwen3.5 arch isn't supported by mlx-swift-lm yet — upgrade the model id when it is.
- Remaining: Whisper large-v3-turbo fallback for non-European languages; ASR-level vocabulary boosting (see personalization loop); per-app vocabularies/context; streaming partial transcripts in the pill.

**Personalization loop (v1 built; grows over time).**
The app adapts to the speaker without retraining any model:

- *Personal dictionary* (`~/Library/Application Support/Wisper/dictionary.txt`, menu → "Edit Personal Dictionary…"): plain words are vocabulary the cleanup LLM prefers over similar-sounding mishearings; `wrong -> right` lines are deterministic replacements applied to every transcript — the fix for recurring ASR errors ("my arms -> my ums").
- *Auto-learning*: at launch, words that recur across dictations but aren't in the system dictionary (names, tools, jargon) are added to the vocabulary automatically.
- *Contextual mishearing repair*: the cleaner is instructed to fix words that make no sense in context when a near-homophone clearly fits, guided by the personal vocabulary.
- *Layered cleanup, no data loss*: dictionary replacements → LLM cleanup (retry on filler-stripped text if Apple's guardrails refuse) → deterministic regex filler-strip post-pass → capitalization/punctuation polish.

Next steps on this arc: ASR-level vocabulary boosting (FluidAudio's CTC keyword spotter + rescorer — needs the parakeet-ctc-110m model and the SlidingWindow manager); a style profile distilled from accumulated raw/clean pairs and injected into the cleanup prompt; and, as a research item, Apple's Foundation Models LoRA adapter toolkit for true on-device model adaptation.

**Phase 6 — Voice command mode (documented, not committed).**
Wispr's other half: talking *about* the text instead of producing it. Explicitly out of scope until the core loop is great, but captured here so it's not forgotten:

- *Edit commands:* "delete that", "scratch that, say instead…", "make it more formal / shorter", "turn this into bullet points" — applied to the last dictation or, via AX, to selected text in the focused app.
- *Intent routing:* the hard problem is deciding whether an utterance is dictation or a command. Likely approach: a separate hotkey (e.g. hold Fn+Shift) for command mode rather than trying to auto-detect intent — auto-detection is where these features get flaky and trust dies.
- *Rewrite tones/presets:* per-app default styles (Slack casual, email formal, code-comment terse), selectable from the pill while recording.
- *Selected-text transforms:* select text anywhere, hold the command hotkey, say "translate to German" / "fix grammar" — the LLM rewrites in place via the same paste mechanism.

## Quality & distribution

- **Golden-audio regression suite.** A small fixture set of recorded clips (clean speech, heavy fillers, mid-sentence corrections, jargon/names, background noise) with expected outputs, runnable as a test target. Every cleanup-prompt or model change gets checked against it — otherwise prompt tuning becomes whack-a-mole.
- **Audio hygiene before transcription:** trim leading/trailing silence and skip transcription entirely if the whole recording is below a speech-energy threshold (Fn pressed by accident) — this avoids both wasted latency and junk pastes.
- **Signing & updates:** hardened runtime, notarized builds, and Sparkle for auto-updates so the app is easy to keep on this machine (and shareable later if desired). Mic/accessibility permission prompts behave much better in a properly signed app.
- **Idle footprint:** Parakeet stays warm (~1 GB, worth it for instant response); the optional Qwen tier unloads after inactivity. Menu bar shows nothing hot when idle — this must feel like a system utility, not an app that's "running."

## Risks / gotchas

- **Fn key quirks:** Fn doesn't arrive as a normal keycode; it must be read from modifier flags, and macOS's own 🌐-key features (emoji picker, dictation) can collide. Handled in HotkeyMonitor; onboarding should walk the user through the one Settings change.
- **Secure input fields** (password boxes) block synthetic paste and AX — detect `AXSecureTextField`/secure-input mode and go straight to the clipboard path.
- **Electron/web apps** sometimes report AX focus poorly — when in doubt we paste anyway if *any* element reports a text role, else clipboard. Tuning list kept per-app.
- **Apple Intelligence availability:** FoundationModels requires Apple Intelligence enabled; the app must degrade gracefully to raw transcript (or Qwen tier) if it's off.
- **First-run download:** ~600 MB Parakeet model — needs a progress UI on first launch.

## Sources

- [Best Local STT Models in 2026: Moonshine vs Parakeet vs Whisper](https://www.onresonant.com/resources/local-stt-models-2026)
- [Parakeet TDT 0.6B v3 vs Whisper Large V3 Turbo](https://www.parakeety.com/resources/parakeet-v3-vs-whisper-large-v3-turbo)
- [Whisper large-v3 vs Parakeet on MLX, benchmarked on M5 Max (2026)](https://contracollective.com/blog/local-speech-to-text-whisper-parakeet-mlx-m5-max-2026)
- [Parakeet V3 vs Whisper: 10x faster, better accuracy](https://whispernotes.app/blog/parakeet-v3-default-mac-model)
- [FreeFlow — open-source Wispr Flow alternative](https://github.com/zachlatta/freeflow) and [FnKey (hold-Fn Rust menu bar app)](https://alternativeto.net/software/fnkey) — reference implementations for the Fn-hold flow
- [Best local LLMs 2026 (Qwen3.5-4B as top small model)](https://klymentiev.com/blog/best-local-llm)
- [mac-whisper-speedtest — Whisper implementations on Apple Silicon](https://github.com/anvanvan/mac-whisper-speedtest)
