import SwiftUI

/// Shared brand + contrast tokens for HTML辑霸 (native + web parity).
/// Aligned with kangzhe-design-3d core: light-only surfaces, orange identity ≤12% area,
/// ink text on light glass, white text ONLY on solid accent.
enum Theme {
    // Brand (kangzhe core: 主强调 #FF9900 / 副强调 #FFCC00 / 深 #DB6B05)
    static let accent = Color(red: 1.0, green: 0.6, blue: 0.0)              // #FF9900
    static let accentSub = Color(red: 1.0, green: 0.8, blue: 0.0)          // #FFCC00
    static let accentDeep = Color(red: 0.859, green: 0.42, blue: 0.02)     // #DB6B05
    static let ink = Color(red: 0.059, green: 0.067, blue: 0.082)          // #0F1115 primary text
    static let inkSecondary = Color(red: 0.322, green: 0.353, blue: 0.4)   // #525A66 readable secondary
    static let inkTertiary = Color(red: 0.478, green: 0.51, blue: 0.557)   // #7A828E still readable
    static let onAccent = Color.white                                     // only on solid accent
    static let canvas = Color(red: 0.93, green: 0.94, blue: 0.96)
    static let panelStroke = Color.white.opacity(0.65)

    // Solid fills used under text (never rely on adaptive primary on clear glass)
    static let glassPanel = Color.white.opacity(0.72)
    static let glassChip = Color.white.opacity(0.82)
    static let solidAccent = Color(red: 1.0, green: 0.6, blue: 0.0)
}
