import SwiftUI
import UIKit

/// Notelore palette — "paper, not glass".
/// Light mode is ivory stationery with near-black ink. Dark mode is "ink
/// paper": a deep warm brown-black with warm off-white text. One vermillion
/// accent for recording and primary actions; sage for success.
extension Color {
    /// #FAF6EF light / #161310 dark — every screen's background.
    static let paper = Color(light: 0xFAF6EF, dark: 0x161310)
    /// A barely-raised flat surface for fields and chips. Never shadowed.
    static let paperRaised = Color(light: 0xF2EDE2, dark: 0x211D18)
    /// #1A1714 light / warm off-white dark — primary text.
    static let ink = Color(light: 0x1A1714, dark: 0xF2EDE3)
    /// Secondary text.
    static let inkMuted = Color(light: 0x6E6759, dark: 0xA59D8E)
    /// 1px hairline rules.
    static let inkHairline = Color(light: 0xDAD3C5, dark: 0x36312A)
    /// #C24A2E — the recording state and primary actions only.
    static let vermillion = Color(light: 0xC24A2E, dark: 0xD2603F)
    /// #7A8B6F — success and quiet confirmation.
    static let sage = Color(light: 0x7A8B6F, dark: 0x90A284)

    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light)
        })
    }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Shared metrics and motion. Surfaces are flat; the only rounding is a
/// printer's 2 pt, and motion is limited to 150–250 ms fades and settles.
enum Theme {
    static let cornerRadius: CGFloat = 2
    static let hairline: CGFloat = 1
    static let pageMargin: CGFloat = 20
    static let fade = Animation.easeOut(duration: 0.2)
    static let settle = Animation.easeInOut(duration: 0.25)
}

extension View {
    /// Standard page treatment: paper background under everything.
    func paperPage() -> some View {
        self.background(Color.paper.ignoresSafeArea())
    }
}
