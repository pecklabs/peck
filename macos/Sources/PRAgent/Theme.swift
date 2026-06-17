import SwiftUI
import AppKit

extension NSColor {
    convenience init(rgbHex hex: UInt32) {
        self.init(srgbRed: Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue: Double(hex & 0xFF) / 255.0,
                  alpha: 1.0)
    }
}

/// GitHub Primer palette — light = "GitHub Light Default", dark = "GitHub Dark Default".
enum GH {
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgbHex: isDark ? dark : light)
        })
    }

    static let canvas    = dyn(0xFFFFFF, 0x0D1117) // canvas.default
    static let subtle    = dyn(0xF6F8FA, 0x161B22) // canvas.subtle
    static let border    = dyn(0xD0D7DE, 0x30363D) // border.default
    static let fg        = dyn(0x1F2328, 0xE6EDF3) // fg.default
    static let muted     = dyn(0x59636E, 0x8B949E) // fg.muted
    static let accent    = dyn(0x0969DA, 0x4493F8) // accent.fg
    static let success   = dyn(0x1A7F37, 0x3FB950) // success.fg
    static let danger    = dyn(0xCF222E, 0xF85149) // danger.fg
    static let attention = dyn(0x9A6700, 0xD29922) // attention.fg
    static let severe    = dyn(0xBC4C00, 0xDB6D28) // severe.fg (orange, conflicts)
    static let done      = dyn(0x8250DF, 0xA371F7) // done.fg (purple, bots)
}
