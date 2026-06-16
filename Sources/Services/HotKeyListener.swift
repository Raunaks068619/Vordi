import Foundation
import AppKit
import Carbon
import ApplicationServices

enum HotKeyStartResult: Equatable {
    case started
    case failedMissingAccessibility
    case failedMissingInputMonitoring
    case failedUnknown
}

class HotKeyListener {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    var onHandsFreeToggle: (() -> Void)?
    /// Fired on Escape (keyCode 53) keydown. AppDelegate uses this to
    /// exit hands-free mode without requiring a second Fn double-tap.
    /// No-op when not in hands-free mode.
    var onEscape: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isTriggerActive = false
    private var isHandsFreeChordActive = false
    private let fnKeyCode: Int64 = 63
    private let escapeKeyCode: Int64 = 53

    deinit {
        stop()
    }

    func start() -> HotKeyStartResult {
        stop()
        if !AXIsProcessTrusted() {
            return .failedMissingAccessibility
        }
        if !CGPreflightListenEventAccess() {
            return .failedMissingInputMonitoring
        }

        // Listen for flagsChanged (Fn) AND keyDown (Escape). Combining
        // both into one tap is cheaper than running two taps.
        let eventMask = (1 << CGEventType.flagsChanged.rawValue)
                      | (1 << CGEventType.keyDown.rawValue)
        
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return nil }
                let listener = Unmanaged<HotKeyListener>.fromOpaque(refcon).takeUnretainedValue()
                return listener.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return .failedUnknown
        }
        
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        
        print("HotKeyListener started with passive CGEvent tap")
        return .started
    }
    
    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isTriggerActive = false
        isHandsFreeChordActive = false
    }
    
    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return nil
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // Escape: used to exit hands-free mode. AppDelegate decides
        // whether the press is meaningful (no-op if not in hands-free).
        if type == .keyDown && keyCode == escapeKeyCode {
            DispatchQueue.main.async { [weak self] in
                self?.onEscape?()
            }
            return nil
        }

        guard type == .flagsChanged else {
            return nil
        }

        let hasFnFlag = event.flags.contains(.maskSecondaryFn)
        let hasControlFlag = event.flags.contains(.maskControl)
        handleFlagsChanged(keyCode: keyCode, hasFnFlag: hasFnFlag, hasControlFlag: hasControlFlag)

        return nil
    }

    private func handleFlagsChanged(keyCode: Int64, hasFnFlag: Bool, hasControlFlag: Bool) {
        // Fn is the ONLY trigger. Right Option previously acted as a fallback
        // but caused accidental activation when users genuinely wanted Option
        // as a modifier. If Fn doesn't register on a given keyboard, the fix
        // is System Settings → Keyboard → Globe/Fn Key Usage, not a fallback.
        let hasHandsFreeChord = hasFnFlag && hasControlFlag
        if hasHandsFreeChord {
            if !isHandsFreeChordActive {
                isHandsFreeChordActive = true
                if isTriggerActive {
                    isTriggerActive = false
                }
                DispatchQueue.main.async { [weak self] in
                    print("Fn+Control detected - toggling hands-free")
                    self?.onHandsFreeToggle?()
                }
            }
            return
        }

        if isHandsFreeChordActive && !hasHandsFreeChord {
            isHandsFreeChordActive = false
            return
        }

        if keyCode == fnKeyCode {
            // Always trust the fn flag. Press = flag ON, Release = flag OFF.
            // Previous implementation toggled on "raw fn without flag" which caused
            // stuck-recording bugs when the release event arrived without the flag.
            setTriggerActive(hasFnFlag, pressedLog: "Fn pressed!", releasedLog: "Fn released!")
            return
        }

        // Any other flag change: if the fn modifier dropped, force-release.
        if !hasFnFlag && isTriggerActive {
            setTriggerActive(false, pressedLog: "Fn pressed!", releasedLog: "Fn released (flags cleared)!")
        }
    }

    private func setTriggerActive(_ active: Bool, pressedLog: String, releasedLog: String) {
        guard active != isTriggerActive else { return }
        isTriggerActive = active
        DispatchQueue.main.async { [weak self] in
            if active {
                print(pressedLog)
                self?.onKeyDown?()
            } else {
                print(releasedLog)
                self?.onKeyUp?()
            }
        }
    }
}
