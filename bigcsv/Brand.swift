import SwiftUI
import AppKit
import CoreText

/// The single source of truth for BigCSV's visual brand — colors, fonts, radii.
/// Every styled surface reads from here, so the whole app re-skins from one place.
/// Colors are dynamic (follow the system light/dark appearance); fonts are the
/// bundled Geist / Geist Mono pair (the sans↔mono contrast IS the brand), with a
/// graceful fall back to the system fonts if the bundle is missing them.
enum Brand {

    // MARK: Fonts

    /// Registers the bundled .ttf fonts exactly once (idempotent).
    static let registerFonts: Void = {
        for url in Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    enum W { case regular, medium, semibold
        var ns: NSFont.Weight { self == .semibold ? .semibold : (self == .medium ? .medium : .regular) }
        var su: Font.Weight { self == .semibold ? .semibold : (self == .medium ? .medium : .regular) }
    }

    private static func sansName(_ w: W) -> String {
        switch w { case .regular: "Geist-Regular"; case .medium: "Geist-Medium"; case .semibold: "Geist-SemiBold" }
    }
    private static func monoName(_ w: W) -> String {
        switch w { case .regular: "GeistMono-Regular"; case .medium: "GeistMono-Medium"; case .semibold: "GeistMono-SemiBold" }
    }

    static func sans(_ size: CGFloat, _ w: W = .regular) -> NSFont {
        _ = registerFonts
        return NSFont(name: sansName(w), size: size) ?? .systemFont(ofSize: size, weight: w.ns)
    }
    static func mono(_ size: CGFloat, _ w: W = .regular) -> NSFont {
        _ = registerFonts
        return NSFont(name: monoName(w), size: size) ?? .monospacedSystemFont(ofSize: size, weight: w.ns)
    }

    /// SwiftUI font (custom if the family registered, else the system equivalent).
    static func sansFont(_ size: CGFloat, _ w: W = .regular) -> Font {
        _ = registerFonts
        return NSFont(name: sansName(w), size: size) != nil
            ? .custom(sansName(w), fixedSize: size) : .system(size: size, weight: w.su)
    }
    static func monoFont(_ size: CGFloat, _ w: W = .regular) -> Font {
        _ = registerFonts
        return NSFont(name: monoName(w), size: size) != nil
            ? .custom(monoName(w), fixedSize: size) : .system(size: size, weight: w.su, design: .monospaced)
    }

    // MARK: Color tokens (light / dark)

    static let accent      = NSColor(hex: 0xA3E635)                 // signal green
    static let accentDeep  = NSColor(hex: 0x65A30D)                 // hover/active
    static let accentText  = dyn(0x3F6212, 0xBEF264)               // green text on surface

    static let windowBg    = dyn(0xFFFFFF, 0x16191B)
    static let barBg       = dyn(0xF6F6F4, 0x1C2022)
    static let headerBg    = dyn(0xF2F2F4, 0x1F2426)
    static let gutterBg    = dyn(0xF7F7F5, 0x1A1E20)
    static let zebraOdd    = dyn(0xFAFAFB, 0x1B1F21)
    static let searchBg    = dyn(0xF1F1EF, 0x23282A)

    static let textPrimary   = dyn(0x0E1110, 0xE8EAED)
    static let textSecondary = dyn(0x4B5563, 0x9BA3AB)
    static let textMuted     = dyn(0x6B7280, 0x6B7280)
    static let placeholder   = dyn(0x8A8F98, 0x6E767E)

    static let rowSeparator    = dyn(0x0E1110, 0xFFFFFF, 0.06, 0.07)
    static let columnSeparator = dyn(0x0E1110, 0xFFFFFF, 0.05, 0.07)
    static let hairline        = dyn(0x0E1110, 0xFFFFFF, 0.08, 0.10)

    static let selectionBg       = dyn(0xA3E635, 0xA3E635, 0.13, 0.16)
    static let matchHighlightBg  = dyn(0xA3E635, 0xA3E635, 0.22, 0.18)
    static let searchMatchBg     = dyn(0xA3E635, 0xA3E635, 0.34, 0.18)
    static let filterStripBg     = dyn(0xFBFDF4, 0x1B2113)

    // Quiet status dots (read fine on both appearances).
    static let dotPaid     = NSColor(hex: 0x65A30D)
    static let dotPending  = NSColor(hex: 0xD97706)
    static let dotRefunded = NSColor(hex: 0x9CA3AF)
    static let dotFailed   = NSColor(hex: 0xDC2626)

    // MARK: Metrics
    static let rowHeight: CGFloat = 34
    static let radiusControl: CGFloat = 8
    static let radiusCard: CGFloat = 12

    // MARK: Helpers

    /// A dynamic color that resolves per the view's effective appearance.
    static func dyn(_ light: UInt32, _ dark: UInt32, _ la: CGFloat = 1, _ da: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: dark, alpha: da) : NSColor(hex: light, alpha: la)
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// Convenience SwiftUI mirrors for the tokens used in the toolbar / sheets.
extension Color {
    init(_ ns: NSColor) { self.init(nsColor: ns) }
}
