import AppKit

/// Glass leaves the native backdrop visible. Solid is opaque, including its
/// center label. Reduce Transparency always uses the opaque presentation.
struct WheelSurfaceStyle {
    let appearance: WheelAppearance
    let dark: Bool
    let reduceTransparency: Bool
    var usesBackdrop: Bool { appearance == .glass && !reduceTransparency }
    var sectorColors: [CGColor] {
        if usesBackdrop {
            return dark
                ? [NSColor(white: 1, alpha: 0.16).cgColor, NSColor(white: 1, alpha: 0.06).cgColor]
                : [NSColor(white: 1, alpha: 0.32).cgColor, NSColor(white: 1, alpha: 0.12).cgColor]
        }
        return dark
            ? [NSColor(white: 0.29, alpha: 1).cgColor, NSColor(white: 0.21, alpha: 1).cgColor]
            : [NSColor(white: 0.99, alpha: 1).cgColor, NSColor(white: 0.85, alpha: 1).cgColor]
    }
    var centerColor: CGColor {
        if usesBackdrop { return NSColor(white: dark ? 1 : 0, alpha: dark ? 0.12 : 0.06).cgColor }
        return NSColor(white: dark ? 0.32 : 0.92, alpha: 1).cgColor
    }
}
