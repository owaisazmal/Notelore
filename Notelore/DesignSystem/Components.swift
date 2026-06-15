import SwiftUI

/// The 1 px hairline rule — the only divider Notelore uses.
struct InkDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.inkHairline)
            .frame(height: Theme.hairline)
    }
}

/// A small-caps running head above a section, like a printed margin label.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.nlLabel)
            .tracking(1.4)
            .foregroundStyle(Color.inkMuted)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The recording state: a small filled vermillion circle beside "Listening"
/// in small caps. Deliberately still — no pulsing, no waveform.
struct ListeningBadge: View {
    var paused = false
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(paused ? Color.inkMuted : Color.vermillion)
                .frame(width: 8, height: 8)
            Text(paused ? "Paused" : "Listening")
                .font(.nlLabel)
                .tracking(1.4)
                .foregroundStyle(paused ? Color.inkMuted : Color.vermillion)
        }
        .animation(Theme.fade, value: paused)
    }
}

/// Empty states are short typeset epigraphs — never illustrations.
struct EpigraphView: View {
    let text: String
    var attribution: String? = nil
    var body: some View {
        VStack(spacing: 10) {
            Text(text)
                .font(.nlProseItalic)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.inkMuted)
            if let attribution {
                Text("— \(attribution)")
                    .font(.nlChromeSmall)
                    .foregroundStyle(Color.inkMuted)
            }
        }
        .padding(.horizontal, 36)
        .frame(maxWidth: 420)
    }
}

/// Primary action: a flat vermillion plate with paper-coloured text.
struct NLPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.nlChrome.weight(.medium))
            .foregroundStyle(Color.paper)
            .padding(.vertical, 12)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .background(Color.vermillion.opacity(configuration.isPressed ? 0.85 : 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .animation(Theme.fade, value: configuration.isPressed)
    }
}

/// Secondary action: ink text inside a hairline border.
struct NLSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.nlChrome.weight(.medium))
            .foregroundStyle(Color.ink)
            .padding(.vertical, 12)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .background(Color.paperRaised.opacity(configuration.isPressed ? 1 : 0))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .strokeBorder(Color.inkHairline, lineWidth: Theme.hairline)
            )
            .animation(Theme.fade, value: configuration.isPressed)
    }
}

/// A tag rendered as quiet set type on a raised paper chip.
struct TagChip: View {
    let text: String
    var selected = false
    var body: some View {
        Text(text)
            .font(.nlChromeSmall)
            .foregroundStyle(selected ? Color.paper : Color.inkMuted)
            .padding(.vertical, 4)
            .padding(.horizontal, 10)
            .background(selected ? Color.ink : Color.paperRaised)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }
}
