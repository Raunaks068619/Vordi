import SwiftUI
import AppKit

/// Dashboard for usage stats. Pure view layer — every number is computed
/// from `RunStore.summaries` on the fly. No background jobs, no caching
/// layer of its own; the index file is the source of truth.
///
/// **Design language**: the app's current product system. Warm surfaces,
/// compact cards, purple/black-highlighted data, restrained borders, and
/// interpretation copy grounded in the user's actual run history.
///
/// **Empty state**: shown when there are zero runs in the store. Avoids
/// the awful "0 runs · 0 words · NaN WPM" first-launch UI.
///
/// **Backwards-compat**: pre-existing runs in the store don't have
/// `wordCount` / `frontmostBundleID` / `profileUsed` populated. We compute
/// `wordCount` from `previewText` lazily so the totals don't read 0 on
/// upgrade. App / profile breakdowns gracefully degrade to "no data yet"
/// blocks until the next dictation populates them.
struct InsightsView: View {
    @ObservedObject var runStore: RunStore
    @StateObject private var classifier = UserTypeClassifier.shared
    @StateObject private var indexer = IndexerService.shared
    @State private var selectedTab: InsightTab
    @State private var cachedStats = ComputedStats.empty

    private enum InsightTab: String, CaseIterable {
        case usage = "Usage"
        case voice = "Voice"

        var title: String {
            switch self {
            case .usage: return "Your Usage"
            case .voice: return "Your Voice"
            }
        }
    }

    init(runStore: RunStore, initialTab: String? = nil) {
        self.runStore = runStore
        let resolvedTab = initialTab.flatMap(InsightTab.init(rawValue:)) ?? .usage
        _selectedTab = State(initialValue: resolvedTab)
    }

    private enum Tone {
        static let ink = Theme.textPrimary
        static let muted = Theme.textSecondary
        static let faint = Theme.textTertiary
        static let accent = Theme.interactive
        static let accentSoft = Theme.interactiveSoft
        static let strongAccent = Theme.textPrimary
        static let track = Theme.secondaryButtonFill
    }

    private var tabSelection: Binding<String> {
        Binding(
            get: { selectedTab.rawValue },
            set: { raw in
                if let tab = InsightTab(rawValue: raw) {
                    selectedTab = tab
                }
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                header

                if runStore.summaries.isEmpty {
                    emptyStateCard
                } else {
                    switch selectedTab {
                    case .usage:
                        usageContent
                    case .voice:
                        voiceContent
                    }
                }
            }
            .frame(maxWidth: 1180, alignment: .leading)
            .padding(.horizontal, Theme.Layout.contentHPad)
            .padding(.top, Theme.Layout.contentVPad)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Theme.mainContent)
        .onAppear {
            refreshStats()
        }
        .onReceive(runStore.$summaries) { summaries in
            cachedStats = ComputedStats.compute(from: summaries)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            HStack(alignment: .center, spacing: Theme.Space.sm) {
                Text("Insights")
                    .font(.vfPageTitle)
                    .foregroundColor(Tone.ink)
                VFBadge(label: "Local", style: .plan)
                Spacer()
                VFButton(
                    title: "Copy summary",
                    icon: "square.and.arrow.up",
                    style: .secondary,
                    isCompact: true,
                    action: copyInsightsSummary
                )
            }

            VStack(alignment: .leading, spacing: 0) {
                VFTabBar(
                    options: InsightTab.allCases.map { (id: $0.rawValue, label: $0.title) },
                    selection: tabSelection
                )
                Rectangle()
                    .fill(Theme.divider)
                    .frame(height: 1)
                    .offset(y: -1)
            }
        }
    }

    private func copyInsightsSummary() {
        let summary = """
        Vordi Insights
        WPM: \(stats.averageWPM > 0 ? "\(stats.averageWPM)" : "—")
        Runs: \(stats.totalRuns)
        Words: \(stats.totalWords.formatted())
        Current streak: \(stats.currentStreakDays) day\(stats.currentStreakDays == 1 ? "" : "s")
        Top app: \(stats.topAppName ?? "No app data yet")
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
    }

    // MARK: - Usage

    private var usageContent: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            overviewGrid

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    desktopUsageCard.frame(maxWidth: .infinity)
                    streakCard.frame(maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 20) {
                    desktopUsageCard
                    streakCard
                }
            }
        }
    }

    private var overviewGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 168), spacing: Theme.Space.md)],
            alignment: .leading,
            spacing: Theme.Space.md
        ) {
            statTile(
                title: "Average pace",
                value: stats.averageWPM > 0 ? "\(stats.averageWPM)" : "—",
                detail: "words per minute",
                icon: "speedometer",
                emphasis: stats.averageWPM > 0
            )
            statTile(
                title: "Words dictated",
                value: stats.totalWords.formatted(),
                detail: "local transcripts",
                icon: "text.quote",
                emphasis: stats.totalWords > 0
            )
            statTile(
                title: "Dictations",
                value: "\(stats.totalRuns)",
                detail: "\(stats.successRuns) successful",
                icon: "waveform",
                emphasis: stats.totalRuns > 0
            )
            statTile(
                title: "Success rate",
                value: successRateText,
                detail: "\(stats.failedRuns + stats.noSpeechRuns) need attention",
                icon: "checkmark.seal",
                emphasis: stats.successRuns > 0
            )
            statTile(
                title: "Current streak",
                value: "\(stats.currentStreakDays)d",
                detail: "longest \(stats.longestStreakDays)d",
                icon: "flame",
                emphasis: stats.currentStreakDays > 0
            )
            statTile(
                title: "Top app",
                value: stats.topAppName ?? "—",
                detail: stats.topApps.first.map { "\($0.count) runs" } ?? "no app data yet",
                icon: "square.grid.2x2",
                emphasis: stats.topAppName != nil
            )
        }
    }

    private var desktopUsageCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            HStack(alignment: .firstTextBaseline) {
                Text("App usage")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Tone.ink)
                Spacer()
                metricPill("\(stats.topApps.count) apps")
            }

            if stats.topApps.isEmpty {
                hintRow("No app data yet — dictate again with Context Capture on.")
                    .padding(.top, 14)
            } else {
                VStack(spacing: Theme.Space.md) {
                    ForEach(stats.topApps, id: \.bundleID) { app in
                        appDetailRow(app)
                    }
                }
            }
        }
        .frame(minHeight: 344, alignment: .top)
        .insightCard(padding: 24)
    }

    private var streakCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            HStack(alignment: .firstTextBaseline) {
                Text("Dictation rhythm")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Tone.ink)
                Spacer()
                metricPill("\(stats.currentStreakDays)d current, \(stats.longestStreakDays)d longest")
            }

            StreakHeatmapView(weeks: stats.heatmapWeeks, accent: Tone.accent, softAccent: Tone.accentSoft)
        }
        .frame(minHeight: 344, alignment: .top)
        .insightCard(padding: 24)
    }

    // MARK: - Voice

    private var voiceContent: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            userTypeCard

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    appBreakdownCard.frame(maxWidth: .infinity)
                    profileBreakdownCard.frame(maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 20) {
                    appBreakdownCard
                    profileBreakdownCard
                }
            }
        }
    }

    /// Adaptive card with three visual states:
    ///   - Locked   → progress bar + "X / 20 transcripts" copy
    ///   - Loading  → spinner + "Analyzing your patterns…"
    ///   - Unlocked → role badge, headline, signal chips, refresh button
    @ViewBuilder
    private var userTypeCard: some View {
        let eligibility = classifier.eligibility()
        if !eligibility.isUnlocked {
            lockedUserTypeCard(eligibility: eligibility)
        } else if classifier.isClassifying || indexer.isWorking {
            loadingUserTypeCard()
        } else if let classification = classifier.classification {
            unlockedUserTypeCard(classification)
        } else {
            readyUserTypeCard()
        }
    }

    private func lockedUserTypeCard(eligibility: UserTypeEligibility) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Text("Voice profile")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Tone.ink)
                Spacer()
                VFBadge(label: "Locked", style: .plan)
            }

            Text("Dictate \(eligibility.requiredRuns) substantive transcriptions with at least \(eligibility.requiredWordsPerRun) words each. \(AppBrand.name) will then summarize your working style from real usage.")
                .font(.system(size: 13))
                .foregroundColor(Tone.muted)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(eligibility.qualifyingRuns) / \(eligibility.requiredRuns) qualifying")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Tone.ink)
                    Spacer()
                    Text("\(Int(eligibility.progress * 100))%")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundColor(Tone.muted)
                }
                progressBar(eligibility.progress)
            }
        }
        .insightCard(padding: 24)
    }

    private func loadingUserTypeCard() -> some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                Text("Voice profile")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Tone.ink)
                Text(classifier.lastError ?? "Syncing saved transcripts and analyzing your patterns...")
                    .font(.system(size: 13))
                    .foregroundColor(classifier.lastError == nil ? Tone.muted : Theme.warning)
            }
            Spacer()
        }
        .insightCard(padding: 24)
    }

    private func readyUserTypeCard() -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                VFBrandLogo(size: 36, variant: .light, cornerRadius: 9)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Voice profile not generated yet")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(Tone.ink)
                    Text("Sync from saved transcriptions to classify your working style.")
                        .font(.system(size: 13))
                        .foregroundColor(Tone.muted)
                }
                Spacer()
                syncInsightsButton(label: "SYNC")
            }

            Text("Insights now run only when you ask, so app launch and dictation stay lightweight.")
                .font(.system(size: 13))
                .foregroundColor(Tone.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .insightCard(padding: 24)
    }

    private func unlockedUserTypeCard(_ classification: UserTypeClassification) -> some View {
        let (r, g, b) = classification.role.tintRGB
        let tint = Color(red: r, green: g, blue: b)

        return VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: classification.role.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(tint))

                VStack(alignment: .leading, spacing: 4) {
                    Text(classification.role.displayLabel)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(Tone.ink)
                    Text(classification.headline)
                        .font(.system(size: 13))
                        .foregroundColor(Tone.muted)
                }

                Spacer()

                syncInsightsButton(label: "")
            }

            if !classification.signals.isEmpty {
                FlowLayout(spacing: 7) {
                    ForEach(classification.signals, id: \.self) { signal in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(tint)
                                .frame(width: 5, height: 5)
                            Text(signal)
                                .font(.system(size: 12))
                                .foregroundColor(Tone.ink)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Theme.surfaceElevated))
                        .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
                    }
                }
            }

            HStack(spacing: 16) {
                miniMetadata(icon: "doc.text", label: "\(classification.runsAnalyzed) transcripts")
                miniMetadata(icon: "gauge.medium", label: "\(Int(classification.confidence * 100))% confidence")
                miniMetadata(icon: "clock", label: relativeTime(classification.computedAt))
                Spacer()
            }
        }
        .insightCard(padding: 24)
    }

    @ViewBuilder
    private func syncInsightsButton(label: String) -> some View {
        if label.isEmpty {
            Button(action: syncInsights) {
                Image(systemName: classifier.isClassifying || indexer.isWorking ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Tone.muted)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.surfaceElevated))
                    .overlay(Circle().strokeBorder(Theme.divider, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .vfClickableCursor()
            .disabled(classifier.isClassifying || indexer.isWorking)
            .help("Sync Memory and re-analyze latest transcripts")
        } else {
            VFButton(title: label, icon: "arrow.triangle.2.circlepath", style: .primary, isCompact: true, isLoading: classifier.isClassifying || indexer.isWorking) {
                syncInsights()
            }
            .help("Sync Memory and re-analyze latest transcripts")
        }
    }

    private func syncInsights() {
        Task {
            await indexer.syncNow()
            await classifier.classify(force: true)
        }
    }

    private var appBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Peak apps")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(Tone.ink)
            if stats.topApps.isEmpty {
                hintRow("No app data yet.")
            } else {
                VStack(spacing: 10) {
                    ForEach(stats.topApps, id: \.bundleID) { app in
                        compactAppBreakdownRow(app)
                    }
                }
            }
        }
        .insightCard()
    }

    private var profileBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Used modes")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(Tone.ink)
            if stats.topProfiles.isEmpty {
                hintRow("Profile usage will appear after your first context-aware dictation.")
            } else {
                VStack(spacing: 10) {
                    ForEach(stats.topProfiles, id: \.profile) { entry in
                        compactBreakdownRow(label: entry.label, count: entry.count, total: stats.totalRuns)
                    }
                }
            }
        }
        .insightCard()
    }

    // MARK: - Empty state

    private var emptyStateCard: some View {
        VStack(alignment: .center, spacing: 12) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 34, weight: .light))
                .foregroundColor(Tone.muted)
            Text("No dictations yet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Tone.ink)
            Text("Hold Fn anywhere to start. Usage cards, app breakdowns, and streaks appear here as soon as you dictate.")
                .font(.system(size: 13))
                .foregroundColor(Tone.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .insightCard(padding: 24)
    }

    // MARK: - Building blocks

    private func metricPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(Tone.muted)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(Capsule(style: .continuous).fill(Theme.secondaryButtonFill))
    }

    private func statTile(
        title: String,
        value: String,
        detail: String,
        icon: String,
        emphasis: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(alignment: .center) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(emphasis ? Tone.accent : Tone.faint)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.RadiusExtra.input, style: .continuous)
                            .fill(emphasis ? Tone.accentSoft : Theme.secondaryButtonFill)
                    )
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(Tone.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .monospacedDigit()
                Text(title)
                    .font(.vfCaption)
                    .foregroundColor(Tone.muted)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(Tone.faint)
                    .lineLimit(1)
            }
        }
        .frame(minHeight: 132, alignment: .topLeading)
        .insightCard(padding: Theme.Space.lg)
    }

    private func appDetailRow(_ app: ComputedStats.AppEntry) -> some View {
        let percent = app.percent(of: stats.totalRuns)

        return HStack(alignment: .center, spacing: Theme.Space.md) {
            InsightAppIcon(app: app, size: 28)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(app.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Tone.ink)
                        .lineLimit(1)
                    Spacer()
                    Text("\(app.count)")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundColor(Tone.muted)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(Tone.track)
                        Capsule(style: .continuous)
                            .fill(Tone.strongAccent)
                            .frame(width: max(4, geo.size.width * percent))
                    }
                }
                .frame(height: 7)

                Text("\(app.words.formatted()) words")
                    .font(.system(size: 11))
                    .foregroundColor(Tone.faint)
            }
        }
        .padding(.vertical, 2)
    }

    private func compactBreakdownRow(label: String, count: Int, total: Int) -> some View {
        let percent = total > 0 ? Double(count) / Double(total) : 0
        return HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Tone.ink)
                .frame(width: 160, alignment: .leading)
                .lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Tone.track)
                        .frame(height: 8)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Tone.strongAccent)
                        .frame(width: max(3, geo.size.width * percent), height: 8)
                }
            }
            .frame(height: 8)
            Text("\(count)")
                .font(.system(size: 12).monospacedDigit())
                .foregroundColor(Tone.muted)
                .frame(width: 30, alignment: .trailing)
        }
    }

    private func compactAppBreakdownRow(_ app: ComputedStats.AppEntry) -> some View {
        let percent = stats.totalRuns > 0 ? Double(app.count) / Double(stats.totalRuns) : 0
        return HStack(spacing: 10) {
            InsightAppIcon(app: app, size: 18)
            Text(app.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Tone.ink)
                .frame(width: 134, alignment: .leading)
                .lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Tone.track)
                        .frame(height: 8)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Tone.strongAccent)
                        .frame(width: max(3, geo.size.width * percent), height: 8)
                }
            }
            .frame(height: 8)
            Text("\(app.count)")
                .font(.system(size: 12).monospacedDigit())
                .foregroundColor(Tone.muted)
                .frame(width: 30, alignment: .trailing)
        }
    }

    private func progressBar(_ progress: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Tone.track)
                    .frame(height: 8)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Tone.strongAccent)
                    .frame(width: max(2, geo.size.width * progress), height: 8)
            }
        }
        .frame(height: 8)
    }

    private func miniMetadata(icon: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
            Text(label)
                .font(.system(size: 11))
        }
        .foregroundColor(Tone.faint)
    }

    private func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func hintRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(Tone.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var stats: ComputedStats {
        cachedStats
    }

    private var successRateText: String {
        guard stats.totalRuns > 0 else { return "—" }
        let rate = Double(stats.successRuns) / Double(stats.totalRuns)
        return "\(Int((rate * 100).rounded()))%"
    }

    private func refreshStats() {
        cachedStats = ComputedStats.compute(from: runStore.summaries)
    }
}

// MARK: - Drawing

private struct StreakHeatmapView: View {
    let weeks: [[ComputedStats.HeatmapDay]]
    let accent: Color
    let softAccent: Color

    private let dayLabels = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Spacer().frame(width: 36)
                ForEach(monthMarkers, id: \.offset) { marker in
                    Text(marker.month)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }

            VStack(spacing: 8) {
                ForEach(0..<7, id: \.self) { weekday in
                    HStack(spacing: 8) {
                        Text(dayLabels[weekday])
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Theme.textTertiary)
                            .frame(width: 36, alignment: .leading)
                        ForEach(weeks.indices, id: \.self) { week in
                            let day = weeks[week][weekday]
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(color(for: day.runs))
                                .frame(width: 15, height: 15)
                                .help("\(day.runs) dictation\(day.runs == 1 ? "" : "s") on \(day.label)")
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Text("More")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textTertiary)
                ForEach([4, 3, 2, 1], id: \.self) { level in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(color(for: level))
                        .frame(width: 15, height: 15)
                }
                Text("Less")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(.leading, 36)
            .padding(.top, 2)
        }
    }

    private var monthMarkers: [(offset: Int, month: String)] {
        guard let firstWeek = weeks.first else { return [] }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        var seen: Set<String> = []
        var markers: [(Int, String)] = []
        for (index, week) in weeks.enumerated() {
            guard let day = week.first else { continue }
            let month = formatter.string(from: day.date)
            if index == 0 || !seen.contains(month) || index == weeks.count - 1 {
                seen.insert(month)
                markers.append((index, month))
            }
        }
        if markers.isEmpty, let day = firstWeek.first {
            markers.append((0, formatter.string(from: day.date)))
        }
        return markers
    }

    private func color(for runs: Int) -> Color {
        switch runs {
        case 0: return Theme.secondaryButtonFill
        case 1: return softAccent.opacity(0.46)
        case 2: return softAccent.opacity(0.78)
        case 3: return accent.opacity(0.72)
        default: return accent
        }
    }
}

private extension View {
    func insightCard(padding: CGFloat = 20) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.divider, lineWidth: 1)
            )
    }
}

private struct InsightAppIcon: View {
    let bundleID: String
    let name: String
    let fallbackSymbol: String
    var size: CGFloat = 22

    init(app: ComputedStats.AppEntry, size: CGFloat = 22) {
        self.bundleID = app.bundleID
        self.name = app.name
        self.fallbackSymbol = app.icon
        self.size = size
    }

    var body: some View {
        Group {
            if let icon = InsightAppIconResolver.icon(bundleID: bundleID, appName: name) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: size * 0.62, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .frame(width: size, height: size)
                    .background(
                        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                            .fill(Theme.surfaceElevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                            .strokeBorder(Theme.divider, lineWidth: 1)
                    )
            }
        }
        .frame(width: size, height: size)
        .help(name)
    }
}

private enum InsightAppIconResolver {
    static func icon(bundleID: String, appName: String) -> NSImage? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return sizedIcon(for: url)
        }

        for candidate in appNameCandidates(appName) {
            for root in applicationRoots {
                let url = root.appendingPathComponent("\(candidate).app")
                if FileManager.default.fileExists(atPath: url.path),
                   let icon = sizedIcon(for: url) {
                    return icon
                }
            }
        }

        return nil
    }

    private static var applicationRoots: [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]
    }

    private static func appNameCandidates(_ rawName: String) -> [String] {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = name.lowercased()
        var candidates = [name]

        if lower == "code" || lower.contains("visual studio") {
            candidates.append("Visual Studio Code")
        }
        if lower.contains("chrome") {
            candidates.append("Google Chrome")
        }
        if lower.contains("claude") {
            candidates.append("Claude")
        }
        if lower.contains("codex") {
            candidates.append("Codex")
        }
        if lower.contains("chatgpt") || lower.contains("chat gpt") {
            candidates.append("ChatGPT")
        }

        return candidates.reduce(into: [String]()) { result, candidate in
            guard !candidate.isEmpty, !result.contains(candidate) else { return }
            result.append(candidate)
        }
    }

    private static func sizedIcon(for url: URL) -> NSImage? {
        let icon = (NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage)
            ?? NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 64, height: 64)
        return icon
    }
}

// MARK: - Stats computation

/// Pure-function rollup of summaries → display numbers.
///
/// **Defensive computation**: pre-Phase1 summaries don't have `wordCount` /
/// `frontmostBundleID`. We fall back gracefully — wordCount derives from
/// `previewText` tokenization, which is the same source the encoder uses
/// for new entries. Bundle ID has no fallback so older runs simply don't
/// show up in the "where you dictate" card.
struct ComputedStats {
    let totalRuns: Int
    let successRuns: Int
    let failedRuns: Int
    let noSpeechRuns: Int
    let totalWords: Int
    let averageWPM: Int
    let currentStreakDays: Int
    let longestStreakDays: Int

    let topAppName: String?

    let topApps: [AppEntry]
    let topProfiles: [ProfileEntry]
    let heatmapWeeks: [[HeatmapDay]]

    struct AppEntry {
        let bundleID: String
        let name: String
        let count: Int
        let words: Int

        var icon: String {
            let lower = name.lowercased()
            if lower.contains("chrome") || lower.contains("safari") || lower.contains("browser") { return "globe" }
            if lower.contains("mail") || lower.contains("outlook") { return "envelope" }
            if lower.contains("code") || lower.contains("xcode") || lower.contains("cursor") { return "chevron.left.forwardslash.chevron.right" }
            if lower.contains("slack") || lower.contains("discord") || lower.contains("message") { return "message" }
            if lower.contains("notes") || lower.contains("notion") { return "doc.text" }
            return "app"
        }

        func percent(of total: Int) -> Double {
            guard total > 0 else { return 0 }
            return Double(count) / Double(total)
        }
    }

    struct ProfileEntry {
        let profile: String
        let label: String
        let count: Int

        func percent(of total: Int) -> Double {
            guard total > 0 else { return 0 }
            return Double(count) / Double(total)
        }
    }
    struct HeatmapDay { let date: Date; let label: String; let runs: Int }

    static var empty: ComputedStats {
        compute(from: [])
    }

    /// Fallback word count for summaries persisted before `wordCount`
    /// was added. Tokenizes on whitespace — same approach as RunStore.save.
    static func wordCount(of summary: RunSummary) -> Int {
        if let cached = summary.wordCount { return cached }
        return summary.previewText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .count
    }

    static func compute(from summaries: [RunSummary]) -> ComputedStats {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)

        let totalRuns = summaries.count
        let successRuns = summaries.filter { $0.status == .success }.count
        let failedRuns = summaries.filter { $0.status == .failed }.count
        let noSpeechRuns = summaries.filter { $0.status == .noSpeech }.count
        let totalWords = summaries.reduce(0) { $0 + wordCount(of: $1) }

        let perRunWPMs = summaries.compactMap { run -> Double? in
            let wc = wordCount(of: run)
            guard run.durationSeconds > 0, wc > 0 else { return nil }
            return Double(wc) * 60.0 / run.durationSeconds
        }
        let averageWPM = perRunWPMs.isEmpty
            ? 0
            : Int((perRunWPMs.reduce(0, +) / Double(perRunWPMs.count)).rounded())

        let runsByDay = Dictionary(grouping: summaries) { calendar.startOfDay(for: $0.createdAt) }
        let runDays = Set(runsByDay.keys)
        var currentStreak = 0
        var cursor = startOfToday
        while runDays.contains(cursor) {
            currentStreak += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }

        let longestStreak = longestStreakLength(in: runDays, calendar: calendar)
        let heatmapWeeks = makeHeatmapWeeks(from: runsByDay, startOfToday: startOfToday, calendar: calendar)

        let appBuckets = Dictionary(grouping: summaries.filter { $0.frontmostBundleID != nil }) {
            $0.frontmostBundleID!
        }
        let topApps = appBuckets.map { bundleID, runs in
            AppEntry(
                bundleID: bundleID,
                name: runs.first?.frontmostAppName ?? bundleID,
                count: runs.count,
                words: runs.reduce(0) { $0 + wordCount(of: $1) }
            )
        }
        .sorted { $0.count > $1.count }
        .prefix(6)

        let profileBuckets = Dictionary(grouping: summaries.filter { $0.profileUsed != nil }) {
            $0.profileUsed!
        }
        let topProfiles = profileBuckets
            .map { raw, runs in
                let label = ProfileKind(rawValue: raw)?.displayLabel ?? raw
                return ProfileEntry(profile: raw, label: label, count: runs.count)
            }
            .sorted { $0.count > $1.count }
            .prefix(6)

        return ComputedStats(
            totalRuns: totalRuns,
            successRuns: successRuns,
            failedRuns: failedRuns,
            noSpeechRuns: noSpeechRuns,
            totalWords: totalWords,
            averageWPM: averageWPM,
            currentStreakDays: currentStreak,
            longestStreakDays: longestStreak,
            topAppName: topApps.first?.name,
            topApps: Array(topApps),
            topProfiles: Array(topProfiles),
            heatmapWeeks: heatmapWeeks
        )
    }

    private static func longestStreakLength(in days: Set<Date>, calendar: Calendar) -> Int {
        guard !days.isEmpty else { return 0 }
        let sortedDays = days.sorted()
        var longest = 0
        var current = 0
        var previous: Date?

        for day in sortedDays {
            if let previous, calendar.date(byAdding: .day, value: 1, to: previous) == day {
                current += 1
            } else {
                current = 1
            }
            longest = max(longest, current)
            previous = day
        }
        return longest
    }

    private static func makeHeatmapWeeks(
        from runsByDay: [Date: [RunSummary]],
        startOfToday: Date,
        calendar: Calendar
    ) -> [[HeatmapDay]] {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium

        let weekday = calendar.component(.weekday, from: startOfToday) - 1
        let startOfCurrentWeek = calendar.date(byAdding: .day, value: -weekday, to: startOfToday)!
        let firstWeekStart = calendar.date(byAdding: .weekOfYear, value: -13, to: startOfCurrentWeek)!

        return (0..<14).map { weekOffset in
            let weekStart = calendar.date(byAdding: .weekOfYear, value: weekOffset, to: firstWeekStart)!
            return (0..<7).map { dayOffset in
                let date = calendar.date(byAdding: .day, value: dayOffset, to: weekStart)!
                let count = runsByDay[date]?.count ?? 0
                return HeatmapDay(date: date, label: formatter.string(from: date), runs: count)
            }
        }
    }
}

// MARK: - FlowLayout

/// Wrapping horizontal layout — children flow left-to-right and wrap to
/// the next row when they'd overflow the proposal width. Built on the
/// macOS 13 Layout protocol so we don't have to ship a third-party
/// dependency for one card.
fileprivate struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let (size, _) = computeLayout(maxWidth: maxWidth, subviews: subviews)
        return size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let maxWidth = bounds.width
        let (_, placements) = computeLayout(maxWidth: maxWidth, subviews: subviews)
        for (idx, point) in placements.enumerated() {
            subviews[idx].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                proposal: .unspecified
            )
        }
    }

    private func computeLayout(
        maxWidth: CGFloat,
        subviews: Subviews
    ) -> (CGSize, [CGPoint]) {
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widest: CGFloat = 0
        var placements: [CGPoint] = []

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if rowWidth > 0 && rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                widest = max(widest, rowWidth)
                rowWidth = 0
                rowHeight = 0
            }
            let x = rowWidth == 0 ? 0 : rowWidth + spacing
            placements.append(CGPoint(x: x, y: totalHeight))
            rowWidth = x + size.width
            rowHeight = max(rowHeight, size.height)
        }
        widest = max(widest, rowWidth)
        return (CGSize(width: widest, height: totalHeight + rowHeight), placements)
    }
}
