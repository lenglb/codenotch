import AppKit
import ApplicationServices

/// Watches the real Dock tiles belonging to Codenotch's provider helpers.
///
/// AppKit does not expose pointer-entered events for an `NSDockTile`.  This
/// monitor therefore asks the public Accessibility API which element of the
/// Dock is under the pointer.  A tile is accepted only when its `AXURL` is the
/// exact URL of one of the embedded helper apps; an accessible title alone is
/// deliberately never enough.
@MainActor
final class DockHoverMonitor {
    /// Called after a Dock hit test. `iconFrame` uses AppKit's bottom-left
    /// screen coordinate system, so it can be used directly to position a
    /// window. Movement away from a provider reports `(nil, nil)`.
    var onHover: ((String?, CGRect?) -> Void)?

    /// Called for every observed movement, including movements over a preview
    /// window away from the Dock. This lets the owner include its own window in
    /// the hover region without doing another global event monitor.
    var onPointerMove: ((CGPoint) -> Void)?

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's Accessibility permission prompt. Call only in response to
    /// an explicit user action; `start()` never prompts.
    @discardableResult
    static func requestPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(settings)
        }
        return trusted
    }

    private struct Hit: @unchecked Sendable {
        let providerID: String?
        let frame: CGRect?
    }

    private let accessibilityQueue = DispatchQueue(label: "com.vinz.codenotch.dock-hover",
                                                    qos: .userInteractive)
    private let targets: [String: String]
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isRunning = false
    private var generation = 0
    private var pointerRevision = 0
    private var queryInFlight = false
    private var scheduledQuery: DispatchWorkItem?
    private var settleWork: DispatchWorkItem?
    private var nextQueryTime: TimeInterval = 0
    private var lastTrustCheck: TimeInterval = 0
    private var cachedTrust = false
    private var pendingQuery: (point: CGPoint, dockPID: pid_t, targets: [String: String],
                               mainHeight: CGFloat, revision: Int)?

    init() {
        targets = DockProviderCoordinator.providers.mapValues { appName in
            Self.normalizedFilePath(Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers/\(appName).app"))!
        }
    }

    func start() {
        lastTrustCheck = 0
        if isRunning {
            // Re-sample after the app becomes active again. This is how the
            // settings UI picks up a permission granted in System Settings
            // even when the pointer has not moved since.
            mouseMoved(to: NSEvent.mouseLocation)
            return
        }
        isRunning = true
        generation += 1
        lastTrustCheck = 0

        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            let dragging = event.type != .mouseMoved
            DispatchQueue.main.async { [weak self] in
                self?.mouseMoved(to: NSEvent.mouseLocation, dragging: dragging)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated {
                self?.mouseMoved(to: NSEvent.mouseLocation, dragging: event.type != .mouseMoved)
            }
            return event
        }

        // A first sample also covers starting while the pointer is stationary
        // over a tile. Further stationary waiting belongs to the UI's reveal
        // delay and requires no polling here.
        mouseMoved(to: NSEvent.mouseLocation)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation += 1
        pendingQuery = nil
        scheduledQuery?.cancel()
        scheduledQuery = nil
        settleWork?.cancel(); settleWork = nil
        queryInFlight = false
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        onHover?(nil, nil)
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    private func mouseMoved(to point: CGPoint, dragging: Bool = false, settled: Bool = false) {
        guard isRunning else { return }
        pointerRevision += 1
        onPointerMove?(point)
        settleWork?.cancel(); settleWork = nil

        guard !dragging, Self.isNearScreenEdge(point) else {
            // Do report ordinary movement. The owner may currently be waiting
            // to hide a preview after the pointer left both icon and window.
            onHover?(nil, nil)
            pendingQuery = nil
            return
        }
        guard trustedNow(),
              let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
                .first(where: { !$0.isTerminated })?.processIdentifier,
              let mainHeight = NSScreen.screens.first?.frame.height else {
            onHover?(nil, nil)
            return
        }

        pendingQuery = (point, dockPID, targets, mainHeight, pointerRevision)
        submitNextQueryIfNeeded()
        if !settled {
            // One final hit test after auto-hide/magnification settles. A
            // stationary cursor otherwise produces no further mouse events.
            let expectedGeneration = generation
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isRunning, self.generation == expectedGeneration else { return }
                self.mouseMoved(to: NSEvent.mouseLocation, settled: true)
            }
            settleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    private func trustedNow() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if lastTrustCheck == 0 || now - lastTrustCheck >= 1 {
            cachedTrust = Self.isTrusted
            lastTrustCheck = now
        }
        return cachedTrust
    }

    /// Keeps at most one AX request running. During it, arbitrary mouseMoved
    /// traffic collapses into the latest point, avoiding a queue backlog.
    private func submitNextQueryIfNeeded() {
        guard !queryInFlight, scheduledQuery == nil, pendingQuery != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let delay = max(0, nextQueryTime - now)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.beginPendingQuery() }
        }
        scheduledQuery = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func beginPendingQuery() {
        scheduledQuery = nil
        guard isRunning, !queryInFlight, let request = pendingQuery else { return }
        pendingQuery = nil
        queryInFlight = true
        nextQueryTime = ProcessInfo.processInfo.systemUptime + 0.1
        let requestedGeneration = generation
        let axPoint = CGPoint(x: request.point.x, y: request.mainHeight - request.point.y)

        accessibilityQueue.async { [weak self] in
            let hit = Self.hitTest(point: axPoint, dockPID: request.dockPID,
                                   targets: request.targets, mainHeight: request.mainHeight)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.isRunning, self.generation == requestedGeneration else { return }
                self.queryInFlight = false
                // An AX reply can arrive after the pointer has already left
                // that tile. Never resurrect a preview from such a stale hit.
                if self.pointerRevision == request.revision {
                    self.onHover?(hit.providerID, hit.frame)
                }
                self.submitNextQueryIfNeeded()
            }
        }
    }

    nonisolated private static func hitTest(point: CGPoint, dockPID: pid_t,
                                            targets: [String: String], mainHeight: CGFloat) -> Hit {
        let dock = AXUIElementCreateApplication(dockPID)
        // Prevent a wedged Dock or accessibility service from tying up our
        // serial worker. A later mouse movement can retry cleanly.
        AXUIElementSetMessagingTimeout(dock, 0.15)

        var rawHit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(dock, Float(point.x), Float(point.y), &rawHit) == .success,
              let rawHit else { return Hit(providerID: nil, frame: nil) }

        var element: AXUIElement? = rawHit
        let deadline = ProcessInfo.processInfo.systemUptime + 0.3
        for _ in 0..<10 {
            guard ProcessInfo.processInfo.systemUptime < deadline, let current = element else { break }
            AXUIElementSetMessagingTimeout(current, 0.15)
            var ownerPID: pid_t = 0
            guard AXUIElementGetPid(current, &ownerPID) == .success, ownerPID == dockPID else { break }

            if let url = url(of: current),
               let provider = providerID(for: url, allowedPaths: targets),
               let frame = frame(of: current) {
                return Hit(providerID: provider,
                           frame: CGRect(x: frame.minX, y: mainHeight - frame.maxY,
                                         width: frame.width, height: frame.height))
            }

            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            element = unsafeBitCast(parent, to: AXUIElement.self)
        }
        return Hit(providerID: nil, frame: nil)
    }

    nonisolated private static func url(of element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success,
              let value else { return nil }
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    nonisolated private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString,
                                            &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString,
                                            &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        let positionAX = unsafeBitCast(positionValue, to: AXValue.self)
        let sizeAX = unsafeBitCast(sizeValue, to: AXValue.self)
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetType(positionAX) == .cgPoint,
              AXValueGetValue(positionAX, .cgPoint, &position),
              AXValueGetType(sizeAX) == .cgSize,
              AXValueGetValue(sizeAX, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }

    nonisolated static func providerID(for url: URL, allowedPaths: [String: String]) -> String? {
        guard let path = normalizedFilePath(url) else { return nil }
        return allowedPaths.first(where: { $0.value == path })?.key
    }

    nonisolated private static func normalizedFilePath(_ url: URL) -> String? {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.query == nil, url.fragment == nil else { return nil }
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func isNearScreenEdge(_ point: CGPoint) -> Bool {
        // Covers bottom, side and vertically arranged Docks, including a
        // magnified tile and the reveal strip of an auto-hidden Dock.
        let margin: CGFloat = 180
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else {
            return false
        }
        let frame = screen.frame
        return point.x - frame.minX <= margin || frame.maxX - point.x <= margin
            || point.y - frame.minY <= margin || frame.maxY - point.y <= margin
    }
}
