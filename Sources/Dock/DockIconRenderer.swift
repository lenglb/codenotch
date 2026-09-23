import AppKit
import SwiftUI

/// Static reuse of the original provider cell: no animation timer or provider
/// request lives in a Dock process. Only a changed reading needs a new image.
@MainActor
enum DockIconRenderer {
    static func image(snapshot: ProviderSnapshot, weeklyRing: WeeklyRing,
                      accent: AccentColorChoice, appearance: NSAppearance? = nil) -> NSImage? {
        let appearance = appearance ?? NSApp.effectiveAppearance
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let resolved = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let content = ProviderCell(snapshot: snapshot, weeklyRing: weeklyRing)
            .environment(\.codenotchAccentColor, accent.color)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
            .padding(Design.px(12))
            // A Dock image has no live backdrop. Bake a predictable surface
            // and resolve foreground, tracks and background in one appearance.
            .background(Color(hex: dark ? 0x242426 : 0xF2F2F4),
                        in: RoundedRectangle(cornerRadius: Design.px(34)))
            .environment(\.colorScheme, dark ? .dark : .light)
        let view = NSHostingView(rootView: content)
        view.appearance = resolved
        var rendered: NSImage?
        resolved.performAsCurrentDrawingAppearance {
            let natural = view.fittingSize
            guard natural.width > 0, natural.height > 0 else { return }
            view.frame = CGRect(origin: .zero, size: natural)
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let tile = NSImage(size: CGSize(width: 128, height: 128))
            tile.lockFocus()
            let factor = min(116 / natural.width, 116 / natural.height)
            let size = CGSize(width: natural.width * factor, height: natural.height * factor)
            bitmap.draw(in: CGRect(x: (128 - size.width) / 2, y: (128 - size.height) / 2,
                                   width: size.width, height: size.height))
            tile.unlockFocus()
            rendered = tile
        }
        return rendered
    }

    static func png(snapshot: ProviderSnapshot, weeklyRing: WeeklyRing,
                    accent: AccentColorChoice, appearance: NSAppearance? = nil) -> Data? {
        guard let image = image(snapshot: snapshot, weeklyRing: weeklyRing, accent: accent, appearance: appearance),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
