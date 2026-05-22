import SwiftUI

/// Dashboard for usage stats. Pure view layer — every number is computed
/// from `RunStore.summaries` on the fly. No background jobs, no caching
/// layer of its own; the index file is the source of truth.
///
/// **Design language**: old VoiceFlow palette with Wispr-inspired dashboard
/// grammar: roomy gutters, tab underline, metric cards, readable charts,
/// and interpretation copy grounded in the user's actual run history.
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
    @State private var selectedTab: InsightTab = .usage

    private enum InsightTab: String, CaseIterable {
        case usage = "Usage"
        case voice = "Voice"
    }

    private enum Tone {
        static let ink = Theme.textPrimary
        static let muted = Theme.textSecondary
        static let faint = Theme.textTertiary
        static let accent = Theme.accent
        static let accentSoft = Color(red: 1.000, green: 0.690, blue: 0.360)
        static let tile = Theme.surfaceElevated
        static let inactiveSquare = Theme.textTertiary.opacity(0.18)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
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
            .padding(.horizontal, 56)
            .padding(.vertical, 44)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 36) {
            Text("Insights")
                .font(.system(size: 25, weight: .semibold))
                .foregroundColor(Tone.ink)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 28) {
                    ForEach(InsightTab.allCases, id: \.self) { tab in
                        Button {
                            withAnimation(.easeOut(duration: 0.14)) {
                                selectedTab = tab
                            }
                        } label: {
                            VStack(spacing: 16) {
                                Text(tab.rawValue)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(selectedTab == tab ? Tone.ink : Tone.muted)
                                Rectangle()
                                    .fill(selectedTab == tab ? Tone.ink : Color.clear)
                                    .frame(width: 82, height: 2)
                            }
                            .fixedSize()
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                Rectangle()
                    .fill(Theme.dividerStrong.opacity(0.6))
                    .frame(height: 1)
                    .offset(y: -1)
            }
        }
    }

    // MARK: - Usage

    private var usageContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            overviewGrid
            interpretationStrip

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    todaySnapshotCard.frame(maxWidth: .infinity)
                    activityRhythmCard.frame(maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 20) {
                    todaySnapshotCard
                    activityRhythmCard
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    desktopUsageCard.frame(maxWidth: .infinity)
                    modeMixCard.frame(maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 20) {
                    desktopUsageCard
                    modeMixCard
                }
            }

            streakCard
        }
    }

    private var overviewGrid: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                overviewMetricCard(
                    title: "Words captured",
                    value: stats.totalWords.formatted(),
                    detail: "\(stats.averageWordsPerRun) words per run avg",
                    icon: "text.quote",
                    tone: Tone.accent
                )
                overviewMetricCard(
                    title: "Dictations",
                    value: "\(stats.totalRuns)",
                    detail: "\(stats.successRuns) successful",
                    icon: "waveform",
                    tone: Theme.accent
                )
                overviewMetricCard(
                    title: "Speech pace",
                    value: stats.averageWPM > 0 ? "\(stats.averageWPM)" : "—",
                    detail: "words per minute",
                    icon: "speedometer",
                    tone: Tone.accentSoft
                )
                overviewMetricCard(
                    title: "LLM spend",
                    value: stats.totalSpendUSD > 0 ? String(format: "$%.3f", stats.totalSpendUSD) : "—",
                    detail: stats.totalSpendUSD > 0 ? "tracked from runs" : "no paid calls tracked",
                    icon: "dollarsign.circle",
                    tone: Theme.warning
                )
            }

            VStack(alignment: .leading, spacing: 16) {
                overviewMetricCard(
                    title: "Words captured",
                    value: stats.totalWords.formatted(),
                    detail: "\(stats.averageWordsPerRun) words per run avg",
                    icon: "text.quote",
                    tone: Tone.accent
                )
                overviewMetricCard(
                    title: "Dictations",
                    value: "\(stats.totalRuns)",
                    detail: "\(stats.successRuns) successful",
                    icon: "waveform",
                    tone: Theme.accent
                )
                overviewMetricCard(
                    title: "Speech pace",
                    value: stats.averageWPM > 0 ? "\(stats.averageWPM)" : "—",
                    detail: "words per minute",
                    icon: "speedometer",
                    tone: Tone.accentSoft
                )
                overviewMetricCard(
                    title: "LLM spend",
                    value: stats.totalSpendUSD > 0 ? String(format: "$%.3f", stats.totalSpendUSD) : "—",
                    detail: stats.totalSpendUSD > 0 ? "tracked from runs" : "no paid calls tracked",
                    icon: "dollarsign.circle",
                    tone: Theme.warning
                )
            }
        }
    }

    private func overviewMetricCard(
        title: String,
        value: String,
        detail: String,
        icon: String,
        tone: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(tone)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(tone.opacity(0.14)))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(Tone.ink)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.35)
                    .foregroundColor(Tone.faint)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(Tone.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 154, alignment: .topLeading)
        .insightCard()
    }

    private var interpretationStrip: some View {
        FlowLayout(spacing: 8) {
            insightPill(icon: "calendar", text: "\(stats.activeDays) active \(stats.activeDays == 1 ? "day" : "days") in your history")
            insightPill(icon: "app.badge", text: stats.topAppName.map { "Most used app: \($0)" } ?? "App data unlocks after context capture")
            insightPill(icon: "slider.horizontal.3", text: stats.topProfileLabel.map { "Most used mode: \($0)" } ?? "Mode mix appears after routed runs")
            insightPill(icon: "flame", text: "Longest streak: \(stats.longestStreakDays) \(stats.longestStreakDays == 1 ? "day" : "days")")
        }
        .insightCard(padding: 14)
    }

    private func insightPill(icon: String, text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Tone.accent)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Tone.ink)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Capsule().fill(Theme.surfaceElevated))
        .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
    }

    private var todaySnapshotCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(Tone.ink)
                Spacer()
                metricLabel("LIVE SNAPSHOT")
            }

            HStack(spacing: 12) {
                compactMetric(label: "Dictations", value: "\(stats.todayRuns)")
                compactMetric(label: "Words", value: stats.todayWords.formatted())
                compactMetric(label: "Avg WPM", value: stats.todayAvgWPM > 0 ? "\(stats.todayAvgWPM)" : "—")
                compactMetric(label: "Top app", value: stats.todayTopApp ?? "—")
            }
        }
        .frame(minHeight: 184, alignment: .top)
        .insightCard(padding: 22)
    }

    private var activityRhythmCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent rhythm")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(Tone.ink)
                Spacer()
                metricLabel("LAST 14 DAYS")
            }

            ActivityBarsView(entries: stats.activitySparkline, accent: Tone.accent, softAccent: Tone.accentSoft)
                .frame(height: 106)
        }
        .frame(minHeight: 184, alignment: .top)
        .insightCard(padding: 22)
    }

    private var wpmCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(stats.averageWPM > 0 ? "\(stats.averageWPM)" : "—")
                .font(.system(size: 29, weight: .semibold))
                .foregroundColor(Tone.ink)
                .monospacedDigit()
            metricLabel("WORDS PER MINUTE")

            Spacer(minLength: 4)

            HalfGaugeView(
                progress: stats.averageWPM > 0 ? min(1, Double(stats.averageWPM) / 120.0) : 0,
                accent: Tone.accent,
                background: Theme.textTertiary.opacity(0.32)
            )
            .frame(height: 112)
            .overlay(alignment: .bottom) {
                VStack(spacing: 2) {
                    Text("Avg")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Tone.faint)
                    Text(stats.averageWPM > 0 ? "\(stats.averageWPM)" : "—")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Tone.ink)
                        .monospacedDigit()
                }
                .offset(y: -6)
            }
        }
        .frame(minHeight: 178, alignment: .top)
        .insightCard()
    }

    private var processedCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(stats.totalRuns)")
                .font(.system(size: 29, weight: .semibold))
                .foregroundColor(Tone.ink)
                .monospacedDigit()
            metricLabel("RUNS THROUGH VOICEFLOW")

            Divider().background(Theme.dividerStrong)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 9) {
                insightFact("\(stats.successRuns) successful dictations", info: true)
                insightFact("\(stats.failedRuns + stats.noSpeechRuns) need attention", info: true)
            }
        }
        .frame(minHeight: 178, alignment: .top)
        .insightCard()
    }

    private var totalWordsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(stats.totalWords.formatted())
                .font(.system(size: 29, weight: .semibold))
                .foregroundColor(Tone.ink)
                .monospacedDigit()
            metricLabel("TOTAL WORDS DICTATED")

            Divider().background(Theme.dividerStrong)
                .padding(.top, 8)

            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Tone.ink)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Desktop")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(Tone.ink)
                    Text("\(stats.totalWords.formatted()) words")
                        .font(.system(size: 14))
                        .foregroundColor(Tone.ink)
                }
                Spacer()
                Button {
                    NotificationCenter.default.post(
                        name: Notification.Name("VoiceFlow.SelectTab"),
                        object: nil,
                        userInfo: ["tab": "runLog"]
                    )
                } label: {
                    Text("Open run log")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Tone.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Theme.surfaceElevated)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Theme.divider, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minHeight: 178, alignment: .top)
        .insightCard()
    }

    private var desktopUsageCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline) {
                Text("App mix")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(Tone.ink)
                Spacer()
                metricLabel("CAPTURED APPS | \(stats.topApps.count)")
            }

            if stats.topApps.isEmpty {
                hintRow("No app data yet — dictate again with Context Capture on.")
                    .padding(.top, 14)
            } else {
                VStack(spacing: 12) {
                    ForEach(stats.topApps, id: \.bundleID) { app in
                        usageBarRow(
                            icon: app.icon,
                            percent: app.percent(of: stats.totalRuns),
                            label: app.name,
                            count: "\(app.count) runs"
                        )
                    }
                }
            }
        }
        .frame(minHeight: 288, alignment: .top)
        .insightCard(padding: 22)
    }

    private var modeMixCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline) {
                Text("Mode mix")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(Tone.ink)
                Spacer()
                metricLabel("TRANSFORM ROUTES")
            }

            if stats.topProfiles.isEmpty {
                hintRow("Mode usage appears after context-aware dictations.")
                    .padding(.top, 14)
            } else {
                VStack(spacing: 12) {
                    ForEach(stats.topProfiles, id: \.profile) { profile in
                        usageBarRow(
                            icon: "slider.horizontal.3",
                            percent: profile.percent(of: stats.totalRuns),
                            label: profile.label,
                            count: "\(profile.count) runs"
                        )
                    }
                }
            }
        }
        .frame(minHeight: 288, alignment: .top)
        .insightCard(padding: 22)
    }

    private var streakCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline) {
                Text("Consistency")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(Tone.ink)
                Spacer()
                metricLabel("CURRENT \(stats.currentStreakDays) \(stats.currentStreakDays == 1 ? "DAY" : "DAYS") | BEST \(stats.longestStreakDays)")
            }

            StreakHeatmapView(weeks: stats.heatmapWeeks, accent: Tone.accent, softAccent: Tone.accentSoft)
        }
        .frame(minHeight: 286, alignment: .top)
        .insightCard(padding: 22)
    }

    // MARK: - Voice

    private var voiceContent: some View {
        VStack(alignment: .leading, spacing: 20) {
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
                    .font(.system(size: 26, weight: .semibold, design: .serif))
                    .foregroundColor(Tone.ink)
                Spacer()
                Text("LOCKED")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.0)
                    .foregroundColor(Tone.faint)
            }

            Text("Dictate \(eligibility.requiredRuns) substantive transcriptions with at least \(eligibility.requiredWordsPerRun) words each. VoiceFlow will then summarize your working style from real usage.")
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
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Tone.accent))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Voice profile")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(Tone.ink)
                    Text("Ready to sync from saved transcriptions.")
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

    private func syncInsightsButton(label: String) -> some View {
        Button {
            Task {
                await indexer.syncNow()
                await classifier.classify(force: true)
            }
        } label: {
            if label.isEmpty {
                Image(systemName: classifier.isClassifying || indexer.isWorking ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Tone.muted)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.surfaceElevated))
                    .overlay(Circle().strokeBorder(Theme.divider, lineWidth: 1))
            } else {
                Label(label, systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Tone.accent))
            }
        }
        .buttonStyle(.plain)
        .disabled(classifier.isClassifying || indexer.isWorking)
        .help("Sync Memory and re-analyze latest transcripts")
    }

    private var appBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Peak apps")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(Tone.ink)
            if stats.topApps.isEmpty {
                hintRow("No app data yet.")
            } else {
                VStack(spacing: 10) {
                    ForEach(stats.topApps, id: \.bundleID) { app in
                        compactBreakdownRow(label: app.name, count: app.count, total: stats.totalRuns)
                    }
                }
            }
        }
        .insightCard()
    }

    private var profileBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Used modes")
                .font(.system(size: 20, weight: .semibold))
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

    private func metricLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .tracking(1.55)
            .foregroundColor(Tone.faint)
    }

    private func compactMetric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(value)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(Tone.ink)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(1.0)
                .foregroundColor(Tone.faint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.divider, lineWidth: 1)
        )
    }

    private func insightFact(_ text: String, info: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Tone.ink)
            Spacer()
            if info {
                Image(systemName: "info.circle")
                    .font(.system(size: 13))
                    .foregroundColor(Tone.faint)
            }
        }
    }

    private func usageBarRow(icon: String, percent: Double, label: String, count: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Tone.ink)
                .frame(width: 22)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Theme.textTertiary.opacity(0.16))
                        .frame(height: 28)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(percent > 0.45 ? Tone.accent : Tone.accentSoft)
                        .frame(width: max(46, geo.size.width * percent), height: 28)
                    Text("\(Int((percent * 100).rounded()))%")
                        .font(.system(size: 13, weight: .bold).monospacedDigit())
                        .foregroundColor(.white)
                        .padding(.leading, 12)
                }
            }
            .frame(height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.0)
                    .foregroundColor(Tone.ink)
                    .lineLimit(1)
                Text(count)
                    .font(.system(size: 11))
                    .foregroundColor(Tone.muted)
            }
            .frame(width: 126, alignment: .leading)
        }
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
                        .fill(Theme.textTertiary.opacity(0.16))
                        .frame(height: 8)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Tone.accent)
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

    private func progressBar(_ progress: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.textTertiary.opacity(0.18))
                    .frame(height: 8)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Tone.accent)
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
        ComputedStats.compute(from: runStore.summaries)
    }
}

// MARK: - Drawing

private struct HalfGaugeView: View {
    let progress: Double
    let accent: Color
    let background: Color

    var body: some View {
        ZStack {
            GaugeArc(progress: 1)
                .stroke(background, style: StrokeStyle(lineWidth: 15, lineCap: .round))
            GaugeArc(progress: progress)
                .stroke(accent, style: StrokeStyle(lineWidth: 15, lineCap: .round))
        }
        .padding(.horizontal, 12)
        .padding(.top, 16)
    }
}

private struct GaugeArc: Shape {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(rect.width / 2, rect.height) - 8
        let center = CGPoint(x: rect.midX, y: rect.maxY - 8)
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(180),
            endAngle: .degrees(180 + 180 * progress),
            clockwise: false
        )
        return path
    }
}

private struct ActivityBarsView: View {
    let entries: [ComputedStats.DayEntry]
    let accent: Color
    let softAccent: Color

    private var maxRuns: Int {
        max(1, entries.map(\.runs).max() ?? 1)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 7) {
            ForEach(entries, id: \.day) { entry in
                VStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(entry.runs == 0 ? Theme.textTertiary.opacity(0.16) : barColor(for: entry.runs))
                        .frame(height: max(8, CGFloat(entry.runs) / CGFloat(maxRuns) * 72))
                        .frame(maxHeight: 72, alignment: .bottom)
                        .help("\(entry.runs) dictation\(entry.runs == 1 ? "" : "s") on \(entry.day)")
                    Text(entry.shortDay)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func barColor(for runs: Int) -> Color {
        runs >= maxRuns ? accent : softAccent.opacity(0.78)
    }
}

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
        case 0: return Theme.textTertiary.opacity(0.14)
        case 1: return softAccent.opacity(0.42)
        case 2: return softAccent.opacity(0.72)
        case 3: return accent.opacity(0.76)
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
            .shadow(color: Theme.Shadow.card.color, radius: Theme.Shadow.card.radius, x: 0, y: Theme.Shadow.card.y)
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
    let totalSpendUSD: Double
    let averageWPM: Int
    let averageWordsPerRun: Int
    let currentStreakDays: Int
    let longestStreakDays: Int
    let activeDays: Int

    let todayRuns: Int
    let todayWords: Int
    let todayAvgWPM: Int
    let todayTopApp: String?
    let topAppName: String?
    let topProfileLabel: String?

    let topApps: [AppEntry]
    let topProfiles: [ProfileEntry]
    let activitySparkline: [DayEntry]
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
    struct DayEntry { let day: String; let shortDay: String; let runs: Int }
    struct HeatmapDay { let date: Date; let label: String; let runs: Int }

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
        let totalSpend = summaries.reduce(0.0) { $0 + ($1.llmCostUSD ?? 0) }
        let averageWordsPerRun = totalRuns > 0 ? Int((Double(totalWords) / Double(totalRuns)).rounded()) : 0

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
        let activeDays = runDays.count
        var currentStreak = 0
        var cursor = startOfToday
        while runDays.contains(cursor) {
            currentStreak += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }

        let todayRuns = summaries.filter { calendar.isDateInToday($0.createdAt) }
        let todayWords = todayRuns.reduce(0) { $0 + wordCount(of: $1) }
        let todayWPMs = todayRuns.compactMap { run -> Double? in
            let wc = wordCount(of: run)
            guard run.durationSeconds > 0, wc > 0 else { return nil }
            return Double(wc) * 60.0 / run.durationSeconds
        }
        let todayAvgWPM = todayWPMs.isEmpty
            ? 0
            : Int((todayWPMs.reduce(0, +) / Double(todayWPMs.count)).rounded())
        let todayTopApp = Dictionary(grouping: todayRuns) { $0.frontmostAppName ?? "" }
            .filter { !$0.key.isEmpty }
            .mapValues { $0.count }
            .max { $0.value < $1.value }?
            .key

        let longestStreak = longestStreakLength(in: runDays, calendar: calendar)
        let activitySparkline = makeActivitySparkline(from: summaries, startOfToday: startOfToday, calendar: calendar)
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
            totalSpendUSD: totalSpend,
            averageWPM: averageWPM,
            averageWordsPerRun: averageWordsPerRun,
            currentStreakDays: currentStreak,
            longestStreakDays: longestStreak,
            activeDays: activeDays,
            todayRuns: todayRuns.count,
            todayWords: todayWords,
            todayAvgWPM: todayAvgWPM,
            todayTopApp: todayTopApp,
            topAppName: topApps.first?.name,
            topProfileLabel: topProfiles.first?.label,
            topApps: Array(topApps),
            topProfiles: Array(topProfiles),
            activitySparkline: activitySparkline,
            heatmapWeeks: heatmapWeeks
        )
    }

    private static func makeActivitySparkline(
        from summaries: [RunSummary],
        startOfToday: Date,
        calendar: Calendar
    ) -> [DayEntry] {
        let fullFormatter = DateFormatter()
        fullFormatter.dateStyle = .medium
        let shortFormatter = DateFormatter()
        shortFormatter.dateFormat = "EE"

        return (0..<14).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: startOfToday)!
            let next = calendar.date(byAdding: .day, value: 1, to: day)!
            let count = summaries.filter { $0.createdAt >= day && $0.createdAt < next }.count
            return DayEntry(
                day: fullFormatter.string(from: day),
                shortDay: shortFormatter.string(from: day),
                runs: count
            )
        }
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
