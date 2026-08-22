import AppKit

/// Watches the Fn (globe) modifier globally. Fn arrives as a modifier flag on
/// `.flagsChanged` events, not as a normal keycode, so we track edge transitions.
/// Requires Accessibility trust to observe events in other apps.
final class HotkeyMonitor {
    /// `commandMode` is true when Shift is held with Fn (command mode).
    var onFnDown: ((_ commandMode: Bool) -> Void)?
    var onFnUp: (() -> Void)?
    /// Fires if Shift joins while Fn is already held — upgrades to command mode.
    var onCommandUpgrade: (() -> Void)?

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
        if fn && !fnIsDown {
            fnIsDown = true
            DispatchQueue.main.async { self.onFnDown?(shift) }
        } else if fn && fnIsDown && shift {
            DispatchQueue.main.async { self.onCommandUpgrade?() }
        } else if !fn && fnIsDown {
            fnIsDown = false
            DispatchQueue.main.async { self.onFnUp?() }
        }
    }
}
