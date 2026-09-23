import AppKit
import Darwin

private enum DockProvider: String, CaseIterable {
    case codex
    case claude
    case antigravity = "gemini"
}

private enum HelperAction: String {
    case ready
    case details
    case refresh
    case settings
    case quit
}

private struct LaunchConfiguration {
    let provider: DockProvider
    let session: String
    let parentPID: pid_t
    let imageURL: URL

    static func current() -> LaunchConfiguration? {
        guard let providerValue = Bundle.main.object(forInfoDictionaryKey: "CodenotchProviderID") as? String,
              let provider = DockProvider(rawValue: providerValue),
              let session = value(after: "--codenotch-session"),
              UUID(uuidString: session) != nil,
              let parentValue = value(after: "--codenotch-parent"),
              let parentPID = Int32(parentValue), parentPID > 1,
              let statePath = value(after: "--codenotch-state"),
              statePath.hasPrefix("/")
        else { return nil }

        let directory = URL(fileURLWithPath: statePath, isDirectory: true).standardizedFileURL
        return LaunchConfiguration(
            provider: provider,
            session: session,
            parentPID: parentPID,
            imageURL: directory.appendingPathComponent(provider.rawValue, isDirectory: false)
                .appendingPathExtension("png")
        )
    }

    private static func value(after option: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: option),
              arguments.indices.contains(index + 1)
        else { return nil }
        let value = arguments[index + 1]
        return value.isEmpty ? nil : value
    }
}

@MainActor
private final class DockHelperDelegate: NSObject, NSApplicationDelegate {
    private let provider: DockProvider?
    private var configuration: LaunchConfiguration?
    private var updateObserver: NSObjectProtocol?
    private var parentExitSource: DispatchSourceProcess?
    private let imageView = NSImageView()
    private var dockMenu: NSMenu?

    override init() {
        if let value = Bundle.main.object(forInfoDictionaryKey: "CodenotchProviderID") as? String {
            provider = DockProvider(rawValue: value)
        } else {
            provider = nil
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let provider else {
            NSApp.terminate(nil)
            return
        }

        guard let configuration = LaunchConfiguration.current() else {
            openMainApplication(for: provider)
            return
        }
        guard processExists(configuration.parentPID) else {
            NSApp.terminate(nil)
            return
        }

        self.configuration = configuration
        NSApp.setActivationPolicy(.regular)
        installDockView()
        installMenu()
        observeUpdates()
        observeParentExit(pid: configuration.parentPID)
        reloadImage()
        post(.ready)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        if configuration != nil {
            post(.details)
        } else if let provider {
            openMainApplication(for: provider)
        }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        dockMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let updateObserver {
            DistributedNotificationCenter.default().removeObserver(updateObserver)
        }
        parentExitSource?.cancel()
    }

    private func installDockView() {
        let tile = NSApp.dockTile
        imageView.frame = NSRect(origin: .zero, size: tile.size)
        imageView.autoresizingMask = [.width, .height]
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleProportionallyUpOrDown
        tile.contentView = imageView
        tile.display()
    }

    private func installMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        appItem.submenu = actionMenu()
        NSApp.mainMenu = mainMenu
        dockMenu = actionMenu()
    }

    private func actionMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Charts öffnen", action: #selector(openDetails)))
        menu.addItem(item("Aktualisieren", action: #selector(refresh)))
        menu.addItem(.separator())
        menu.addItem(item("Einstellungen", action: #selector(openSettings)))
        menu.addItem(item("Codenotch beenden", action: #selector(quitCodenotch)))
        return menu
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func observeUpdates() {
        guard let configuration else { return }
        let name = Notification.Name("com.vinz.codenotch.dock.\(configuration.session).update")
        updateObserver = DistributedNotificationCenter.default().addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  notification.object as? String == configuration.provider.rawValue
            else { return }
            MainActor.assumeIsolated { self.reloadImage() }
        }
    }

    private func observeParentExit(pid: pid_t) {
        let source = DispatchSource.makeProcessSource(
            identifier: pid,
            eventMask: .exit,
            queue: .main
        )
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        parentExitSource = source
    }

    private func reloadImage() {
        guard let imageURL = configuration?.imageURL,
              let data = try? Data(contentsOf: imageURL),
              let image = NSImage(data: data)
        else { return }
        imageView.image = image
        NSApp.dockTile.display()
    }

    private func post(_ action: HelperAction) {
        guard let configuration else { return }
        let name = Notification.Name("com.vinz.codenotch.dock.\(configuration.session).command")
        DistributedNotificationCenter.default().postNotificationName(
            name,
            object: configuration.provider.rawValue,
            userInfo: ["action": action.rawValue],
            deliverImmediately: true
        )
    }

    @objc private func openDetails() { post(.details) }
    @objc private func refresh() { post(.refresh) }
    @objc private func openSettings() { post(.settings) }
    @objc private func quitCodenotch() { post(.quit) }

    private func processExists(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private func openMainApplication(for provider: DockProvider) {
        guard let parentURL = enclosingMainApplication(),
              let destination = URL(string: "codenotch://provider/\(provider.rawValue)")
        else {
            NSApp.terminate(nil)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(
            [destination],
            withApplicationAt: parentURL,
            configuration: configuration
        ) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private func enclosingMainApplication() -> URL? {
        var candidate = Bundle.main.bundleURL.deletingLastPathComponent()
        while candidate.path != "/" {
            if candidate.pathExtension == "app",
               Bundle(url: candidate)?.bundleIdentifier == "com.vinz.codenotch" {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = DockHelperDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
