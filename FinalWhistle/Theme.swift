import SwiftUI

/// Colours taken verbatim from final-whistle.app
/// (src/app/globals.css in the web app repo):
///   --bg #050712, --bg-2 #0b0e22, --panel #12162e,
///   --panel-soft #171c38, --line #262c52, --text #f4f6ff,
///   --muted #a6abd0, --accent #bd195d, --accent-soft #fea282,
///   --lime #a2e634.
/// The site is dark-only, so the app is too.
extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    static let fwBackground = Color(hex: "050712")
    static let fwBackground2 = Color(hex: "0b0e22")
    static let fwPanel = Color(hex: "12162e")
    static let fwPanelSoft = Color(hex: "171c38")
    static let fwLine = Color(hex: "262c52")
    static let fwText = Color(hex: "f4f6ff")
    static let fwMuted = Color(hex: "a6abd0")
    static let fwAccent = Color(hex: "bd195d")
    static let fwAccentSoft = Color(hex: "fea282")
    static let fwLime = Color(hex: "a2e634")
}

/// Liquid Glass numbers (Glazier pattern 4, Chat; pattern 8, Viewer).
/// U is the composer height at rest; a capsule's corners are U / 2,
/// and the composer grows into a card with the same corner radius
/// while typing. The glass itself is `.regular.interactive()`.
enum GlassMetrics {
    /// The composer capsule height at rest.
    static let composerU: CGFloat = 52
    /// The inset of the circle buttons inside the composer.
    static let composerInset: CGFloat = 8
    /// A floating control's height (title pill, close button).
    static let barHeight: CGFloat = 44
}
