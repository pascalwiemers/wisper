# Wisper

Local, private push-to-talk dictation for macOS. Hold **Fn**, speak, release — your words are transcribed on-device (Parakeet TDT v3 on the Neural Engine) and pasted into whatever text field you're in. No text field focused? The text lands on your clipboard instead.

See [PLAN.md](PLAN.md) for the full roadmap. Current state: **Phases 1–4 built** — core loop, on-device LLM cleanup (Apple Foundation Models), waveform pill + polish, and the Stats window.

## Build & run

```bash
./scripts/build-app.sh      # builds release binary + wraps it into build/Wisper.app
open build/Wisper.app
```

On first launch the app downloads the Parakeet model (~500 MB) to `~/Library/Application Support/FluidAudio/`. The menu bar icon shows a download arrow until the model is ready, then a mic.

## Required permissions (one-time)

1. **Microphone** — macOS prompts automatically on first launch. If you miss it: System Settings → Privacy & Security → Microphone → enable Wisper.
2. **Accessibility** — needed to see the Fn key globally and to paste. macOS prompts on first launch; grant under System Settings → Privacy & Security → Accessibility → enable Wisper. There's a shortcut to this pane in the menu bar menu.

> **Note:** the app is ad-hoc signed, so after a rebuild macOS may silently ignore the old Accessibility grant. If Fn stops triggering after rebuilding, remove Wisper from the Accessibility list and re-add it (drag `build/Wisper.app` in).

Recommended: System Settings → Keyboard → "Press 🌐 key to" → **Do Nothing**, so the emoji picker doesn't pop up alongside dictation.

## Usage

- **Hold Fn** → waveform pill appears, menu bar mic turns red. **Release** → cleaned and pasted. **Esc while holding** → cancel.
- Dictations of 4+ words are cleaned by the on-device Apple Intelligence model (fillers removed, punctuation fixed, meaning untouched). Toggle: menu → "Clean Up Text".
- Taps shorter than ~250 ms are ignored; recordings cap at 5 minutes.
- If no text field has focus, the text goes to the clipboard and the pill says so. Password fields always go to the clipboard.
- Smart spacing: dictating mid-sentence won't glue words together.
- Bluetooth mics are avoided by default ("Prefer Built-In Microphone" in the menu) — AirPods drop to low-quality HFP when used as a mic.
- Menu bar → Copy/Paste Last Transcript, Start at Login, and **Stats…** (words per day/week, speaking WPM, time saved vs typing, filler-word habits, top apps, JSONL/CSV export).
- Every dictation is logged locally only, to `~/Library/Application Support/Wisper/transcripts.db`; delivery decisions log to `wisper.log` next to it.

## Layout

```
Sources/Wisper/
  main.swift            app bootstrap (menu-bar-only, no Dock icon)
  AppDelegate.swift     wiring: status item, permissions, dictation flow
  HotkeyMonitor.swift   global Fn press/release detection (flagsChanged)
  AudioRecorder.swift   AVAudioEngine → 16 kHz mono Float32 samples
  Transcriber.swift     FluidAudio / Parakeet TDT v3 wrapper
  Cleaner.swift         on-device LLM cleanup (FoundationModels, @Generable output)
  Injector.swift        AX focus check → smart-spaced paste (clipboard-swap + ⌘V) or clipboard
  TranscriptStore.swift SQLite log of every dictation
  IndicatorPanel.swift  floating pill: live waveform / processing pulse / messages
  Stats.swift           stats computation + SwiftUI Stats window + export
  Log.swift             file logger (~/Library/Application Support/Wisper/wisper.log)
```

Dev tip: `.build/release/Wisper --clean "um so some raw text"` tests the cleanup prompt from the terminal without launching the app.
