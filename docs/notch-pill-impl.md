# Notch Pill — Implementation Plan

Replace the `FloatingChipWindow` (bottom-of-screen draggable chip) with a single notch-docked morphing pill that lives permanently in the macOS menu bar area, centered over the camera notch.

---

## Visual Reference

Every dimension, color, animation, and state transition is prototyped and finalized in:

```
Sources/Resources/notch-preview/vordi-notch.html   ← main interactive demo
Sources/Resources/notch-preview/notch-anatomy.html     ← annotated dimension reference
```

Serve them locally with `npx serve .` in that directory (or open in browser directly).  
**Do not guess at details — if something is ambiguous, read the HTML source.**

---

## What Gets Removed

| Symbol | File | Lines |
|--------|------|-------|
| `FloatingChipModel` | `Sources/Views/MainDashboardView.swift` | ~2537–2560 |
| `ChipHitBoundsKey` | `Sources/Views/MainDashboardView.swift` | ~2563–2570 |
| `ChipHostingView` | `Sources/Views/MainDashboardView.swift` | ~2573–2627 |
| `FloatingChipWindow` | `Sources/Views/MainDashboardView.swift` | ~2629–2870 |
| `FloatingChipView` | `Sources/Views/MainDashboardView.swift` | ~2988–3360 |
| `RecordingOverlayWindow` | `Sources/Views/RecordingOverlayWindow.swift` | entire file |
| `RecordingOverlayModel` | `Sources/Views/RecordingOverlayWindow.swift` | entire file |
| `RecordingOverlayView` | `Sources/Views/RecordingOverlayWindow.swift` | entire file |

> `RecordingOverlayWindow` is already silenced in the current codebase (see comments in `AppDelegate.showRecordingOverlay`). Delete the file entirely.

---

## What Gets Added

| File | Contents |
|------|----------|
| `Sources/Views/NotchPillWindow.swift` | `NotchPillModel`, `NotchPillHostingView`, `NotchPillWindow` |
| `Sources/Views/NotchPillView.swift` | Main SwiftUI pill + panel body |
| `Sources/Views/NotchPillComponents.swift` | `VFLogoView`, `WaveformBarsView`, `ThinkingDotsView`, `GreenTickView`, all panel sub-views |

---

## What Gets Modified

| File | Change |
|------|--------|
| `Sources/App/VordiApp.swift` | Swap `floatingChip: FloatingChipWindow?` → `notchPill: NotchPillWindow?`; update every call site; wire Done/Error states |
| `Sources/Views/MainDashboardView.swift` | Delete the entire `// MARK: - FloatingChipWindow` section |

---

## 1. State Machine

### `NotchPillState` enum

```swift
enum NotchPillState: Equatable {
    // Inline pill states (32 pt tall, no panel)
    case idle
    case proximity                          // cursor near notch area
    case listening                          // Fn held, recording
    case thinking                           // STT/LLM in flight
    case done                               // success flash, auto-reverts 2 s
    case handsFree                          // double-tap continuous listen

    // Expansion states (pill + panel below)
    case errorMini(message: String)         // single amber line, ~67 pt tall
    case panelHover                         // click/hover → idle detail panel
    case panelTranscript(text: String)      // Fn held while panel is open
    case panelError(title: String, desc: String, tip: String) // tap errorMini

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.proximity, .proximity),
             (.listening, .listening), (.thinking, .thinking),
             (.done, .done), (.handsFree, .handsFree),
             (.panelHover, .panelHover):
            return true
        case (.errorMini(let a), .errorMini(let b)):       return a == b
        case (.panelTranscript(let a), .panelTranscript(let b)): return a == b
        case (.panelError(let a, let b, let c), .panelError(let d, let e, let f)):
            return a == d && b == e && c == f
        default: return false
        }
    }
}
```

### `NotchPillModel`

```swift
final class NotchPillModel: ObservableObject {
    @Published var state: NotchPillState = .idle

    /// Live microphone amplitude 0…1. Drives WaveformBarsView scale.
    @Published var audioLevel: Float = 0

    /// Passive orange-dot indicator when a required permission is missing.
    @Published var hasAllPermissions: Bool = true

    /// Published by the SwiftUI body via preference key; read by
    /// NotchPillHostingView.hitTest to scope click-through.
    @Published var pillHitBounds: CGRect = .zero

    /// Stored so tapping errorMini can expand to panelError without
    /// AppDelegate passing the error again.
    var lastError: (title: String, desc: String, tip: String)?
}
```

---

## 2. Dimensions

All values in logical points (1× scale). Widths are the pill shape; the window canvas is larger (see §3).

| State | Pill width | Total height | Bottom corner radius |
|-------|-----------|-------------|----------------------|
| `.idle` | 220 | 32 | 16 |
| `.proximity` | 268 | 32 | 16 |
| `.listening` | 360 | 32 | 16 |
| `.thinking` | 360 | 32 | 16 |
| `.done` | 320 | 32 | 16 |
| `.handsFree` | 360 | 32 | 16 |
| `.errorMini` | 364 | 67 | 22 |
| `.panelHover` | 364 | 225 | 22 |
| `.panelTranscript` | 364 | 134 | 22 |
| `.panelError` | 364 | 218 | 22 |

**Physical notch dead zone**: 162 × 32 pt, centered. All states wider than 162 pt have a safe visible zone of `(pillWidth − 162) / 2` on each side of the notch.

**Top corners**: always 0 — the pill is flush with the top of the screen (no radius needed, the notch hardware provides the visual boundary).

---

## 3. `NotchPillWindow` — Full Spec

```swift
// Sources/Views/NotchPillWindow.swift

import AppKit, SwiftUI

// MARK: - Hit-test scoped hosting view

/// Same pattern as the retired ChipHostingView.
/// Returns nil outside model.pillHitBounds so transparent padding is click-through.
final class NotchPillHostingView: NSHostingView<NotchPillView> {
    weak var model: NotchPillModel?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let model else { return super.hitTest(point) }
        let bounds = model.pillHitBounds
        if bounds == .zero { return super.hitTest(point) }
        let local = self.convert(point, from: self.superview)
        return bounds.contains(local) ? super.hitTest(point) : nil
    }

    // No drag — pill is fixed position, not movable.
}

// MARK: - Window

final class NotchPillWindow: NSPanel {
    let model = NotchPillModel()

    /// Canvas is larger than any single state so we never resize the window
    /// during state transitions (avoids jank). SwiftUI clips inside.
    /// Width: 500 pt — wider than the 364 pt max pill + shadow/glow room.
    /// Height: 400 pt — taller than the 225 pt max panel + padding.
    private static let canvasSize = NSSize(width: 500, height: 400)

    private var globalMouseMonitor: Any?
    private var flashTimer: Timer?

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.canvasSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level            = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
        backgroundColor  = .clear
        isOpaque         = false
        hasShadow        = false
        ignoresMouseEvents = false
        isFloatingPanel  = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        isMovable        = false

        let host = NotchPillHostingView(rootView: NotchPillView(model: model))
        host.model = model
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: Self.canvasSize)
        host.autoresizingMask = [.width, .height]
        contentView = host
        setContentSize(Self.canvasSize)
    }

    override var canBecomeKey:  Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Positioning

    /// Position: centered horizontally, top of canvas flush with screen top.
    /// y = screen.frame.maxY − canvasHeight.
    /// We use screen.frame (not visibleFrame) so the pill sits at the true
    /// top of the display, overlapping the menu bar / notch area.
    func show() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reposition()
            self.alphaValue = 1
            self.orderFrontRegardless()
            // Re-assert level — some macOS versions reset it on Space join.
            self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
            self.startProximityTracking()
        }
    }

    private func reposition() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let cw = Self.canvasSize.width
        let ch = Self.canvasSize.height
        let x = screen.frame.midX - cw / 2
        let y = screen.frame.maxY - ch          // top of canvas = top of display
        setFrame(NSRect(x: x, y: y, width: cw, height: ch), display: true)
    }

    // MARK: - Proximity state (cursor near notch → show hint)

    private func startProximityTracking() {
        guard globalMouseMonitor == nil else { return }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.evaluateProximity()
        }
    }

    private func stopProximityTracking() {
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m); globalMouseMonitor = nil }
    }

    private func evaluateProximity() {
        guard let screen = NSScreen.main else { return }
        let loc = NSEvent.mouseLocation
        // Within 200 pt horizontally of screen center AND within top 60 pt.
        let near = abs(loc.x - screen.frame.midX) < 200
                && loc.y > screen.frame.maxY - 60

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch self.model.state {
            case .idle:
                if near { self.model.state = .proximity }
            case .proximity:
                if !near { self.model.state = .idle }
            default:
                break   // don't interfere with active states
            }
        }
    }

    // MARK: - Public state API (matches FloatingChipWindow interface exactly)

    func setRecording() {
        DispatchQueue.main.async { [weak self] in
            self?.flashTimer?.invalidate()
            self?.model.state = .listening
            self?.model.audioLevel = 0
        }
    }

    func setProcessing() {
        DispatchQueue.main.async { [weak self] in
            self?.model.state = .thinking
        }
    }

    /// Called after a successful transcription + injection.
    /// Shows the Done tick for 2 s, then reverts to idle.
    func setDone() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.flashTimer?.invalidate()
            self.model.state = .done
            self.flashTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                self?.model.state = .idle
            }
        }
    }

    func setIdle() {
        DispatchQueue.main.async { [weak self] in
            self?.flashTimer?.invalidate()
            self?.model.state = .idle
            self?.model.audioLevel = 0
        }
    }

    func setHandsFree() {
        DispatchQueue.main.async { [weak self] in
            self?.model.state = .handsFree
        }
    }

    /// Called when the user presses Fn a second time or hits Escape to exit
    /// hands-free. Transitions to .thinking while the last utterance is processed.
    func setHandsFreeExitedAnimating() {
        DispatchQueue.main.async { [weak self] in
            self?.model.state = .thinking
        }
    }

    func setPermissionsAvailable(_ available: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.model.hasAllPermissions != available {
                self.model.hasAllPermissions = available
            }
        }
    }

    func updateAudioLevel(_ level: Float) {
        if Thread.isMainThread { model.audioLevel = level }
        else { DispatchQueue.main.async { [weak self] in self?.model.audioLevel = level } }
    }

    // MARK: - Error / warning flash (mirrors FloatingChipWindow)

    func flashPermissionsWarning(durationSeconds: Double = 5.0) {
        flash(
            message: "Microphone access denied — check System Settings",
            title: "Microphone access denied",
            desc: "Vordi needs microphone access to listen. Grant access in System Settings → Privacy.",
            tip: "Go to System Settings → Privacy & Security → Microphone and enable Vordi.",
            durationSeconds: durationSeconds
        )
    }

    func flashNoInputWarning(durationSeconds: Double = 4.5) {
        flash(
            message: "No input field detected — use ⌘V to paste",
            title: "No input field detected",
            desc: "Vordi couldn't find an active text field. Use ⌘V to paste the transcription manually.",
            tip: "Click into any text field first, then hold Fn to dictate directly into it.",
            durationSeconds: durationSeconds
        )
    }

    func flashNoAudioWarning(durationSeconds: Double = 3.0) {
        flash(
            message: "No audio detected — adjust mic sensitivity in Settings",
            title: "No audio detected",
            desc: "No voice was captured during the Fn hold. The noise gate may be too aggressive.",
            tip: "Increase mic sensitivity in Settings → Microphone Sensitivity.",
            durationSeconds: durationSeconds
        )
    }

    func flashNoOutputWarning(durationSeconds: Double = 4.0) {
        flash(
            message: "No output was generated — check the logs",
            title: "No output was generated",
            desc: "The flow ran but produced no text output. This may be a flow configuration issue.",
            tip: "Open the run logs to inspect which step failed or returned empty.",
            durationSeconds: durationSeconds
        )
    }

    private func flash(
        message: String,
        title: String,
        desc: String,
        tip: String,
        durationSeconds: Double
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.flashTimer?.invalidate()
            self.model.lastError = (title: title, desc: desc, tip: tip)
            self.model.state = .errorMini(message: message)
            self.flashTimer = Timer.scheduledTimer(
                withTimeInterval: durationSeconds,
                repeats: false
            ) { [weak self] _ in
                guard let self, case .errorMini = self.model.state else { return }
                self.model.state = .idle
            }
        }
    }

    deinit {
        stopProximityTracking()
        flashTimer?.invalidate()
    }
}
```

---

## 4. `NotchPillView` — Layout Spec

### Shape & Animation

```swift
// Sources/Views/NotchPillView.swift

struct NotchPillView: View {
    @ObservedObject var model: NotchPillModel

    // Spring-like cubic bezier — matches the HTML prototype's
    // cubic-bezier(0.34, 1.56, 0.64, 1.0) spring.
    private static let morphAnimation = Animation.timingCurve(0.34, 1.56, 0.64, 1.0, duration: 0.38)

    var body: some View {
        // Canvas is 500×400; pill is pinned to the TOP-CENTER of the canvas.
        VStack(spacing: 0) {
            pillShape
                .frame(width: pillWidth, height: pillHeight)
                .animation(Self.morphAnimation, value: model.state)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .center)
        // Publish visible pill rect for hit-testing
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: PillHitBoundsKey.self,
                    value: geo.frame(in: .local)
                )
            }
        )
        .onPreferenceChange(PillHitBoundsKey.self) { rect in
            model.pillHitBounds = rect
        }
    }
}
```

### Pill Shape

```swift
private var pillShape: some View {
    ZStack(alignment: .top) {
        // Solid black background — top corners flat (0), bottom corners rounded.
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: bottomRadius,
            bottomTrailingRadius: bottomRadius,
            topTrailingRadius: 0
        )
        .fill(Color.black)

        // Subtle top-edge inner highlight (white 6% opacity, 0.5 pt stroke).
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: bottomRadius,
            bottomTrailingRadius: bottomRadius,
            topTrailingRadius: 0
        )
        .stroke(Color.white.opacity(0.06), lineWidth: 0.5)

        // Vertical stack: pill row (fixed 32 pt) + panel area (animated height).
        VStack(spacing: 0) {
            pillRow
                .frame(height: 32)
            if hasPanelContent {
                panelContent
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
    }
}
```

### Computed Geometry

```swift
private var pillWidth: CGFloat {
    switch model.state {
    case .idle:                        return 220
    case .proximity:                   return 268
    case .listening, .thinking,
         .handsFree:                   return 360
    case .done:                        return 320
    case .errorMini, .panelHover,
         .panelTranscript, .panelError: return 364
    }
}

private var pillHeight: CGFloat {
    switch model.state {
    case .errorMini:        return 67
    case .panelHover:       return 225
    case .panelTranscript:  return 134
    case .panelError:       return 218
    default:                return 32
    }
}

private var bottomRadius: CGFloat {
    pillHeight > 32 ? 22 : 16
}

private var hasPanelContent: Bool {
    switch model.state {
    case .errorMini, .panelHover, .panelTranscript, .panelError: return true
    default: return false
    }
}
```

### Pill Row Layout

The pill row is always 32 pt tall. Horizontal layout:

```
[8pt pad] [VFLogoView 18×14] [10pt gap] [statusLabel] [Spacer] [indicatorView] [8pt pad]
```

- **VFLogoView**: always visible, all states.
- **statusLabel**: animates in/out via `maxWidth` + `opacity` transition.
- **indicatorView**: state-specific right-side widget.
- **Close button** (✕): visible only in panel-open states (`.panelHover`, `.panelTranscript`, `.panelError`).

```swift
private var pillRow: some View {
    HStack(spacing: 0) {
        VFLogoView()
            .padding(.leading, 8)
        statusLabel
            .padding(.leading, 10)
        Spacer()
        indicatorView
        closeButtonIfNeeded
            .padding(.trailing, 8)
    }
    .onTapGesture { handlePillTap() }
}
```

### Status Label (text, appears/disappears)

| State | Text | Color |
|-------|------|-------|
| `.idle`, `.proximity` | — (hidden) | — |
| `.listening`, `.handsFree` | "Listening" | white 90% |
| `.thinking` | "Thinking" | white 90% |
| `.done` | "Done" | white 90% |
| `.errorMini`, `.panelHover`, `.panelTranscript`, `.panelError` | — (hidden) | — |

Animate with `maxWidth: 0 → 130 pt` + `opacity: 0 → 1`:

```swift
private var statusLabel: some View {
    Text(statusText)
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.white.opacity(0.9))
        .lineLimit(1)
        .fixedSize()
        .frame(maxWidth: showsStatus ? 130 : 0)
        .opacity(showsStatus ? 1 : 0)
        .clipped()
        .animation(.easeInOut(duration: 0.22), value: model.state)
}
```

### Indicator View (right side)

| State | Widget |
|-------|--------|
| `.idle`, `.proximity` | nothing |
| `.listening`, `.handsFree` | `WaveformBarsView(audioLevel: model.audioLevel, color: .blue)` |
| `.thinking` | `ThinkingDotsView()` |
| `.done` | `GreenTickView()` |
| `.errorMini`, `.panelHover`, `.panelTranscript`, `.panelError` | nothing (or ✕ in panel states) |

### Tap Handling

```swift
private func handlePillTap() {
    switch model.state {
    case .idle, .proximity:
        model.state = .panelHover
    case .errorMini:
        guard let e = model.lastError else { return }
        model.state = .panelError(title: e.title, desc: e.desc, tip: e.tip)
    case .panelHover, .panelTranscript, .panelError:
        model.state = .idle
    default:
        break
    }
}
```

---

## 5. Sub-Component Specs

### `VFLogoView` — 5-bar micro icon

Matches the Vordi wordmark proportions. Use `Rectangle` with `Capsule` clip or `Capsule()` fills:

```swift
// Bar heights in pt: [4, 10, 14, 8, 4]
// Bar width: 2.5 pt, spacing: 2 pt
// Top of tallest bar aligns to 14 pt; shorter bars center-aligned vertically.
// Color: white opacity 0.85 in .idle/.proximity; white opacity 0.9 otherwise.

struct VFLogoView: View {
    let heights: [CGFloat] = [4, 10, 14, 8, 4]
    var color: Color = .white.opacity(0.85)

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<heights.count, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 2.5, height: heights[i])
            }
        }
        .frame(width: 18, height: 14)
    }
}
```

### `WaveformBarsView` — live audio meter

```swift
// Bar heights (base, un-scaled): [4, 10, 14, 8, 4] pt
// Driven by audioLevel (0…1): each bar scaleY = 0.22 + audioLevel * 0.78
// Width: 2.5 pt, spacing: 2 pt
// Animation: alternating ease-in-out, infinite
//   Delays:    [0.00, 0.12, 0.06, 0.18, 0.03] s
//   Durations: [0.50, 0.60, 0.52, 0.58, 0.48] s

struct WaveformBarsView: View {
    let audioLevel: Float
    let color: Color    // blue for listening, green briefly at done

    private let baseHeights: [CGFloat] = [4, 10, 14, 8, 4]
    private let delays:      [Double]  = [0.00, 0.12, 0.06, 0.18, 0.03]
    private let durations:   [Double]  = [0.50, 0.60, 0.52, 0.58, 0.48]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<baseHeights.count, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 2.5, height: baseHeights[i])
                    .scaleEffect(
                        y: 0.22 + CGFloat(audioLevel) * 0.78,
                        anchor: .center
                    )
                    .animation(
                        .easeInOut(duration: durations[i])
                            .repeatForever(autoreverses: true)
                            .delay(delays[i]),
                        value: audioLevel
                    )
            }
        }
        .frame(width: 18, height: 14)
    }
}
```

### `ThinkingDotsView` — white sequential bounce

```swift
// 3 dots, 5 pt diameter, white opacity 0.9
// Animation: Y-translate 0 → −4 pt → 0, opacity 0.35 → 1.0 → 0.35
// Delays: [0, 0.16, 0.32] s, period 0.72 s

struct ThinkingDotsView: View {
    @State private var animating = false

    private let delays: [Double] = [0, 0.16, 0.32]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.white.opacity(animating ? 1.0 : 0.35))
                    .frame(width: 5, height: 5)
                    .offset(y: animating ? -4 : 0)
                    .animation(
                        .easeInOut(duration: 0.36)
                            .repeatForever(autoreverses: true)
                            .delay(delays[i]),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
        .onDisappear { animating = false }
    }
}
```

### `GreenTickView`

```swift
struct GreenTickView: View {
    var body: some View {
        Canvas { ctx, _ in
            var path = Path()
            path.move(to:    CGPoint(x: 1.5, y: 6.0))
            path.addLine(to: CGPoint(x: 6.0, y: 10.5))
            path.addLine(to: CGPoint(x: 14.5, y: 1.5))
            ctx.stroke(
                path,
                with: .color(Color(red: 0.133, green: 0.773, blue: 0.369)),
                style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: 16, height: 12)
    }
}
```

---

## 6. Panel Content Views

### Error Mini Line (inside `.errorMini` expansion)

```swift
// 35 pt area below the 32 pt pill row = 67 pt total.
// Layout: 9 pt top pad, ⚠ icon + message text, 11 pt bottom pad.
// Separated from pill row by a 1 pt rgba(255,255,255,0.05) divider.

struct ErrorMiniPanel: View {
    let message: String

    var body: some View {
        HStack(spacing: 6) {
            Text("⚠")
                .font(.system(size: 11))
                .foregroundColor(Color(red: 0.98, green: 0.75, blue: 0.14))
            Text(message)
                .font(.system(size: 11.5, weight: .regular))
                .foregroundColor(.white.opacity(0.65))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            Rectangle()
                .fill(Color.white.opacity(0.05))
                .frame(height: 1),
            alignment: .top
        )
    }
}
```

### Hover Panel (`.panelHover`)

Content from the prototype's `mode-idle` panel:

```
─ divider ──────────────────────────────────────
[⏱ icon] "Recent Runs"                [→ Run Log]
  row: app-icon + transcript snippet + timestamp
  row: app-icon + transcript snippet + timestamp
  row: app-icon + transcript snippet + timestamp
─ divider ──────────────────────────────────────
[⚙] "Settings"                  [⊞ Open Vordi]
```

- Data source: read last 3 items from `RunStore.shared.recentRuns` (read-only, no writes from this view)
- Tapping "Run Log" or "Open Vordi": post `Vordi.OpenMainWindow` / `Vordi.OpenRunLog` via `NotificationCenter` (same pattern as the old chip)
- Tapping "Settings": post `Vordi.OpenSettings`

### Transcript Panel (`.panelTranscript`)

```
─ header ─────────────────────────────────────────
● LISTENING                         [waveform bars]
─ body ───────────────────────────────────────────
  live transcript text (auto-scroll, grows bottom-up)
─ footer ─────────────────────────────────────────
Release Fn to send                     [✕ Cancel]
```

- `model.liveTranscript` feeds the body text. Wired by AppDelegate (see §8).
- Cancel button: calls `AppDelegate.stopRecording()` then `notchPill?.setIdle()`

### Error Detail Panel (`.panelError`)

```
─ body ───────────────────────────────────────────
  [⚠ Error badge]
  title (bold, 13 pt)
  desc (12 pt, white 65%, 2 lines max)
  [💡 tip box (dark bg, 11 pt)]
─ footer ─────────────────────────────────────────
  [Try Again]              [View Logs]
```

- "Try Again": close panel → `model.state = .idle`
- "View Logs": post `Vordi.OpenRunLog`

---

## 7. Preference Key (hit-testing)

```swift
// Defined at file scope in NotchPillView.swift

private struct PillHitBoundsKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}
```

---

## 8. AppDelegate Changes (`Sources/App/VordiApp.swift`)

### A. Property swap

```swift
// Remove:
var floatingChip: FloatingChipWindow?

// Add:
var notchPill: NotchPillWindow?
```

### B. `installFloatingChip()` → `installNotchPill()`

```swift
func installNotchPill() {
    if notchPill == nil {
        notchPill = NotchPillWindow()
    }
    notchPill?.show()
}
```

### C. Full call-site replacement (grep for `floatingChip`)

| Old | New |
|-----|-----|
| `installFloatingChip()` | `installNotchPill()` |
| `floatingChip?.show()` | `notchPill?.show()` |
| `floatingChip?.setRecording()` | `notchPill?.setRecording()` |
| `floatingChip?.setProcessing()` | `notchPill?.setProcessing()` |
| `floatingChip?.setIdle()` | `notchPill?.setIdle()` |
| `floatingChip?.setHandsFree()` | `notchPill?.setHandsFree()` |
| `floatingChip?.setHandsFreeExitedAnimating()` | `notchPill?.setHandsFreeExitedAnimating()` |
| `floatingChip?.flashPermissionsWarning(...)` | `notchPill?.flashPermissionsWarning(...)` |
| `floatingChip?.flashNoInputWarning(...)` | `notchPill?.flashNoInputWarning(...)` |
| `floatingChip?.flashNoAudioWarning(...)` | `notchPill?.flashNoAudioWarning(...)` |
| `floatingChip?.flashNoOutputWarning(...)` | `notchPill?.flashNoOutputWarning(...)` |
| `floatingChip?.setPermissionsAvailable(...)` | `notchPill?.setPermissionsAvailable(...)` |
| `floatingChip?.updateAudioLevel(...)` | `notchPill?.updateAudioLevel(...)` |
| `chip?.updateAudioLevel(level)` (in closure) | `chip?.updateAudioLevel(level)` (rename capture to `chip = notchPill`) |

### D. Done state: replace `hideRecordingOverlay` success path

Current `hideRecordingOverlay()`:
```swift
private func hideRecordingOverlay() {
    audioRecorder?.onAmplitude = nil
    floatingChip?.setIdle()
}
```

New — `setIdle()` is still correct for the EARLY exit paths (permission abort, no audio). The Done state is triggered by the **success branch** specifically. Locate `persistAndInject` and add before `textInjector?.injectText(...)`:

```swift
// In persistAndInject, AFTER guard !trimmed.isEmpty:
self.notchPill?.setDone()
self.textInjector?.injectText(trimmed, targetBundleIdentifier: targetBundleIdentifier)
```

And replace `hideRecordingOverlay()` to use `setIdle()` for non-success:

```swift
private func hideRecordingOverlay() {
    audioRecorder?.onAmplitude = nil
    notchPill?.setIdle()    // only for cancel/abort/error paths now
}
```

> The `.done` state auto-reverts to `.idle` after 2 s inside `NotchPillWindow.setDone()`. No extra timer needed in AppDelegate.

### E. Error state on transcription failure

In `handleResult(.failure)`, currently only `session.fail()` is called (and `hideRecordingOverlay` → setIdle). Add:

```swift
case .failure(let error):
    // ... existing session.fail(reason:) code ...
    self.notchPill?.flashNoOutputWarning()   // or a more specific flash depending on error type
```

### F. Live transcript wiring

In `setupRealtimeStreamIfEnabled()`, after `stream` is created:

```swift
stream.onPartialTranscript = { [weak self] text in
    DispatchQueue.main.async {
        self?.notchPill?.model.liveTranscript = text
    }
}
```

Clear on session end in `hideRecordingOverlay()`:
```swift
notchPill?.model.liveTranscript = ""
```

> Check `RealtimeTranscriptionService` for the correct callback property name — it may differ from `onPartialTranscript`.

---

## 9. Animation Reference (from HTML prototype)

| Property | CSS source | Swift equivalent |
|----------|-----------|-----------------|
| Width/height morph | `cubic-bezier(0.34, 1.56, 0.64, 1.0) 0.38s` | `.timingCurve(0.34, 1.56, 0.64, 1.0, duration: 0.38)` |
| Status text fade-in | `opacity .22s ease .1s` | `.easeIn(duration: 0.22).delay(0.1)` |
| Status text width | `max-width .3s ease` | `frame(maxWidth:)` animated with `.easeInOut(duration: 0.3)` |
| Panel content appear | `opacity .2s` | `.opacity` transition |
| Waveform bars | `ease-in-out .48–.60s alternate infinite` | `.easeInOut(duration:).repeatForever(autoreverses: true)` |
| Thinking dots | `0.72s ease-in-out, sequential` | `.easeInOut(duration: 0.36).repeatForever(autoreverses: true).delay(n*0.16)` |

---

## 10. Colors

| Token | Hex | SwiftUI |
|-------|-----|---------|
| Pill background | `#000000` | `.black` |
| Inner highlight | `rgba(255,255,255,0.06)` | `.white.opacity(0.06)` |
| Status text | `rgba(255,255,255,0.9)` | `.white.opacity(0.9)` |
| Waveform blue | `#3b82f6` | `Color(red: 0.231, green: 0.510, blue: 0.965)` |
| Done green | `#22c55e` | `Color(red: 0.133, green: 0.773, blue: 0.369)` |
| Error amber | `#fbbf24` | `Color(red: 0.984, green: 0.749, blue: 0.141)` |
| Error dim text | `rgba(255,255,255,0.65)` | `.white.opacity(0.65)` |
| Panel divider | `rgba(255,255,255,0.06)` | `.white.opacity(0.06)` |
| Panel body text | `rgba(255,255,255,0.75)` | `.white.opacity(0.75)` |

---

## 11. Non-Notched Mac Fallback

On Macs without a physical notch, the pill still sits at the top center of the screen, centered in the menu bar. The behavior and dimensions are identical — the menu bar hides items to leave room, and the black pill reads as an extension of the menu bar itself. No code changes needed for this case; the positioning logic already handles it.

---

## 12. Implementation Order

1. Create `NotchPillComponents.swift` (pure SwiftUI views, no dependencies)
2. Create `NotchPillWindow.swift` (model + window, no UI yet)
3. Create `NotchPillView.swift` (connects model to components)
4. Build + check for compilation errors in the three new files
5. Modify `MainDashboardView.swift` — delete the `FloatingChipWindow` block
6. Modify `VordiApp.swift` — swap all call sites
7. Run the app, press Fn, verify each state transitions correctly
8. Verify positions on screen with notch guide overlay (toggle in `vordi-notch.html`)
