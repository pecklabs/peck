import SwiftUI
import AppKit

/// Menu bar status: how many of my PRs need action (mergeable / conflict to fix)
/// and how many PRs await my review — e.g. "⚠ 2   ✎ 2".
///
/// NSStatusItem doesn't render SF Symbols embedded in a Text run, so we rasterize
/// the SwiftUI content into a template NSImage and show that.
struct MenuBarLabel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Image(nsImage: MenuBarLabel.render(model.tray))
    }

    @MainActor
    static func render(_ t: TrayStatus) -> NSImage {
        let renderer = ImageRenderer(content: TrayGlyphs(tray: t))
        renderer.scale = max(2, NSScreen.main?.backingScaleFactor ?? 2)
        guard let image = renderer.nsImage else {
            return NSImage(systemSymbolName: "checkmark.seal", accessibilityDescription: nil) ?? NSImage()
        }
        // Round up to whole points so the menu bar can't clip a fractional edge.
        image.size = NSSize(width: ceil(image.size.width), height: ceil(image.size.height))
        image.isTemplate = true // adopt the menu bar's light/dark tint
        return image
    }
}

private struct TrayGlyphs: View {
    var tray: TrayStatus

    var body: some View {
        content
            .font(.system(size: 13, weight: .bold).monospacedDigit())
            .foregroundStyle(.black)
            .fixedSize()
            .padding(.leading, 4)
            .padding(.trailing, 8)
    }

    // The Peck mark (template PNG silhouette) loaded from the resource bundle.
    private static let peckMarkImage: NSImage? = Bundle.module
        .url(forResource: "peck-mark", withExtension: "png", subdirectory: "brand")
        .flatMap { NSImage(contentsOf: $0) }

    @ViewBuilder private func peck(_ size: CGFloat) -> some View {
        if let img = Self.peckMarkImage {
            Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "bird.fill")
        }
    }

    @ViewBuilder private var content: some View {
        if tray.state == .disconnected {
            peck(16).opacity(0.35)   // faded = inactive/disconnected
        } else if tray.needAction == 0 && tray.needsReview == 0 {
            peck(16)
        } else {
            HStack(spacing: 7) {
                if tray.needAction > 0 {
                    HStack(spacing: 3) { peck(14); Text("\(tray.needAction)") }
                }
                if tray.needsReview > 0 {
                    HStack(spacing: 3) { Image(systemName: "hourglass"); Text("\(tray.needsReview)") }
                }
            }
        }
    }
}
