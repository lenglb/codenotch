import AppKit
import SwiftUI

/// Static reuse of the original provider cell: no animation timer or provider
/// request lives in a Dock process. Only a changed reading needs a new image.
@MainActor
enum DockIconRenderer {
    static func image(snapshot: ProviderSnapshot, weeklyRing: WeeklyRing,
                      accent: AccentColorChoice) -> NSImage? {
        let content = ProviderCell(snapshot: snapshot, weeklyRing: weeklyRing)
            .environment(\.codenotchAccentColor, accent.color)
            .environment(\.colorScheme, .light)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
            .padding(Design.px(12))
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Design.px(34)))
        let view = NSHostingView(rootView: content)
        let natural = view.fittingSize
        guard natural.width > 0, natural.height > 0 else { return nil }
        view.frame = CGRect(origin: .zero, size: natural)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let tile = NSImage(size: CGSize(width: 128, height: 128))
        tile.lockFocus()
        let factor = min(116 / natural.width, 116 / natural.height)
        let size = CGSize(width: natural.width * factor, height: natural.height * factor)
        bitmap.draw(in: CGRect(x: (128 - size.width) / 2, y: (128 - size.height) / 2,
                               width: size.width, height: size.height))
        tile.unlockFocus()
        return tile
    }

    static func png(snapshot: ProviderSnapshot, weeklyRing: WeeklyRing,
                    accent: AccentColorChoice) -> Data? {
        guard let image = image(snapshot: snapshot, weeklyRing: weeklyRing, accent: accent),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
