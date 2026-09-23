import AppKit
import SwiftUI

private struct DockProviderDetail: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var preferences: Preferences
    let providerID: String
    let maximumHeight: CGFloat

    var body: some View {
        if let snapshot = model.snapshots.first(where: { $0.id == providerID }) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                TooltipCard(snapshot: snapshot, activity: model.activity(for: providerID),
                            historySamples: model.historySamples, now: context.date,
                            direction: .up, trendHeightLimit: maximumHeight,
                            resetTimeFormat: preferences.resetTimeFormat,
                            deepSeekPricingEnabled: preferences.deepSeekPricingEnabled,
                            deepSeekPricingSchedule: preferences.deepSeekPricingSchedule,
                            onFocusSession: model.onFocusSession)
                    .environment(\.codenotchAccentColor, preferences.accentColor.color)
                    .environment(\.notchSurfaceStyle, preferences.notchSurfaceStyle)
            }
        } else {
            Text("Für diesen Anbieter liegen keine Messwerte vor.")
                .padding(24).frame(width: NotchLayout.cardWidth)
        }
    }
}

/// A normal closeable detail panel; the chart implementation and its real
/// history stay exactly the same as the edge widget's hover card.
@MainActor
final class ProviderDetailWindowController: NSObject, NSWindowDelegate {
    private var panels: [String: NSPanel] = [:]
    private let model: NotchViewModel
    private let preferences: Preferences

    init(model: NotchViewModel, preferences: Preferences) {
        self.model = model
        self.preferences = preferences
    }

    func show(_ providerID: String) {
        guard let snapshot = model.snapshots.first(where: { $0.id == providerID }) else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let maximumHeight = min(NotchLayout.trendCardMaximumHeight, max(200, (screen?.visibleFrame.height ?? 800) - 100))
        let panel = panels[providerID] ?? NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: NotchLayout.cardWidth, height: maximumHeight),
            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "\(snapshot.displayName) · Nutzung"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        let host = NSHostingView(rootView: DockProviderDetail(model: model, preferences: preferences,
                                                            providerID: providerID, maximumHeight: maximumHeight))
        panel.contentView = host
        panel.setContentSize(CGSize(width: NotchLayout.cardWidth,
                                    height: min(maximumHeight + NotchLayout.tailLength, host.fittingSize.height)))
        if let screen {
            panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - panel.frame.width / 2,
                                         y: screen.visibleFrame.midY - panel.frame.height / 2))
        } else { panel.center() }
        panels[providerID] = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func closeAll() {
        for panel in panels.values { panel.close() }
        panels.removeAll()
    }
}
