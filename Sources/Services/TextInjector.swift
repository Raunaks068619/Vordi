import Foundation
import AppKit
import Carbon
import ApplicationServices

class TextInjector {
    private var lastInjectedSignature: String?
    private var lastInjectedAt: TimeInterval = 0
    private static let directPasteClipboardRestoreDelay: TimeInterval = 0.45

    /// Delivered when injection is suppressed for ANY reason — VoiceFlow
    /// is foreground, no text input focused, etc. The transcript is on
    /// the clipboard so the user can paste manually. AppDelegate uses
    /// this hook to flash the floating chip's warning state.
    var onInjectionSuppressed: ((String) -> Void)?

    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]

        static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot? {
            guard let pasteboardItems = pasteboard.pasteboardItems, !pasteboardItems.isEmpty else {
                return nil
            }

            let capturedItems = pasteboardItems.compactMap { item -> [NSPasteboard.PasteboardType: Data]? in
                var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) {
                        dataByType[type] = data
                    }
                }
                return dataByType.isEmpty ? nil : dataByType
            }

            guard !capturedItems.isEmpty else { return nil }
            return PasteboardSnapshot(items: capturedItems)
        }

        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()

            let restoredItems = items.map { dataByType -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in dataByType {
                    item.setData(data, forType: type)
                }
                return item
            }

            if !restoredItems.isEmpty {
                pasteboard.writeObjects(restoredItems)
            }
        }
    }

    func injectText(_ text: String, targetBundleIdentifier: String? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return }

            let now = Date().timeIntervalSinceReferenceDate
            let signature = "\(normalized.count):\(normalized.hashValue)"
            if signature == self.lastInjectedSignature && now - self.lastInjectedAt < 1.0 {
                print("Skipping duplicate text injection")
                return
            }

            self.lastInjectedSignature = signature
            self.lastInjectedAt = now

            self.injectNormalizedText(normalized, targetBundleIdentifier: targetBundleIdentifier)
        }
    }

    private func injectNormalizedText(_ normalized: String, targetBundleIdentifier: String?) {
        reactivateTargetIfVoiceFlowOwnsFocus(targetBundleIdentifier) { [weak self] in
            guard let self else { return }

            // Guard 1: VoiceFlow itself is foreground (Settings window
            // focused, etc.). Don't paste into our own UI — could clobber
            // a SecureField like an API key.
            if Self.isVoiceFlowForeground() {
                self.suppressInjection(normalized, reason: "VoiceFlow is frontmost")
                return
            }

            // Guard 2: focused element doesn't look like a text input.
            // This is INTENTIONALLY conservative — we still try to inject
            // into a wide range of AX roles (AXTextArea/Field/Search/
            // ComboBox/WebArea/ScrollArea/Group). If after that the role
            // is still off-list, fall back to clipboard.
            //
            // Tradeoff vs. the strict upfront gate: we may paste into an
            // app that doesn't actually consume the keystroke, in which
            // case the user has to Cmd+V again. That's acceptable — every
            // alternative either (a) blocks legitimate dictation in
            // AX-quirky apps like VS Code or iTerm, or (b) drops the
            // transcript on the floor.
            if !Self.focusedElementLooksLikeTextInput() {
                self.suppressInjection(normalized, reason: "no text-input element focused")
                return
            }

            self.injectViaPasteboard(normalized)
        }
    }

    private func reactivateTargetIfVoiceFlowOwnsFocus(
        _ targetBundleIdentifier: String?,
        completion: @escaping () -> Void
    ) {
        guard Self.isVoiceFlowForeground(),
              let targetBundleIdentifier,
              targetBundleIdentifier != Bundle.main.bundleIdentifier,
              let targetApp = NSRunningApplication.runningApplications(
                withBundleIdentifier: targetBundleIdentifier
              ).first
        else {
            completion()
            return
        }

        targetApp.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        print("Reactivated target app before paste: \(targetBundleIdentifier)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: completion)
    }

    // MARK: - Suppressed-injection clipboard preservation
    //
    // When we can't paste the transcript directly (no text input focused,
    // VoiceFlow foreground, etc.) we have to put the transcript on the
    // clipboard so the user can Cmd+V it later. That clobbers whatever
    // the user had — a copied password, an unrelated snippet — and feels
    // disrespectful.
    //
    // Solution: save the previous clipboard contents alongside our own
    // changeCount marker. The caller (AppDelegate) calls
    // `restorePreservedClipboard()` after the warning chip dismisses.
    // If the clipboard has been touched in the meantime (user copied
    // something new), we abort the restore so we don't clobber THAT.

    private var preservedPreviousClipboard: PasteboardSnapshot?
    /// `pasteboard.changeCount` recorded right after WE wrote the
    /// transcript. If it differs at restore-time, the clipboard has
    /// been mutated by some other source and we don't touch it.
    private var transcriptChangeCount: Int = -1

    /// Common path for suppressed injections: stash transcript on clipboard,
    /// preserve user's previous clipboard for later restore, log the reason,
    /// fire the callback so the chip can warn the user.
    private func suppressInjection(_ text: String, reason: String) {
        let pasteboard = NSPasteboard.general

        // Save previous clipboard BEFORE we overwrite. Preserve every
        // pasteboard type, not just plain text, so image/rich-text clips
        // survive the fallback path.
        preservedPreviousClipboard = PasteboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Snapshot the changeCount we just produced. Any future write
        // (Cmd+C of new content) will increment this, signaling we
        // should NOT restore.
        transcriptChangeCount = pasteboard.changeCount

        print("Injection suppressed (\(reason)) — transcript on clipboard, previous preserved")
        onInjectionSuppressed?(text)
    }

    /// Restore the user's previous clipboard contents — called by
    /// AppDelegate when the warning chip dismisses (auto-timer or user X).
    ///
    /// Safety: skips restore if changeCount has moved since we wrote the
    /// transcript, which means the user (or another app) put something
    /// else on the clipboard. Cmd+V doesn't increment changeCount, so a
    /// successful paste of our transcript still allows the restore.
    func restorePreservedClipboard() {
        guard let previous = preservedPreviousClipboard else { return }
        let pasteboard = NSPasteboard.general
        defer { preservedPreviousClipboard = nil }

        if pasteboard.changeCount != transcriptChangeCount {
            print("Clipboard changed since transcript was set — skipping restore")
            return
        }

        previous.restore(to: pasteboard)
        print("Restored previous clipboard")
    }

    /// AX role check on the currently-focused element.
    ///
    /// History: this was an *allowlist* (AXTextField, AXTextArea, AXScrollArea,
    /// AXGroup, AXOutline, ...). The allowlist approach has a fatal flaw —
    /// Electron apps (Claude desktop, VS Code, Cursor, Notion, Linear) and
    /// many web wrappers return roles that aren't in the list even when the
    /// user is staring at a blinking cursor in a real text input. Result:
    /// users see a false "Click a textbox" warning while their cursor is
    /// actively in a textbox. That breaks trust — the app is lying about
    /// what it can see.
    ///
    /// New approach: *denylist*. Only suppress when the role is something
    /// pasting clearly can't help with (button clicks, static labels, images,
    /// menus). For everything else — including AX-permission failures — we
    /// optimistically try the paste. If the keystroke lands nowhere, the
    /// user notices and Cmd+V's manually. That's a strictly better failure
    /// mode than a wrongful "you don't have a textbox focused" lecture when
    /// they obviously do.
    ///
    /// Roles confirmed-bad-paste-target — keep this list short. Adding a
    /// role here means we WILL show the warning, so be sure it never hosts
    /// a real text input on any platform/version.
    private static let nonTextInputRoles: Set<String> = [
        "AXButton",          // clicking a button
        "AXImage",           // image element
        "AXStaticText",      // label text, not editable
        "AXMenuItem",        // menu open
        "AXMenu",
        "AXMenuBar",
        "AXMenuBarItem",
        "AXMenuButton",
        "AXLink",            // hyperlink
        "AXCheckBox",
        "AXRadioButton",
        "AXSlider",
        "AXIncrementor",
        "AXScrollBar",
        "AXDisclosureTriangle"
    ]

    private static func focusedElementLooksLikeTextInput() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        // AX query failed — could be missing accessibility permission or a
        // sandboxed app refusing introspection. Optimistically allow paste:
        // if AX is broken, the cmd+v keystroke we're about to send is the
        // user's best chance of getting their transcript anyway.
        guard result == .success, let element = focused else {
            print("AX focus query failed — allowing paste (denylist semantics)")
            return true
        }

        var role: AnyObject?
        AXUIElementCopyAttributeValue(element as! AXUIElement, kAXRoleAttribute as CFString, &role)
        guard let roleString = role as? String else {
            // Got a focused element but couldn't read its role. Same logic:
            // unknown ≠ confirmed-bad. Allow.
            return true
        }

        if Self.nonTextInputRoles.contains(roleString) {
            print("Suppressing paste — focused role is \(roleString) (non-text)")
            return false
        }

        // Anything else — AXTextField, AXTextArea, AXWebArea, AXScrollArea,
        // AXGroup, AXOutline, AXUnknown, custom Electron roles, you name it
        // — gets the paste attempt. We'd rather try and fail silently than
        // refuse to try at all.
        return true
    }

    /// True when VoiceFlow is the frontmost application. We compare by bundle
    /// identifier rather than PID because helper processes (e.g. SwiftUI
    /// previews or XPC) share the same bundle id and should be treated as
    /// "us" for this check.
    private static func isVoiceFlowForeground() -> Bool {
        guard let frontBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return frontBundleID == Bundle.main.bundleIdentifier
    }

    private func injectViaPasteboard(_ text: String) {
        let didPostPasteShortcut = Self.pasteTextIntoFrontmostApp(
            text,
            restoreDelay: Self.directPasteClipboardRestoreDelay
        )
        if !didPostPasteShortcut {
            suppressInjection(text, reason: "paste shortcut could not be posted")
        }
    }

    /// Paste text into whichever app is currently frontmost, bypassing
    /// VoiceFlow/focused-role guards. Used by explicit action commands after
    /// they have already launched and activated their target app.
    @discardableResult
    static func pasteTextIntoFrontmostApp(
        _ text: String,
        restoreDelay: TimeInterval = directPasteClipboardRestoreDelay
    ) -> Bool {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                Self.pasteTextIntoFrontmostApp(text, restoreDelay: restoreDelay)
            }
            return true
        }

        let source = CGEventSource(stateID: .hidSystemState)
        guard let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        else {
            print("Paste injection failed — could not create Cmd+V events")
            return false
        }

        let pasteboard = NSPasteboard.general
        let previousClipboard = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            previousClipboard?.restore(to: pasteboard)
            print("Paste injection failed — could not write transcript to clipboard")
            return false
        }
        let transcriptChangeCount = pasteboard.changeCount

        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        vDown.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035) {
            vUp.post(tap: .cghidEventTap)
        }

        // Keep the transcript on the clipboard only long enough for the
        // posted Cmd+V to read it. The no-input fallback path intentionally
        // leaves the transcript available for manual paste; successful paste
        // attempts should not steal the user's previous clipboard.
        if restoreDelay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
                guard pasteboard.changeCount == transcriptChangeCount else {
                    print("Clipboard changed after paste attempt — skipping restore")
                    return
                }

                if let previousClipboard {
                    previousClipboard.restore(to: pasteboard)
                    print("Restored previous clipboard after paste attempt")
                } else {
                    pasteboard.clearContents()
                    print("Cleared transcript clipboard after paste attempt")
                }
            }
        }

        return true
    }
}
