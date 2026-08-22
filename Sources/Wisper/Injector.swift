import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum Delivery: String {
    case pasted
    case clipboard
}

/// Delivers finished text: pastes into the focused text field when there is
/// one, otherwise leaves the text on the clipboard.
final class Injector {
    /// Apps that accept ⌘V into their main view but are invisible or
    /// unreliable through the Accessibility API — mostly terminals.
    private let alwaysPasteBundleIDs: Set<String> = [
        "com.mitchellh.ghostty",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "dev.warp.Warp",
    ]

    func deliver(_ text: String) -> Delivery {
        let decision = pasteDecision()
        if decision.paste {
            paste(smartSpacingPrefix(for: decision.element) + text)
            return .pasted
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        return .clipboard
    }

    // MARK: - Focus detection

    private func pasteDecision() -> (paste: Bool, element: AXUIElement?) {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            let terminal = alwaysPasteBundleIDs.contains(frontmost)
            wlog("inject: no AX focused element (app=\(frontmost)) → \(terminal ? "paste (terminal allowlist)" : "clipboard")")
            return (terminal, nil)
        }
        let element = focusedRef as! AXUIElement

        let role = stringAttribute(element, kAXRoleAttribute)
        let subrole = stringAttribute(element, kAXSubroleAttribute)

        // Password fields: synthetic paste is blocked / undesirable there.
        if subrole == "AXSecureTextField" {
            wlog("inject: secure text field (app=\(frontmost)) → clipboard")
            return (false, nil)
        }

        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
        if let role, textRoles.contains(role) {
            wlog("inject: role=\(role) (app=\(frontmost)) → paste")
            return (true, element)
        }

        // Web content and custom editors (Electron, browsers) often expose a
        // generic role but support a selected text range plus a settable value.
        var rangeRef: CFTypeRef?
        let hasSelectedRange = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success
        var valueSettable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable)

        if hasSelectedRange && (valueSettable.boolValue || role == "AXWebArea") {
            wlog("inject: role=\(role ?? "?") hasRange settable=\(valueSettable.boolValue) (app=\(frontmost)) → paste")
            return (true, element)
        }

        // Terminals and other AX-opaque apps: their focused element exposes
        // no text traits, but ⌘V into them is exactly what the user wants.
        if alwaysPasteBundleIDs.contains(frontmost) {
            wlog("inject: role=\(role ?? "?") no text traits, terminal allowlist (app=\(frontmost)) → paste")
            return (true, nil)
        }

        wlog("inject: role=\(role ?? "?") subrole=\(subrole ?? "?") hasRange=\(hasSelectedRange) settable=\(valueSettable.boolValue) (app=\(frontmost)) → clipboard")
        return (false, nil)
    }

    /// When dictating mid-sentence, add a leading space so pasted text doesn't
    /// glue onto the previous word. Reads the field's text and cursor position.
    private func smartSpacingPrefix(for element: AXUIElement?) -> String {
        guard let element,
              let value = stringAttribute(element, kAXValueAttribute), !value.isEmpty else { return "" }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return "" }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range), range.location > 0 else { return "" }

        // AX text ranges are in UTF-16 units, so index via NSString.
        let ns = value as NSString
        let location = min(range.location, ns.length)
        guard location > 0 else { return "" }
        let previous = Character(UnicodeScalar(ns.character(at: location - 1)) ?? " ")
        let noSpaceAfter: Set<Character> = [" ", "\n", "\t", "(", "[", "{", "\"", "'", "/", "-"]
        return (previous.isWhitespace || noSpaceAfter.contains(previous)) ? "" : " "
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    // MARK: - Paste

    private func paste(_ text: String) {
        wlog("paste: AXIsProcessTrusted=\(AXIsProcessTrusted()) — posting ⌘V")
        let pb = NSPasteboard.general
        let savedItems = snapshotPasteboard(pb)

        pb.clearContents()
        pb.setString(text, forType: .string)

        synthesizeCommandV()

        // Restore the user's previous clipboard once the paste has landed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            pb.clearContents()
            if !savedItems.isEmpty {
                pb.writeObjects(savedItems)
            }
        }
    }

    private func snapshotPasteboard(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private func synthesizeCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(kVK_ANSI_V)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
