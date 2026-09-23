import AppKit

/// One small, prebuilt app per supported provider. The main process remains
/// the only owner of credentials, polling and history. Helpers only see PNGs.
@MainActor
final class DockProviderCoordinator {
    static let providers = ["codex": "Codenotch Codex", "claude": "Codenotch Claude",
                            "gemini": "Codenotch Antigravity"]
    static let actions: Set<String> = ["ready", "details", "refresh", "settings", "quit"]
    static func providerID(from url: URL) -> String? {
        guard url.scheme == "codenotch", url.host == "provider", url.pathComponents.count == 2,
              url.query == nil, url.fragment == nil, url.user == nil, url.password == nil,
              url.port == nil, let id = url.pathComponents.last, providers[id] != nil else { return nil }
        return id
    }

    private(set) var session = UUID().uuidString
    private var isEnabled = false
    private var terminationObserver: NSObjectProtocol?
    private var appearanceObservation: NSKeyValueObservation?
    private var latestSnapshots: [ProviderSnapshot] = []
    private var latestWeeklyRing: WeeklyRing = .off
    private var latestAccent: AccentColorChoice = .system
    private var restartCounts: [String: Int] = [:]
    private let directory: URL
    private var observer: NSObjectProtocol?
    private var applications: [String: NSRunningApplication] = [:]
    private var launching: Set<String> = []
    private var desired: Set<String> = []
    private var images: [String: Data] = [:]
    private var readings: [String: ProviderSnapshot] = [:]
    private var style: String = ""
    private var generation = 0
    var onCommand: ((String, String) -> Void)?
    var onFailure: ((String) -> Void)?

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Codenotch/DockImages", isDirectory: true)
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.isEnabled else { return }
                self.update(self.latestSnapshots, enabled: true,
                            weeklyRing: self.latestWeeklyRing, accent: self.latestAccent)
            }
        }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let id = self.applications.first(where: { $0.value.processIdentifier == app.processIdentifier })?.key,
                      self.desired.contains(id) else { return }
                self.applications[id] = nil
                let attempt = (self.restartCounts[id] ?? 0) + 1
                self.restartCounts[id] = attempt
                guard attempt <= 3 else {
                    self.onFailure?("Die Dock-Komponente wurde wiederholt beendet: \(Self.providers[id] ?? id)")
                    return
                }
                let generation = self.generation
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(attempt)) { [weak self] in
                    guard let self, self.generation == generation, self.desired.contains(id),
                          self.applications[id]?.isTerminated != false, !self.launching.contains(id) else { return }
                    self.launch(id)
                }
            }
        }
    }

    private func beginSession() {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        session = UUID().uuidString
        restartCounts.removeAll()
        isEnabled = true
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.vinz.codenotch.dock.\(session).command"),
            object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, note.name.rawValue == "com.vinz.codenotch.dock.\(self.session).command",
                      let id = note.object as? String, self.desired.contains(id),
                      let action = note.userInfo?["action"] as? String,
                      Self.actions.contains(action) else { return }
                if action == "ready" { self.notify(id) }
                else { self.onCommand?(id, action) }
            }
        }
    }

    func update(_ snapshots: [ProviderSnapshot], enabled: Bool,
                weeklyRing: WeeklyRing, accent: AccentColorChoice) {
        guard enabled else { stop(); return }
        if !isEnabled { beginSession() }
        latestSnapshots = snapshots
        latestWeeklyRing = weeklyRing
        latestAccent = accent
        let appearance = NSApp.effectiveAppearance
        let theme = appearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? ""
        let currentStyle = "\(weeklyRing.rawValue):\(accent.rawValue):\(theme)"
        if currentStyle != style { readings.removeAll(); style = currentStyle }
        let supported = snapshots.filter { Self.providers[$0.id] != nil }
        desired = Set(supported.map(\.id))
        for id in Array(applications.keys) where !desired.contains(id) {
            applications.removeValue(forKey: id)?.terminate()
            readings[id] = nil
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            for snapshot in supported {
                let id = snapshot.id
                if readings[id] != snapshot {
                    guard let data = DockIconRenderer.png(snapshot: snapshot, weeklyRing: weeklyRing, accent: accent, appearance: appearance) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    if images[id] != data {
                        try data.write(to: directory.appendingPathComponent("\(id).png"), options: .atomic)
                        images[id] = data
                        notify(id)
                    }
                    readings[id] = snapshot
                }
                if applications[id]?.isTerminated != false && !launching.contains(id) { launch(id) }
            }
        } catch { onFailure?(error.localizedDescription) }
    }

    private func notify(_ id: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.vinz.codenotch.dock.\(session).update"),
            object: id, userInfo: nil, deliverImmediately: true)
    }

    private func launch(_ id: String) {
        guard let name = Self.providers[id] else { return }
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name).app")
        guard FileManager.default.fileExists(atPath: url.path) else {
            onFailure?("Dock-Komponente fehlt: \(name)"); return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.createsNewApplicationInstance = true
        config.addsToRecentItems = false
        config.arguments = ["--codenotch-session", session, "--codenotch-parent", String(ProcessInfo.processInfo.processIdentifier),
                            "--codenotch-state", directory.path]
        let requestedGeneration = generation
        launching.insert(id)
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] app, error in
            DispatchQueue.main.async {
                guard let self else { app?.terminate(); return }
                guard self.generation == requestedGeneration else { app?.terminate(); return }
                self.launching.remove(id)
                guard self.desired.contains(id) else { app?.terminate(); return }
                if let error { self.onFailure?(error.localizedDescription); return }
                if let app { self.applications[id] = app; self.notify(id) }
            }
        }
    }

    func stop() {
        isEnabled = false
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        generation += 1
        desired.removeAll()
        launching.removeAll()
        for app in applications.values { app.terminate() }
        applications.removeAll()
    }

    deinit {
        if let terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver) }
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }
}
