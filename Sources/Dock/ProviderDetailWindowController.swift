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

/// A hover panel can be read without taking focus. Clicking it (or its Dock
/// icon) promotes the same window, preserving the chart selection and position.
private final class DockDetailPanel: NSPanel {
    var pinned = false
    var onPin: (() -> Void)?
    override var canBecomeKey: Bool { pinned }
    override var canBecomeMain: Bool { pinned }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !pinned { onPin?() }
        super.sendEvent(event)
    }
}

@MainActor
final class ProviderDetailWindowController: NSObject, NSWindowDelegate {
    private var panels: [String: DockDetailPanel] = [:]
    private let model: NotchViewModel
    private let preferences: Preferences
    private let pointerLocation: () -> CGPoint
    private let revealDelay: TimeInterval
    private let dismissDelay: TimeInterval
    private var revealWork: DispatchWorkItem?
    private var dismissWork: DispatchWorkItem?
    private var hoveredProvider: String?
    private var hoveredFrame: CGRect?
    private var suppressedProvider: String?
    private(set) var previewProviderID: String?

    init(model: NotchViewModel, preferences: Preferences,
         revealDelay: TimeInterval = 0.25, dismissDelay: TimeInterval = 0.45,
         pointerLocation: @escaping () -> CGPoint = { NSEvent.mouseLocation }) {
        self.model = model
        self.preferences = preferences
        self.revealDelay = revealDelay
        self.dismissDelay = dismissDelay
        self.pointerLocation = pointerLocation
    }

    func panel(for providerID: String) -> NSPanel? { panels[providerID] }
    func isPinned(_ providerID: String) -> Bool { panels[providerID]?.pinned == true }

    /// Called on mouse movement, including movement outside the Dock. The short
    /// dismissal grace lets the pointer cross from an icon into its preview.
    func hover(_ providerID: String?, iconFrame: CGRect?) {
        if providerID != hoveredProvider { suppressedProvider = nil }
        hoveredProvider = providerID
        hoveredFrame = iconFrame
        guard let id = providerID, let frame = iconFrame,
              DockProviderCoordinator.providers[id] != nil,
              suppressedProvider != id else {
            revealWork?.cancel(); revealWork = nil; pendingProvider = nil
            pointerMoved()
            return
        }
        dismissWork?.cancel(); dismissWork = nil
        if isPinned(id) {
            revealWork?.cancel(); revealWork = nil; pendingProvider = nil
            dismissPreview()
            return
        }
        if previewProviderID == id { return }
        // Repeated mouse movement over one icon must not postpone revelation.
        if revealWork != nil, pendingProvider == id { return }
        revealWork?.cancel()
        pendingProvider = id
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hoveredProvider == id, self.suppressedProvider != id else { return }
            self.revealWork = nil
            self.pendingProvider = nil
            self.dismissPreview()
            guard let panel = self.makePanel(id, near: self.hoveredFrame ?? frame) else { return }
            self.previewProviderID = id
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.title += " · Vorschau"
            // Never activate the application or make the temporary panel key.
            panel.orderFrontRegardless()
        }
        revealWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + revealDelay, execute: work)
    }
    private var pendingProvider: String?

    func pointerMoved() {
        guard let id = previewProviderID, let panel = panels[id] else { return }
        let pointer = pointerLocation()
        if panel.frame.contains(pointer) || (hoveredProvider == id && hoveredFrame?.contains(pointer) == true) {
            dismissWork?.cancel(); dismissWork = nil
            return
        }
        guard dismissWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.dismissWork = nil
            guard let id = self.previewProviderID, let panel = self.panels[id] else { return }
            let pointer = self.pointerLocation()
            guard !panel.frame.contains(pointer),
                  !(self.hoveredProvider == id && self.hoveredFrame?.contains(pointer) == true) else { return }
            self.dismissPreview()
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissDelay, execute: work)
    }

    /// A Dock click pins an existing preview, or opens a fixed detail window.
    func show(_ providerID: String) {
        revealWork?.cancel(); revealWork = nil; pendingProvider = nil
        dismissWork?.cancel(); dismissWork = nil
        if previewProviderID != providerID { dismissPreview() }
        guard let panel = panels[providerID] ?? makePanel(providerID, near: nil) else { return }
        previewProviderID = nil
        panel.pinned = true
        panel.level = .normal
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        if let snapshot = model.snapshots.first(where: { $0.id == providerID }) {
            panel.title = "\(snapshot.displayName) · Nutzung"
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    private func makePanel(_ providerID: String, near icon: CGRect?) -> DockDetailPanel? {
        guard let snapshot = model.snapshots.first(where: { $0.id == providerID }) else { return nil }
        let point = icon.map { CGPoint(x: $0.midX, y: $0.midY) } ?? pointerLocation()
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        var availableHeight = (screen?.visibleFrame.height ?? 800) - 100
        if let icon, let screen {
            let bottom = abs(icon.midY - screen.frame.minY)
            let side = min(abs(icon.midX - screen.frame.minX), abs(screen.frame.maxX - icon.midX))
            if bottom <= side {
                // Keep even a magnified Dock tile uncovered on a small screen.
                availableHeight = min(availableHeight, screen.visibleFrame.maxY - icon.maxY - 60)
            }
        }
        let maximumHeight = min(NotchLayout.trendCardMaximumHeight, max(160, availableHeight))
        let panel = DockDetailPanel(
            contentRect: CGRect(x: 0, y: 0, width: NotchLayout.cardWidth, height: maximumHeight),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "\(snapshot.displayName) · Nutzung"
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.onPin = { [weak self] in self?.show(providerID) }
        let host = NSHostingView(rootView: DockProviderDetail(model: model, preferences: preferences,
                                                            providerID: providerID, maximumHeight: maximumHeight))
        panel.contentView = host
        panel.setContentSize(CGSize(width: NotchLayout.cardWidth,
                                    height: min(maximumHeight + NotchLayout.tailLength, host.fittingSize.height)))
        if let screen {
            if let icon {
                panel.setFrameOrigin(Self.previewOrigin(size: panel.frame.size, icon: icon,
                                                       screen: screen.frame, visible: screen.visibleFrame))
            } else {
                panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - panel.frame.width / 2,
                                             y: screen.visibleFrame.midY - panel.frame.height / 2))
            }
        } else { panel.center() }
        panels[providerID] = panel
        return panel
    }

    static func previewOrigin(size: CGSize, icon: CGRect, screen: CGRect, visible: CGRect) -> CGPoint {
        let left = abs(icon.midX - screen.minX)
        let right = abs(screen.maxX - icon.midX)
        let bottom = abs(icon.midY - screen.minY)
        let gap: CGFloat = 8
        var point: CGPoint
        if left < bottom && left < right {
            point = CGPoint(x: icon.maxX + gap, y: icon.midY - size.height / 2)
        } else if right < bottom {
            point = CGPoint(x: icon.minX - size.width - gap, y: icon.midY - size.height / 2)
        } else {
            point = CGPoint(x: icon.midX - size.width / 2, y: icon.maxY + gap)
        }
        point.x = max(visible.minX, min(point.x, visible.maxX - size.width))
        point.y = max(visible.minY, min(point.y, visible.maxY - size.height))
        return point
    }

    func dismissPreview() {
        dismissWork?.cancel(); dismissWork = nil
        guard let id = previewProviderID else { return }
        previewProviderID = nil
        panels.removeValue(forKey: id)?.close()
    }

    func stopHover() {
        revealWork?.cancel(); revealWork = nil; pendingProvider = nil
        hoveredProvider = nil; hoveredFrame = nil; suppressedProvider = nil
        dismissPreview()
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? DockDetailPanel,
              let id = panels.first(where: { $0.value === panel })?.key else { return }
        if previewProviderID == id { previewProviderID = nil }
        suppressedProvider = id
        panels.removeValue(forKey: id)
    }

    func closeAll() {
        stopHover()
        let windows = Array(panels.values)
        panels.removeAll()
        windows.forEach { $0.close() }
    }
}
