import SwiftUI
import AppKit

// Brand palette (docs/brand.md).
extension Color {
    static let sottoInk = Color(red: 0x1C / 255, green: 0x1B / 255, blue: 0x22 / 255)
    static let sottoPaper = Color(red: 0xF6 / 255, green: 0xF4 / 255, blue: 0xEF / 255)
    static let sottoRecord = Color(red: 0xE5 / 255, green: 0x48 / 255, blue: 0x4D / 255)
    static let sottoHush = Color(red: 0x8A / 255, green: 0x86 / 255, blue: 0x99 / 255)
    static let sottoAccent = Color(red: 0x6C / 255, green: 0x63 / 255, blue: 0xD2 / 255)
}

extension NSColor {
    static let sottoRecord = NSColor(srgbRed: 0xE5 / 255, green: 0x48 / 255, blue: 0x4D / 255, alpha: 1)
}

extension View {
    /// Brand chrome for Sotto windows: paper surface, ink text, accent tint.
    /// The palette is light-only, so the window is pinned to the light scheme
    /// to keep semantic colors readable on paper in dark mode.
    func sottoWindowStyle() -> some View {
        self
            .foregroundStyle(Color.sottoInk)
            .tint(.sottoAccent)
            .preferredColorScheme(.light)
    }
}
