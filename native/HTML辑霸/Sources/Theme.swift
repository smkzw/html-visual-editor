import SwiftUI

/// Shared brand + contrast tokens for HTML辑霸 (native + web parity).
enum Theme {
    // Brand
    static let accent = Color(red: 1.0, green: 0.58, blue: 0.10)          // #FF941A
    static let accentDeep = Color(red: 0.86, green: 0.42, blue: 0.02)     // darker orange
    static let ink = Color(red: 0.12, green: 0.14, blue: 0.17)            // #1F242B primary text
    static let inkSecondary = Color(red: 0.32, green: 0.36, blue: 0.42)   // readable secondary
    static let inkTertiary = Color(red: 0.48, green: 0.52, blue: 0.58)    // still readable
    static let onAccent = Color.white                                     // only on solid accent
    static let canvas = Color(red: 0.93, green: 0.94, blue: 0.96)
    static let panelStroke = Color.white.opacity(0.65)

    // Solid fills used under text (never rely on adaptive primary on clear glass)
    static let glassPanel = Color.white.opacity(0.72)
    static let glassChip = Color.white.opacity(0.82)
    static let solidAccent = Color(red: 1.0, green: 0.55, blue: 0.05)
}
