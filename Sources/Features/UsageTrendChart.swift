import SwiftUI

extension ProviderSnapshot {
    /// Only vendor quota windows with a known cycle can support an even pace.
    var trendWindows: [LimitWindow] {
        guard CodexProfile.isCodex(providerID: id) || ClaudeProfile.isClaude(providerID: id) else { return [] }
        return windows.filter {
            guard let used = $0.usedFraction, used.isFinite, used >= 0,
                  let duration = $0.duration, duration.isFinite, duration > 0, duration <= UsageHistory.retention,
                  let reset = $0.resetsAt, reset.timeIntervalSince1970.isFinite else { return false }
            return true
        }
    }

    var hasUsageTrend: Bool { !trendWindows.isEmpty }

    /// The ring may lead with DailyPace, a synthetic weekly-budget ratio with
    /// no independent cycle. Saved selections must use the same eligibility
    /// rules as navigation so they cannot reopen an empty chart.
    func selectedTrendWindow(id: String) -> LimitWindow? {
        let available = trendWindows
        return available.first { $0.id == id }
            ?? available.first { $0.id == headlineID }
            ?? available.first
    }
}

/// Shares the card's typography, tracks and accent. Selecting a different
/// window never changes the card's height or moves it out from under the mouse.
struct UsageTrendSection: View {
    let snapshot: ProviderSnapshot
    let samples: [UsageSample]
    let now: Date
    let resetTimeFormat: ResetTimeFormat
    @AppStorage private var selectedID: String
    @State private var inspectedDate: Date?
    @Environment(\.codenotchAccentColor) private var accent

    init(snapshot: ProviderSnapshot, samples: [UsageSample], now: Date,
         resetTimeFormat: ResetTimeFormat = .automatic) {
        self.snapshot = snapshot
        self.samples = samples
        self.now = now
        self.resetTimeFormat = resetTimeFormat
        _selectedID = AppStorage(wrappedValue: "", "usageTrend.window.\(snapshot.id)")
    }

    private var window: LimitWindow? {
        snapshot.selectedTrendWindow(id: selectedID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.px(14)) {
            if let window,
               let trend = UsageTrend(providerID: snapshot.id, window: window, samples: samples, now: now,
                                      accountFingerprint: snapshot.usageAccountFingerprint) {
                selector(window)
                HStack {
                    Text(ResetCopy.text(for: trend.end, now: now, format: resetTimeFormat))
                    Spacer(minLength: 0)
                    Text(L10n.t("15 min steps"))
                }
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

                GeometryReader { proxy in
                    Capsule().fill(Palette.barTrack)
                    Capsule().fill(accent)
                        .frame(width: proxy.size.width * min(max(window.usedFraction ?? 0, 0), 1))
                }
                .frame(height: NotchLayout.barHeight)
                Text(window.summary)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)

                UsageTrendPlot(trend: trend, inspectedDate: $inspectedDate, now: now)
                    .frame(height: Design.px(255))

                readout(trend: trend)
                allowance(trend: trend)
            }
        }
        .font(Typography.cardBody)
        .frame(height: NotchLayout.usageTrendHeight, alignment: .top)
        .onChange(of: window?.id) { _, _ in inspectedDate = nil }
        .onChange(of: window?.resetsAt) { _, _ in inspectedDate = nil }
    }

    private func selector(_ window: LimitWindow) -> some View {
        // Inline arrows avoid a pop-up extending beyond the notch's hover
        // region. Every chartable provider window remains one click away.
        HStack(spacing: Design.px(12)) {
            Button { select(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel(L10n.t("Previous usage window"))
            Text([window.group, window.label].compactMap { $0 }.joined(separator: " · "))
                .fontWeight(.semibold)
                .foregroundStyle(Palette.textPrimary)
                .frame(maxWidth: .infinity)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .help([window.group, window.label].compactMap { $0 }.joined(separator: " · "))
            Button { select(1) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel(L10n.t("Next usage window"))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.textSecondary)
        .frame(height: Design.px(36))
    }

    private func select(_ offset: Int) {
        let windows = snapshot.trendWindows
        guard !windows.isEmpty else { return }
        let index = windows.firstIndex { $0.id == window?.id } ?? 0
        selectedID = windows[(index + offset + windows.count) % windows.count].id
        inspectedDate = nil
    }

    private func readout(trend: UsageTrend) -> some View {
        let all = trend.observed.flatMap { $0 }
        let date = inspectedDate ?? min(max(now, trend.start), trend.end)
        // A nearby last observation is shown with its real timestamp. Nothing
        // is extrapolated into a future tick or carried across an offline gap.
        let sample = date <= now ? all.last {
            $0.measuredAt <= date && date.timeIntervalSince($0.measuredAt) <= UsageHistory.resolution
        } : nil
        let reference = date
        let delta = sample.map { $0.remainingFraction - trend.idealRemaining(at: date) }
        return VStack(alignment: .leading, spacing: Design.px(8)) {
            HStack {
                Text(reference.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                Spacer(minLength: 0)
                Text(L10n.t("Target") + " " + percent(trend.idealRemaining(at: reference)))
            }
            .foregroundStyle(Palette.textSecondary)
            HStack {
                Text(sample.map { L10n.t("Remaining") + " " + percent($0.remainingFraction) }
                     ?? (date > now ? L10n.t("Future target") : L10n.t("No reading at this time")))
                    .foregroundStyle(Palette.textPrimary)
                Spacer(minLength: 0)
                if let delta {
                    Text(String(format: "%+.1f pp", delta * 100))
                        .foregroundStyle(delta < 0 ? Palette.critical : accent)
                }
            }
            Text(sample.map { L10n.t("Reading") + " " + $0.measuredAt.formatted(.dateTime.hour().minute()) }
                 ?? (date > now ? L10n.t("Future usage is not yet known") : L10n.t("History starts with observed readings")))
                .foregroundStyle(Palette.textSecondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .monospacedDigit()
        .frame(height: Design.px(102), alignment: .top)
    }

    private func allowance(trend: UsageTrend) -> some View {
        let remainingTime = trend.end.timeIntervalSince(now)
        let latest = trend.observed.last?.last
        let current = latest.flatMap { now.timeIntervalSince($0.measuredAt) <= UsageHistory.resolution ? $0 : nil }
        let even = UsageHistory.resolution / trend.cycle.duration
        let available = current.map { $0.remainingFraction * min(UsageHistory.resolution / max(remainingTime, 1), 1) }
        return VStack(alignment: .leading, spacing: Design.px(8)) {
            HStack {
                Text(L10n.t("Even pace"))
                Spacer(minLength: 0)
                Text(String(format: "%.2f%% / 15 min", even * 100))
            }
            HStack {
                Text(remainingTime > 0 ? L10n.t("From now") : L10n.t("Waiting for reset"))
                Spacer(minLength: 0)
                Text(remainingTime > 0 ? available.map { String(format: "%.2f%% / 15 min", $0 * 100) } ?? "—" : "—")
            }
        }
        .foregroundStyle(Palette.textSecondary)
        .lineLimit(1)
        .monospacedDigit()
    }

    private func percent(_ fraction: Double) -> String { String(format: "%.1f%%", fraction * 100) }
}

struct UsageTrendPlot: View {
    let trend: UsageTrend
    @Binding var inspectedDate: Date?
    let now: Date
    @Environment(\.codenotchAccentColor) private var accent

    private var selected: Date { inspectedDate ?? min(max(now, trend.start), trend.end) }

    var body: some View {
        VStack(spacing: Design.px(10)) {
            HStack(spacing: Design.px(16)) {
                Text(L10n.t("Remaining budget"))
                    .foregroundStyle(Palette.textPrimary)
                Spacer(minLength: 0)
                Text("− " + L10n.t("Actual")).foregroundStyle(accent)
                Text("┄ " + L10n.t("Target")).foregroundStyle(Palette.textSecondary)
            }
            GeometryReader { proxy in
                let size = proxy.size
                ZStack {
                    Path { path in
                        for fraction in [0.0, 0.5, 1.0] {
                            let y = y(fraction, size)
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: size.width, y: y))
                        }
                    }.stroke(Palette.ringTrack, lineWidth: Design.px(1))
                    Path { path in
                        path.move(to: point(trend.start, 1, size))
                        path.addLine(to: point(trend.end, 0, size))
                    }.stroke(Palette.textSecondary, style: StrokeStyle(lineWidth: Design.px(3), dash: [Design.px(9), Design.px(7)]))
                    Path { path in
                        for run in trend.observed {
                            guard let first = run.first else { continue }
                            path.move(to: point(first.measuredAt, first.remainingFraction, size))
                            for sample in run.dropFirst() {
                                path.addLine(to: point(sample.measuredAt, sample.remainingFraction, size))
                            }
                        }
                    }.stroke(accent, style: StrokeStyle(lineWidth: Design.px(4), lineCap: .round, lineJoin: .round))
                    Path { path in
                        // Single measurements must remain visible on first launch.
                        for run in trend.observed {
                            for sample in run.count == 1 ? run : Array(run.suffix(1)) {
                                let p = point(sample.measuredAt, sample.remainingFraction, size)
                                path.addEllipse(in: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4))
                            }
                        }
                    }.fill(accent)
                    Path { path in
                        let x = x(selected, size)
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                    }.stroke(Palette.textPrimary.opacity(0.5), lineWidth: Design.px(2))
                    VStack {
                        HStack { Text("100%"); Spacer() }
                        Spacer()
                        HStack { Text("0%"); Spacer() }
                    }
                    .font(.system(size: Design.fontSize(capPixels: 14)))
                    .foregroundStyle(Palette.textSecondary)
                    .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): inspect(x: location.x, width: size.width)
                    case .ended: break // Retain the tick while using the step buttons.
                    }
                }
                .gesture(DragGesture(minimumDistance: 0).onChanged { inspect(x: $0.location.x, width: size.width) })
                .accessibilityLabel(L10n.t("Remaining budget, 15 minute steps"))
                .accessibilityValue(selected.formatted(.dateTime.weekday().hour().minute()))
                .accessibilityAdjustableAction { step($0 == .increment ? 1 : -1) }
            }
            HStack {
                Text(trend.start.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                Spacer(minLength: 0)
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel(L10n.t("Previous 15 minutes"))
                Button { inspectedDate = nil } label: { Text(L10n.t("Now")) }
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel(L10n.t("Next 15 minutes"))
                Spacer(minLength: 0)
                Text(trend.end.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.textSecondary)
            .font(.system(size: Design.fontSize(capPixels: 14)))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }

    private func inspect(x: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        let target = trend.start.addingTimeInterval(min(max(x / width, 0), 1) * trend.cycle.duration)
        inspectedDate = trend.grid.min { abs($0.timeIntervalSince(target)) < abs($1.timeIntervalSince(target)) }
    }

    private func step(_ direction: Int) {
        guard let index = trend.grid.indices.min(by: {
            abs(trend.grid[$0].timeIntervalSince(selected)) < abs(trend.grid[$1].timeIntervalSince(selected))
        }) else { return }
        inspectedDate = trend.grid[min(max(index + direction, 0), trend.grid.count - 1)]
    }

    private func x(_ date: Date, _ size: CGSize) -> CGFloat {
        min(max(date.timeIntervalSince(trend.start) / trend.cycle.duration, 0), 1) * size.width
    }
    private func y(_ remaining: Double, _ size: CGSize) -> CGFloat { (1 - remaining) * size.height }
    private func point(_ date: Date, _ remaining: Double, _ size: CGSize) -> CGPoint {
        CGPoint(x: x(date, size), y: y(remaining, size))
    }
}
