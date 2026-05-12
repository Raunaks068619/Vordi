import SwiftUI

/// Dashboard for usage stats. Pure view layer — every number is computed
/// from `RunStore.summaries` on the fly. No background jobs, no caching
/// layer of its own; the index file is the source of truth.
///
/// **Design language**: matches Settings exactly — ScrollView with
/// `padding(Theme.Space.xl)` (=24), VStack `spacing: 20`, every section
/// in a `themedCard()`. Header uses serif font + subtitle, consistent
/// with `settingsHeader`.
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if runStore.summaries.isEmpty {
                    emptyStateCard
                } else {
                    userTypeCard
                    heroStatsCard
                    todayCard
                    activityCard
                    appBreakdownCard
                    profileBreakdownCard
                }
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            // Auto-trigger classification when eligible + no cache.
            // Idempotent — the service guards against re-running while
            // a classification is in flight.
            let eligibility = classifier.eligibility()
            if eligibility.isUnlocked && classifier.classification == nil {
                await classifier.classify()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Insights")
                .font(.system(size: 26, weight: .semibold, design: .serif))
                .foregroundColor(Theme.textPrimary)
            Text("How you dictate, where you dictate, and what you spend.")
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
        }
    }

    // MARK: - User type (AI-classified)

    /// Adaptive card with three visual states:
    ///   - Locked   → progress bar + "X / 20 transcripts" copy
    ///   - Loading  → spinner + "Analyzing your patterns…"
    ///   - Unlocked → role badge, headline, signal chips, refresh button
    @ViewBuilder
    private var userTypeCard: some View {
        let eligibility = classifier.eligibility()
        if !eligibility.isUnlocked {
            lockedUserTypeCard(eligibility: eligibility)
        } else if let classification = classifier.classification {
            unlockedUserTypeCard(classification)
        } else {
            loadingUserTypeCard()
        }
    }

    private func lockedUserTypeCard(eligibility: UserTypeEligibility) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                Text("Your User Type")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text("Locked")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundColor(Theme.textSecondary)
                    .background(
                        Capsule().fill(Theme.surfaceElevated)
                    )
                    .overlay(
                        Capsule().strokeBorder(Theme.divider, lineWidth: 1)
                    )
            }

            Text("Dictate \(eligibility.requiredRuns) substantive transcriptions (≥\(eligibility.requiredWordsPerRun) words each) and VoiceFlow will analyze your patterns to identify how you work.")
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(eligibility.qualifyingRuns) / \(eligibility.requiredRuns) qualifying")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    Text("\(Int(eligibility.progress * 100))%")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundColor(Theme.textSecondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Theme.textTertiary.opacity(0.18))
                            .frame(height: 8)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Theme.accent)
                            .frame(
                                width: max(2, geo.size.width * eligibility.progress),
                                height: 8
                            )
                    }
                }
                .frame(height: 8)
            }
        }
        .themedCard()
    }

    private func loadingUserTypeCard() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.accent)
                Text("Your User Type")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                ProgressView().controlSize(.small)
            }
            Text("Analyzing your transcription patterns…")
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
            if let err = classifier.lastError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.warning)
            }
        }
        .themedCard()
    }

    private func unlockedUserTypeCard(_ c: UserTypeClassification) -> some View {
        let (tr, tg, tb) = c.role.tintRGB
        let tint = Color(red: tr, green: tg, blue: tb)
        return VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: c.role.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(tint))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(c.role.displayLabel)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                        Text("AI-inferred")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .foregroundColor(tint)
                            .background(Capsule().fill(tint.opacity(0.14)))
                    }
                    Text(c.headline)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer()
                Button {
                    Task { await classifier.classify(force: true) }
                } label: {
                    Image(systemName: classifier.isClassifying
                          ? "arrow.triangle.2.circlepath"
                          : "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Theme.surfaceElevated))
                        .overlay(Circle().strokeBorder(Theme.divider, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(classifier.isClassifying)
                .help("Re-analyze with latest transcripts")
            }

            // Signals
            if !c.signals.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("WHY")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.6)
                        .foregroundColor(Theme.textTertiary)
                    FlowLayout(spacing: 6) {
                        ForEach(c.signals, id: \.self) { signal in
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(tint)
                                    .frame(width: 4, height: 4)
                                Text(signal)
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textPrimary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(Theme.surfaceElevated)
                            )
                            .overlay(
                                Capsule().strokeBorder(Theme.divider, lineWidth: 1)
                            )
                        }
                    }
                }
            }

            // Footer — analysis context
            HStack(spacing: 12) {
                miniMetadata(icon: "doc.text", label: "\(c.runsAnalyzed) transcripts")
                miniMetadata(icon: "gauge.medium",
                             label: "\(Int(c.confidence * 100))% confidence")
                miniMetadata(icon: "clock",
                             label: relativeTime(c.computedAt))
                Spacer()
            }
        }
        .themedCard()
    }

    private func miniMetadata(icon: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
            Text(label)
                .font(.system(size: 10))
        }
        .foregroundColor(Theme.textTertiary)
    }

    private func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Empty state

    private var emptyStateCard: some View {
        VStack(alignment: .center, spacing: 12) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(Theme.textSecondary)
            Text("No dictations yet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text("Hold Fn anywhere to start. Stats appear here as soon as you do.")
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .themedCard()
    }

    // MARK: - Hero stats

    private var heroStatsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Lifetime")
            HStack(spacing: Theme.Space.md) {
                statTile(
                    icon: "text.bubble",
                    label: "Runs",
                    value: "\(stats.totalRuns)"
                )
                statTile(
                    icon: "abc",
                    label: "Words",
                    value: stats.totalWords.formatted()
                )
                statTile(
                    icon: "flame",
                    label: "Day streak",
                    value: stats.currentStreakDays > 0 ? "\(stats.currentStreakDays) 🔥" : "—"
                )
                statTile(
                    icon: "dollarsign.circle",
                    label: "LLM spend",
                    value: stats.totalSpendUSD > 0
                        ? String(format: "$%.3f", stats.totalSpendUSD)
                        : "—"
                )
            }
        }
        .themedCard()
    }

    // MARK: - Today

    private var todayCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Today")
            HStack(spacing: Theme.Space.md) {
                miniStat(label: "Dictations", value: "\(stats.todayRuns)")
                miniStat(label: "Words", value: stats.todayWords.formatted())
                miniStat(label: "Avg WPM", value: stats.todayAvgWPM > 0 ? "\(stats.todayAvgWPM)" : "—")
                miniStat(label: "Top app", value: stats.todayTopApp ?? "—")
            }
        }
        .themedCard()
    }

    // MARK: - Activity sparkline

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Last 14 days")
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(stats.activitySparkline, id: \.day) { entry in
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(entry.runs > 0 ? Theme.accent : Theme.textTertiary.opacity(0.2))
                            .frame(height: max(6, CGFloat(min(entry.runs, 12)) * 6))
                            .frame(maxHeight: 80)
                            .help("\(entry.runs) runs · \(entry.day)")
                        Text(entry.shortDay)
                            .font(.system(size: 10))
                            .foregroundColor(Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 100)
        }
        .themedCard()
    }

    // MARK: - App breakdown

    private var appBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Where you dictate")
            if stats.topApps.isEmpty {
                hintRow("No app data yet — dictate again with Context Capture on (Dev Mode → Context Capture).")
            } else {
                VStack(spacing: 10) {
                    ForEach(stats.topApps, id: \.bundleID) { entry in
                        breakdownRow(label: entry.name, count: entry.count, total: stats.totalRuns)
                    }
                }
            }
        }
        .themedCard()
    }

    // MARK: - Profile breakdown

    private var profileBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Which features you use")
            if stats.topProfiles.isEmpty {
                hintRow("Profile usage will appear after your first context-aware dictation.")
            } else {
                VStack(spacing: 10) {
                    ForEach(stats.topProfiles, id: \.profile) { entry in
                        breakdownRow(label: entry.label, count: entry.count, total: stats.totalRuns)
                    }
                }
            }
        }
        .themedCard()
    }

    // MARK: - Building blocks

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(Theme.textPrimary)
    }

    private func statTile(icon: String, label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }
            Text(value)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                .fill(Theme.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1)
        )
    }

    private func miniStat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func breakdownRow(label: String, count: Int, total: Int) -> some View {
        let pct = total > 0 ? Double(count) / Double(total) : 0
        return HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Theme.textPrimary)
                .frame(width: 180, alignment: .leading)
                .lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.textTertiary.opacity(0.18))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.accent)
                        .frame(width: max(2, geo.size.width * pct), height: 6)
                }
            }
            .frame(height: 6)
            Text("\(count)")
                .font(.system(size: 12).monospacedDigit())
                .foregroundColor(Theme.textSecondary)
                .frame(width: 32, alignment: .trailing)
        }
    }

    private func hintRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Stats

    private var stats: ComputedStats {
        ComputedStats.compute(from: runStore.summaries)
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
    let totalWords: Int
    let totalSpendUSD: Double
    let currentStreakDays: Int

    let todayRuns: Int
    let todayWords: Int
    let todayAvgWPM: Int
    let todayTopApp: String?

    let activitySparkline: [DayEntry]
    let topApps: [AppEntry]
    let topProfiles: [ProfileEntry]

    struct DayEntry { let day: String; let shortDay: String; let runs: Int }
    struct AppEntry { let bundleID: String; let name: String; let count: Int }
    struct ProfileEntry { let profile: String; let label: String; let count: Int }

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
        let totalWords = summaries.reduce(0) { $0 + wordCount(of: $1) }
        let totalSpend = summaries.reduce(0.0) { $0 + ($1.llmCostUSD ?? 0) }

        // Streak: consecutive days going back from today with ≥1 run.
        let runDays: Set<Date> = Set(summaries.map { calendar.startOfDay(for: $0.createdAt) })
        var streak = 0
        var cursor = startOfToday
        while runDays.contains(cursor) {
            streak += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }

        // Today's numbers — WPM is per-run mean (not global wallclock).
        let todayRuns = summaries.filter { calendar.isDateInToday($0.createdAt) }
        let todayWordsTotal = todayRuns.reduce(0) { $0 + wordCount(of: $1) }
        let todayAvgWPM: Int = {
            guard !todayRuns.isEmpty else { return 0 }
            // Mean of per-run WPM, NOT total words / total time. Per-run
            // is more representative of a user's actual speech rate; the
            // total form gets dragged down by short pauses between runs.
            let perRunWPMs = todayRuns.compactMap { run -> Double? in
                let wc = wordCount(of: run)
                guard run.durationSeconds > 0, wc > 0 else { return nil }
                return Double(wc) * 60.0 / run.durationSeconds
            }
            guard !perRunWPMs.isEmpty else { return 0 }
            let mean = perRunWPMs.reduce(0, +) / Double(perRunWPMs.count)
            return Int(mean.rounded())
        }()

        let todayTopApp: String? = {
            let appCounts = Dictionary(grouping: todayRuns) { $0.frontmostAppName ?? "" }
                .filter { !$0.key.isEmpty }
                .mapValues { $0.count }
            return appCounts.max { $0.value < $1.value }?.key
        }()

        // 14-day sparkline.
        var sparkline: [DayEntry] = []
        let dayFormatterFull = DateFormatter()
        dayFormatterFull.dateFormat = "yyyy-MM-dd"
        let dayFormatterShort = DateFormatter()
        dayFormatterShort.dateFormat = "EE"
        for offset in (0..<14).reversed() {
            let date = calendar.date(byAdding: .day, value: -offset, to: startOfToday)!
            let next = calendar.date(byAdding: .day, value: 1, to: date)!
            let count = summaries.filter { $0.createdAt >= date && $0.createdAt < next }.count
            sparkline.append(DayEntry(
                day: dayFormatterFull.string(from: date),
                shortDay: dayFormatterShort.string(from: date),
                runs: count
            ))
        }

        // Top apps — bundle ID grouping but we display the name.
        // Filter out runs with no captured app (pre-Phase1 history).
        let appBuckets = Dictionary(grouping: summaries.filter { $0.frontmostBundleID != nil }) {
            $0.frontmostBundleID!
        }
        let topApps = appBuckets.map { (bundleID, runs) in
            AppEntry(
                bundleID: bundleID,
                name: runs.first?.frontmostAppName ?? bundleID,
                count: runs.count
            )
        }
        .sorted { $0.count > $1.count }
        .prefix(5)

        // Top profiles.
        let profileBuckets = Dictionary(grouping: summaries.filter { $0.profileUsed != nil }) {
            $0.profileUsed!
        }
        let topProfiles = profileBuckets
            .map { (raw, runs) in
                let label = ProfileKind(rawValue: raw)?.displayLabel ?? raw
                return ProfileEntry(profile: raw, label: label, count: runs.count)
            }
            .sorted { $0.count > $1.count }
            .prefix(5)

        return ComputedStats(
            totalRuns: totalRuns,
            totalWords: totalWords,
            totalSpendUSD: totalSpend,
            currentStreakDays: streak,
            todayRuns: todayRuns.count,
            todayWords: todayWordsTotal,
            todayAvgWPM: todayAvgWPM,
            todayTopApp: todayTopApp,
            activitySparkline: sparkline,
            topApps: Array(topApps),
            topProfiles: Array(topProfiles)
        )
    }
}

// MARK: - FlowLayout

/// Wrapping horizontal layout — children flow left-to-right and wrap to
/// the next row when they'd overflow the proposal width. Built on the
/// macOS 13 Layout protocol so we don't have to ship a third-party
/// dependency for one card.
///
/// SwiftUI doesn't ship a FlowLayout. Pre-Layout-protocol workarounds
/// fight intrinsic sizing; this ~60-line Layout impl integrates cleanly.
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

    /// Returns the bounding size and per-subview top-left positions.
    /// Single pass — O(n) in subview count.
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
            // If this subview would overflow the current row, wrap.
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
        let finalHeight = totalHeight + rowHeight
        return (CGSize(width: widest, height: finalHeight), placements)
    }
}
