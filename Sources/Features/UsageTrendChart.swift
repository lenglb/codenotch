import SwiftUI

extension ProviderSnapshot {
    /// Only vendor quota windows with a known cycle can support an even pace.
    var trendWindows: [LimitWindow] {
        guard CodexProfile.isCodex(providerID: id) || ClaudeProfile.isClaude(providerID: id) else { return [] }
        let available = windows.filter {
            guard let used = $0.usedFraction, used.isFinite, used >= 0,
                  let duration = $0.duration, duration.isFinite, duration > 0, duration <= UsageHistory.retention,
                  let reset = $0.resetsAt, reset.timeIntervalSince1970.isFinite else { return false }
            return true
        }
        if CodexProfile.isCodex(providerID: id) {
            // The main weekly quota may be primary (weekly-only accounts) or
            // secondary. Never substitute an unrelated model quota.
            let weekly = available.filter {
                ["primary", "secondary"].contains($0.id) && abs(($0.duration ?? 0) - 604800) < 1
            }
            return (weekly.first { $0.id == weeklyID } ?? weekly.first).map { [$0] } ?? []
        }
        func rank(_ window: LimitWindow) -> Int {
            if window.id == "weekly_fable" || window.label.lowercased().contains("fable")
                || window.group?.lowercased().contains("fable") == true { return 0 }
            if window.id == "session" || window.duration == 18000 { return 1 }
            if window.id == "weekly_all" { return 2 }
            return 3
        }
        return available.enumerated().sorted {
            let left = rank($0.element), right = rank($1.element)
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }

    var hasUsageTrend: Bool { !trendWindows.isEmpty }

}

/// Every real quota cycle is expanded together. Each plot owns its cursor so
/// inspecting one window never changes the other windows' readings.
struct UsageTrendSection: View {
    let snapshot: ProviderSnapshot
    let samples: [UsageSample]
    let now: Date
    var resetTimeFormat: ResetTimeFormat = .automatic

    var body: some View {
        VStack(alignment: .leading, spacing: NotchLayout.blockSpacing) {
            ForEach(Array(snapshot.trendWindows.enumerated()), id: \.element.id) { index, window in
                if index > 0 {
                    Rectangle().fill(Palette.ringTrack).frame(height: NotchLayout.hairline)
                }
                UsageWindowChart(snapshot: snapshot, window: window, samples: samples,
                                 now: now, resetTimeFormat: resetTimeFormat)
            }
        }
    }
}

private struct UsageWindowChart: View {
    let snapshot: ProviderSnapshot
    let window: LimitWindow
    let samples: [UsageSample]
    let now: Date
    let resetTimeFormat: ResetTimeFormat
    @State private var inspectedDate: Date?
    @Environment(\.codenotchAccentColor) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: Design.px(10)) {
            if let trend = UsageTrend(providerID: snapshot.id, window: window, samples: samples, now: now,
                                      accountFingerprint: snapshot.usageAccountFingerprint) {
                HStack {
                    Text([window.group, window.label].compactMap { $0 }.joined(separator: " · "))
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .help([window.group, window.label].compactMap { $0 }.joined(separator: " · "))
                    Spacer(minLength: Design.px(8))
                    Text(percent(1 - min(window.usedFraction ?? 0, 1)) + " " + L10n.t("remaining"))
                        .monospacedDigit()
                }
                .foregroundStyle(Palette.textPrimary)
                HStack {
                    Text(ResetCopy.text(for: trend.end, now: now, format: resetTimeFormat))
                    Spacer(minLength: 0)
                    Text(L10n.t("15 min steps"))
                }
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

                UsageTrendPlot(trend: trend, inspectedDate: $inspectedDate, now: now)
                    .frame(height: Design.px(225))
                readout(trend: trend)
                allowance(trend: trend)
            }
        }
        .font(Typography.cardBody)
        .frame(height: NotchLayout.usageTrendHeight, alignment: .top)
        .onChange(of: window.resetsAt) { old, new in
            if let old, let new, abs(new.timeIntervalSince(old)) <= UsageHistory.resetTolerance { return }
            inspectedDate = nil
        }
    }

    private func readout(trend: UsageTrend) -> some View {
        let all = trend.observed.flatMap { $0 }
        let date = inspectedDate ?? min(max(now, trend.start), trend.end)
        // A nearby last observation is shown with its real timestamp. Nothing
        // is extrapolated into a future tick or carried across an offline gap.
        let isGap = trend.observationGaps.contains { date > $0.before.measuredAt && date < $0.after.measuredAt }
        let sample = date <= now && !isGap ? all.last {
            $0.measuredAt <= date && date.timeIntervalSince($0.measuredAt) <= UsageHistory.resolution
        } : nil
        let reference = date
        let prediction = date > now ? trend.forecast(now: now)?.remaining(at: date) : nil
        let remaining = sample?.remainingFraction ?? prediction
        let delta = remaining.map { $0 - trend.idealRemaining(at: date) }
        return VStack(alignment: .leading, spacing: Design.px(8)) {
            HStack {
                Text(reference.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                Spacer(minLength: 0)
                Text(L10n.t("Target") + " " + percent(trend.idealRemaining(at: reference)))
            }
            .foregroundStyle(Palette.textSecondary)
            HStack {
                Text(sample.map { L10n.t("Remaining") + " " + percent($0.remainingFraction) }
                     ?? prediction.map { L10n.t("Forecast") + " " + percent($0) }
                     ?? (isGap ? L10n.t("Measurement gap") : date > now ? L10n.t("Future target") : L10n.t("No reading at this time")))
                    .foregroundStyle(Palette.textPrimary)
                Spacer(minLength: 0)
                if let delta {
                    Text(String(format: "%+.1f pp", delta * 100))
                        .foregroundStyle(delta < 0 ? Palette.critical : accent)
                }
            }
            Text(sample.map { L10n.t("Reading") + " " + $0.measuredAt.formatted(.dateTime.hour().minute()) }
                 ?? (isGap ? L10n.t("Dotted connection, no measured values")
                     : prediction != nil ? L10n.t("Estimate at the same workload")
                     : date > now ? L10n.t("Future usage is not yet known") : L10n.t("History starts with observed readings")))
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
        let forecast = trend.forecast(now: now)
        let evenText = String(format: "%.2f%%", even * 100)
        let availableText: String = remainingTime > 0
            ? available.map { String(format: "%.2f%%", $0 * 100) } ?? "—" : "—"
        let paceText = L10n.t("Target") + " " + evenText + " · " + L10n.t("From now") + " " + availableText
        let basisText: String
        let lastsText: String
        let runsOut: Bool
        if let forecast {
            basisText = forecast.basis == .recent
                ? L10n.t("Forecast") + ": " + L10n.t("last") + " " + interval(forecast.basisDuration)
                : L10n.t("Forecast: average since window start")
            runsOut = forecast.exhaustionDate.map { $0 < trend.end } ?? false
            if let exhausted = forecast.exhaustionDate, exhausted <= now {
                lastsText = L10n.t("Exhausted")
            } else if let exhausted = forecast.exhaustionDate, exhausted < trend.end {
                lastsText = "≈ " + interval(exhausted.timeIntervalSince(now))
            } else {
                lastsText = L10n.t("Until reset") + " · " + interval(max(0, remainingTime))
            }
        } else {
            basisText = L10n.t("Forecast needs a fresh reading")
            lastsText = "—"
            runsOut = false
        }
        return VStack(alignment: .leading, spacing: Design.px(8)) {
            HStack {
                Text(L10n.t("Per 15 min"))
                Spacer(minLength: 0)
                Text(paceText)
            }
            HStack {
                Text(L10n.t("Lasts for"))
                Spacer(minLength: 0)
                Text(lastsText).foregroundStyle(runsOut ? Palette.critical : accent)
            }
            Text(basisText)
                .help(L10n.t("Estimate assuming the same workload. Recent readings are preferred; otherwise the average since the window began is used."))
        }
        .foregroundStyle(Palette.textSecondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .monospacedDigit()
    }

    private func interval(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86400 ? [.day, .hour] : seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(60, seconds)) ?? "—"
    }

    private func percent(_ fraction: Double) -> String { String(format: "%.1f%%", fraction * 100) }
}

struct UsageTrendPlot: View {
    let trend: UsageTrend
    @Binding var inspectedDate: Date?
    let now: Date
    @Environment(\.codenotchAccentColor) private var accent
    private var displayRange: ClosedRange<Date> { trend.displayRange }
    private var visibleGrid: [Date] {
        let range = displayRange
        return ([range.lowerBound] + trend.grid.filter { range.contains($0) } + [range.upperBound])
            .sorted()
    }

    private var selected: Date { inspectedDate ?? min(max(now, trend.start), trend.end) }

    var body: some View {
        // Resolve the range once per render, not once for every path vertex.
        let range = displayRange
        VStack(spacing: Design.px(10)) {
            HStack(spacing: Design.px(8)) {
                Text(L10n.t("Budget"))
                    .foregroundStyle(Palette.textPrimary)
                Spacer(minLength: 0)
                Text("− " + L10n.t("Actual")).foregroundStyle(accent)
                Text("┄ " + L10n.t("Target")).foregroundStyle(Palette.textSecondary)
                Text("┄ " + L10n.t("Forecast")).foregroundStyle(accent)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
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
                        path.move(to: point(range.lowerBound, trend.idealRemaining(at: range.lowerBound), size, range))
                        path.addLine(to: point(range.upperBound, trend.idealRemaining(at: range.upperBound), size, range))
                    }.stroke(Palette.textSecondary, style: StrokeStyle(lineWidth: Design.px(3), dash: [Design.px(9), Design.px(7)]))
                    Path { path in
                        for run in trend.observed {
                            guard let first = run.first else { continue }
                            path.move(to: point(first.measuredAt, first.remainingFraction, size, range))
                            for sample in run.dropFirst() {
                                path.addLine(to: point(sample.measuredAt, sample.remainingFraction, size, range))
                            }
                        }
                    }.stroke(accent, style: StrokeStyle(lineWidth: Design.px(4), lineCap: .round, lineJoin: .round))
                    Path { path in
                        for gap in trend.observationGaps {
                            path.move(to: point(gap.before.measuredAt, gap.before.remainingFraction, size, range))
                            path.addLine(to: point(gap.after.measuredAt, gap.after.remainingFraction, size, range))
                        }
                    }
                    .stroke(accent.opacity(0.65), style: StrokeStyle(lineWidth: Design.px(3), lineCap: .round,
                                                                    dash: [Design.px(1), Design.px(9)]))
                    if let forecast = trend.forecast(now: now) {
                        Path { path in
                            let until = min(trend.end, forecast.exhaustionDate ?? trend.end)
                            path.move(to: point(forecast.origin.measuredAt, forecast.origin.remainingFraction, size, range))
                            path.addLine(to: point(until, forecast.remaining(at: until), size, range))
                        }
                        .stroke(accent, style: StrokeStyle(lineWidth: Design.px(3), dash: [Design.px(9), Design.px(7)]))
                    }
                    Path { path in
                        // Single measurements must remain visible on first launch.
                        for run in trend.observed {
                            for sample in run.count == 1 ? run : Array(run.suffix(1)) {
                                let p = point(sample.measuredAt, sample.remainingFraction, size, range)
                                path.addEllipse(in: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4))
                            }
                        }
                    }.fill(accent)
                    Path { path in
                        let x = x(selected, size, range)
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                    }.stroke(Palette.textPrimary.opacity(0.5), lineWidth: Design.px(2))
                    VStack {
                        HStack { Text("100%"); Spacer() }
                        Spacer()
                        HStack {
                            Text("0%")
                            Spacer()
                            if trend.observationGaps.contains(where: { $0.after.measuredAt > range.lowerBound && $0.before.measuredAt < range.upperBound }) {
                                Text("··· " + L10n.t("Measurement gap"))
                            }
                        }
                    }
                    .font(.system(size: Design.fontSize(capPixels: 14)))
                    .foregroundStyle(Palette.textSecondary)
                    .allowsHitTesting(false)
                }
                .clipped()
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
                Text(range.lowerBound.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                Spacer(minLength: 0)
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel(L10n.t("Previous 15 minutes"))
                Button { inspectedDate = nil } label: { Text(L10n.t("Now")) }
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel(L10n.t("Next 15 minutes"))
                Spacer(minLength: 0)
                Text(range.upperBound.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
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
        let target = displayRange.lowerBound.addingTimeInterval(min(max(x / width, 0), 1)
            * displayRange.upperBound.timeIntervalSince(displayRange.lowerBound))
        inspectedDate = visibleGrid.min { abs($0.timeIntervalSince(target)) < abs($1.timeIntervalSince(target)) }
    }

    private func step(_ direction: Int) {
        let dates = trend.grid.filter { displayRange.contains($0) }
        guard let index = dates.indices.min(by: {
            abs(dates[$0].timeIntervalSince(selected)) < abs(dates[$1].timeIntervalSince(selected))
        }) else { return }
        inspectedDate = dates[min(max(index + direction, 0), dates.count - 1)]
    }

    private func x(_ date: Date, _ size: CGSize, _ range: ClosedRange<Date>) -> CGFloat {
        // Do not clamp offscreen observations onto the axis boundary: that
        // would draw false vertical segments in the zoomed chart.
        date.timeIntervalSince(range.lowerBound)
            / range.upperBound.timeIntervalSince(range.lowerBound) * size.width
    }
    private func y(_ remaining: Double, _ size: CGSize) -> CGFloat { (1 - remaining) * size.height }
    private func point(_ date: Date, _ remaining: Double, _ size: CGSize, _ range: ClosedRange<Date>) -> CGPoint {
        CGPoint(x: x(date, size, range), y: y(remaining, size))
    }
}
