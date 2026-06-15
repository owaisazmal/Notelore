import SwiftUI

/// Type system: New York (serif) for headings and all generated prose,
/// SF Pro for interface chrome, monospaced digits wherever time appears.
extension Font {
    /// Large screen titles, e.g. "Library".
    static let nlPageTitle = Font.system(.largeTitle, design: .serif).weight(.semibold)
    /// Sheet and section titles.
    static let nlTitle = Font.system(.title2, design: .serif).weight(.semibold)
    /// Sub-headings within a page.
    static let nlHeading = Font.system(.headline, design: .serif)
    /// Generated prose and transcripts — the manuscript voice.
    static let nlProse = Font.system(.body, design: .serif)
    static let nlProseItalic = Font.system(.body, design: .serif).italic()
    /// Smaller serif, e.g. list previews.
    static let nlProseSmall = Font.system(.subheadline, design: .serif)
    /// Interface chrome: labels, captions, buttons.
    static let nlChrome = Font.system(.subheadline)
    static let nlChromeSmall = Font.system(.footnote)
    /// Small-caps markers, e.g. LISTENING, running heads above sections.
    static let nlLabel = Font.system(.footnote).weight(.medium).smallCaps()
    /// Timestamps — digits must not jitter as they count.
    static let nlTimestamp = Font.system(.subheadline).monospacedDigit()
    /// The elapsed-time clock on the record screen.
    static let nlClock = Font.system(size: 44, weight: .light).monospacedDigit()
}
