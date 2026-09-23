import AppKit
import SwiftUI

/// macOS only exposes the Dock's item under the mouse through Accessibility.
/// Permission is requested by this explicit button, never at background launch.
struct DockHoverPermissionView: View {
    @State private var trusted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if trusted {
                Label("Chart-Vorschau beim Darüberfahren aktiv", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Für die Vorschau beim Darüberfahren bitte Codenotch unter Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen erlauben. Ein Klick auf das Dock-Symbol öffnet die Charts auch ohne diese Freigabe.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Bedienungshilfen für Vorschau öffnen …") {
                    DockHoverMonitor.requestPermission()
                }
            }
        }
        .task {
            // Only while this settings row is on screen; no background timer.
            while !Task.isCancelled {
                trusted = DockHoverMonitor.isTrusted
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
}
