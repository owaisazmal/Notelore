import SwiftUI

/// Shown once, before the very first recording. A calm reminder that consent
/// laws differ by place and the responsibility for obtaining it is the user's.
struct ConsentView: View {
    let onAcknowledge: () -> Void
    let onDecline: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionLabel("BEFORE YOU RECORD")

            Text("A note on consent")
                .font(.nlTitle)
                .foregroundStyle(Color.ink)

            VStack(alignment: .leading, spacing: 14) {
                Text("Recording laws differ from place to place. In some, everyone in the conversation must agree to be recorded.")
                Text("You are responsible for obtaining any consent the law requires where you are.")
                Text("What you record stays on this device until you ask for it to be made into minutes.")
            }
            .font(.nlProse)
            .foregroundStyle(Color.inkMuted)
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            VStack(spacing: 12) {
                Button("I understand", action: onAcknowledge)
                    .buttonStyle(NLPrimaryButtonStyle())
                Button("Not now") {
                    onDecline()
                    dismiss()
                }
                .buttonStyle(NLSecondaryButtonStyle())
            }
        }
        .padding(.horizontal, Theme.pageMargin)
        .padding(.top, 32)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .paperPage()
        .presentationDragIndicator(.visible)
    }
}
