import AppKit

/// Watches the Fn (globe) modifier globally. Fn arrives as a modifier flag on
/// `.flagsChanged` events, not as a normal keycode, so we track edge transitions.
/// Requires Accessibility trust to observe events in other apps.
/// What a hold of Fn means, decided by the co-held modifier.
enum RecordingMode {
    case dictation      // Fn alone
    case command        // Fn + Shift: transform selected text
    case skill          // Fn + Control: paste a named skill
    case reclean        // Fn + Option: re-clean the last paste via Codex (no recording)
}

final class HotkeyMonitor {
    var onFnDown: ((RecordingMode) -> Void)?
    var onFnUp: (() -> Void)?
    /// Fires if Shift/Control joins while Fn is already held — upgrades the mode.
    var onModeUpgrade: ((RecordingMode) -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var fnIsDown = false

    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func handle(_ event: NSEvent) {
        let fn = event.modifierFlags.contains(.function)
        let shift = event.modifierFlags.contains(.shift)
        let control = event.modifierFlags.contains(.control)
        let option = event.modifierFlags.contains(.option)
        let mode: RecordingMode = control ? .skill : (shift ? .command : (option ? .reclean : .dictation))
        if fn && !fnIsDown {
            fnIsDown = true
            DispatchQueue.main.async { self.onFnDown?(mode) }
        } else if fn && fnIsDown && mode != .dictation {
            DispatchQueue.main.async { self.onModeUpgrade?(mode) }
        } else if !fn && fnIsDown {
            fnIsDown = false
            DispatchQueue.main.async { self.onFnUp?() }
        }
    }
}
