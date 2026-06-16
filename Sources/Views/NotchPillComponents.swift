import SwiftUI
import AppKit

enum NotchPillPalette {
    static let fill = Color.black
    static let mark = Color(red: 0.94, green: 0.94, blue: 0.94)
    static let success = Color(red: 0.28, green: 0.86, blue: 0.54)
    static let blue = Color(red: 0.04, green: 0.56, blue: 1.00)
    static let cyan = Color(red: 0.18, green: 0.91, blue: 1.00)
    static let violet = Color(red: 0.59, green: 0.16, blue: 1.00)
    static let magenta = Color(red: 1.00, green: 0.28, blue: 0.90)
    static let thinking = Color(red: 0.70, green: 0.18, blue: 1.00)
    static let warning = Color(red: 0.98, green: 0.63, blue: 0.22)
    static let failure = Color(red: 0.95, green: 0.30, blue: 0.25)
}

struct NotchPillBaseShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let topRadius = min(topCornerRadius, rect.width / 4, rect.height / 2)
        let bottomRadius = min(bottomCornerRadius, rect.width / 4, rect.height / 2)
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius, y: rect.minY + topRadius),
            control: CGPoint(x: rect.minX + topRadius, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + topRadius, y: rect.maxY - bottomRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius + bottomRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topRadius - bottomRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topRadius, y: rect.maxY - bottomRadius),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY + topRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.minY)
        )
        path.closeSubpath()

        return path
    }
}

enum NotchSwipeDirection {
    case left
    case right
}

/// Transparent overlay that captures two-finger horizontal trackpad scrolls
/// via a local event monitor. It never participates in hit testing, so
/// clicks and taps pass straight through.
struct NotchTrackpadSwipeOverlay: NSViewRepresentable {
    var enabled: Bool
    let onSwipe: (NotchSwipeDirection) -> Void

    func makeNSView(context: Context) -> NotchTrackpadSwipeView {
        let view = NotchTrackpadSwipeView()
        view.enabled = enabled
        view.onSwipe = onSwipe
        return view
    }

    func updateNSView(_ nsView: NotchTrackpadSwipeView, context: Context) {
        nsView.enabled = enabled
        nsView.onSwipe = onSwipe
    }
}

final class NotchTrackpadSwipeView: NSView {
    var enabled = false
    var onSwipe: ((NotchSwipeDirection) -> Void)?

    private var monitor: Any?
    private var accumulatedDeltaX: CGFloat = 0
    private var hasFired = false
    private let threshold: CGFloat = 30

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handleScroll(event)
                return event
            }
        } else if window == nil {
            removeMonitor()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func handleScroll(_ event: NSEvent) {
        guard enabled,
              let window,
              event.window == window,
              event.hasPreciseScrollingDeltas else { return }

        switch event.phase {
        case .began:
            accumulatedDeltaX = 0
            hasFired = false

        case .changed:
            guard !hasFired else { return }
            accumulatedDeltaX += event.scrollingDeltaX

            if abs(accumulatedDeltaX) >= threshold {
                hasFired = true
                let direction: NotchSwipeDirection = accumulatedDeltaX < 0 ? .left : .right
                DispatchQueue.main.async { [weak self] in
                    self?.onSwipe?(direction)
                }
            }

        case .ended, .cancelled:
            accumulatedDeltaX = 0
            hasFired = false

        default:
            break
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit {
        removeMonitor()
    }
}

struct VFLogoView: View {
    var color: Color = NotchPillPalette.mark.opacity(0.92)

    var body: some View {
        Group {
            if let image = AppBrand.logoImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                HStack(alignment: .center, spacing: 1.4) {
                    ForEach(0..<5, id: \.self) { index in
                        Capsule()
                            .fill(color)
                            .frame(width: 1.8, height: markHeight(for: index))
                    }
                }
            }
        }
    }

    private func markHeight(for index: Int) -> CGFloat {
        [5, 9, 12, 8, 5][index]
    }
}

struct NotchPulseView: View {
    let color: Color

    var body: some View {
        Text("fn")
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundColor(NotchPillPalette.mark.opacity(0.56))
            .tracking(0.2)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(NotchPillPalette.mark.opacity(0.055))
                    .overlay {
                        Capsule()
                            .stroke(NotchPillPalette.mark.opacity(0.075), lineWidth: 0.7)
                    }
            )
    }
}

struct WaveformBarsView: View {
    let audioLevel: Float
    let color: Color

    private static let multipliers: [CGFloat] = [0.45, 0.75, 1.0, 0.70, 0.45]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Self.multipliers.indices, id: \.self) { index in
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                color.opacity(0.72),
                                NotchPillPalette.cyan.opacity(0.95)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 2, height: barHeight(for: index))
                    .shadow(color: color.opacity(0.85), radius: 4, x: 0, y: 0)
                    .shadow(color: NotchPillPalette.cyan.opacity(0.36), radius: 8, x: 0, y: 0)
                    .animation(.easeOut(duration: 0.10), value: audioLevel)
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let level = max(CGFloat(audioLevel), 0.12)
        let minHeight: CGFloat = 3
        let maxHeight: CGFloat = 14
        let amplitude = min(level * Self.multipliers[index], 1)
        return minHeight + (maxHeight - minHeight) * amplitude
    }
}

struct ThinkingDotsView: View {
    var color: Color = NotchPillPalette.thinking

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: false)) { context in
            let time = context.date.timeIntervalSinceReferenceDate

            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    let phase = 0.5 + 0.5 * sin((time * 7.0) - Double(index) * 0.72)
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    color.opacity(0.60 + phase * 0.25),
                                    NotchPillPalette.magenta.opacity(0.78 + phase * 0.22)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: 3.5, height: 3.5)
                        .offset(y: -CGFloat(phase) * 2.5)
                        .shadow(color: color.opacity(0.75), radius: 4, x: 0, y: 0)
                        .shadow(color: NotchPillPalette.magenta.opacity(0.38), radius: 8, x: 0, y: 0)
                }
            }
        }
    }
}

struct NotchStateGlowView: View {
    let color: Color
    let secondaryColor: Color
    let intensity: Double

    var body: some View {
        ZStack(alignment: .trailing) {
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            secondaryColor.opacity(0.50 * intensity),
                            color.opacity(0.30 * intensity),
                            color.opacity(0.08 * intensity),
                            .clear
                        ],
                        center: .center,
                        startRadius: 2,
                        endRadius: 36
                    )
                )
                .frame(width: 76, height: 46)
                .blur(radius: 7)
                .offset(x: 20, y: 8)

            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            secondaryColor.opacity(0.26 * intensity),
                            color.opacity(0.16 * intensity),
                            .clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 25
                    )
                )
                .frame(width: 44, height: 28)
                .blur(radius: 3.5)
                .offset(x: 5, y: 7)

            LinearGradient(
                colors: [
                    .clear,
                    color.opacity(0.075 * intensity),
                    secondaryColor.opacity(0.12 * intensity)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 58, height: 28)
            .offset(x: 6, y: 7)
        }
        .allowsHitTesting(false)
    }
}

enum NotchActiveGlowMode {
    case listening
    case thinking
}

struct NotchActiveStateGlowView: View {
    let color: Color
    let secondaryColor: Color
    let mode: NotchActiveGlowMode

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: false)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let breath = 0.86 + 0.14 * sin(time * (mode == .thinking ? 2.2 : 1.55))
            let shimmer = 0.72 + 0.28 * sin(time * (mode == .thinking ? 4.0 : 2.8))

            ZStack(alignment: .trailing) {
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [
                                secondaryColor.opacity(0.58 * breath),
                                color.opacity(0.38 * breath),
                                color.opacity(0.16 * breath),
                            .clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 42
                        )
                    )
                    .frame(width: 88, height: 50)
                    .blur(radius: 7)
                    .offset(x: 22, y: 8)

                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [
                                secondaryColor.opacity(0.44 * shimmer),
                                color.opacity(0.20 * shimmer),
                            .clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 25
                        )
                    )
                    .frame(width: 48, height: 30)
                    .blur(radius: 3.5)
                    .offset(x: 4, y: 7)

                LinearGradient(
                    colors: [
                        .clear,
                        color.opacity(0.10 * breath),
                        secondaryColor.opacity(0.18 * shimmer)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 64, height: 30)
                .blur(radius: 1.2)
                .offset(x: 5, y: 7)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                .clear,
                                secondaryColor.opacity(0.42 * shimmer),
                                color.opacity(0.24 * breath)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 2, height: 24)
                    .blur(radius: 1.2)
                    .offset(x: -5, y: 6)
            }
            .opacity(mode == .thinking ? 0.66 : 0.70)
        }
        .allowsHitTesting(false)
    }
}

struct NotchGlowDotsView: View {
    let color: Color
    var count: Int = 4
    var animated: Bool = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 16.0, paused: !animated)) { context in
            let time = context.date.timeIntervalSinceReferenceDate

            HStack(spacing: 3) {
                ForEach(0..<count, id: \.self) { index in
                    let phase = animated
                        ? 0.74 + 0.26 * sin((time * 4.2) - Double(index) * 0.52)
                        : 0.72

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    color.opacity(0.62),
                                    NotchPillPalette.cyan.opacity(0.96)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 5, height: 7 + CGFloat(index % 2) * 1.5)
                        .opacity(phase)
                        .shadow(color: color.opacity(0.70), radius: 4, x: 0, y: 0)
                        .shadow(color: NotchPillPalette.cyan.opacity(0.32), radius: 7, x: 0, y: 0)
                }
            }
        }
    }
}

struct GreenTickView: View {
    var body: some View {
        Canvas { ctx, _ in
            var path = Path()
            path.move(to: CGPoint(x: 1.5, y: 6.0))
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

struct NotchTranscriptCursorView: View {
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 8.0, paused: false)) { context in
            let phase = Int(context.date.timeIntervalSinceReferenceDate * 2)
            Capsule()
                .fill(color.opacity(phase.isMultiple(of: 2) ? 0.72 : 0.12))
        }
    }
}

struct NotchPanelRowBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(NotchPillPalette.mark.opacity(0.035))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(NotchPillPalette.mark.opacity(0.055), lineWidth: 1)
            }
    }
}

struct NotchPanelIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(NotchPillPalette.mark.opacity(configuration.isPressed ? 0.88 : 0.48))
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(NotchPillPalette.mark.opacity(configuration.isPressed ? 0.14 : 0.06))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(NotchPillPalette.mark.opacity(0.07), lineWidth: 1)
            }
    }
}

struct NotchPanelCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(NotchPillPalette.mark.opacity(configuration.isPressed ? 0.82 : 0.40))
            .background(
                Circle()
                    .fill(NotchPillPalette.mark.opacity(configuration.isPressed ? 0.13 : 0.07))
            )
            .overlay {
                Circle()
                    .stroke(NotchPillPalette.mark.opacity(configuration.isPressed ? 0.12 : 0.06), lineWidth: 1)
            }
    }
}

struct NotchErrorPrimaryButtonStyle: ButtonStyle {
    var accent: Color = NotchPillPalette.warning

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(accent.opacity(configuration.isPressed ? 1.0 : 0.92))
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(accent.opacity(configuration.isPressed ? 0.20 : 0.12))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(accent.opacity(configuration.isPressed ? 0.32 : 0.24), lineWidth: 1)
            }
    }
}

struct NotchErrorSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(NotchPillPalette.mark.opacity(configuration.isPressed ? 0.78 : 0.46))
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(NotchPillPalette.mark.opacity(configuration.isPressed ? 0.10 : 0.045))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(NotchPillPalette.mark.opacity(configuration.isPressed ? 0.12 : 0.065), lineWidth: 1)
            }
    }
}

struct NotchPanelFeatureButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(NotchPillPalette.mark.opacity(configuration.isPressed ? 0.90 : 0.62))
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(NotchPillPalette.mark.opacity(configuration.isPressed ? 0.12 : 0.045))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(NotchPillPalette.mark.opacity(configuration.isPressed ? 0.13 : 0.06), lineWidth: 1)
            }
    }
}
