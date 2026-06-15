import SwiftUI

/// Prep — paste a job description or meeting agenda and Notelore drafts a
/// study guide to read in the days before. Preparation only; nothing here
/// happens during a conversation.
struct PrepView: View {
    @State private var model: PrepModel

    init(services: AppServices) {
        _model = State(initialValue: PrepModel(services: services))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let guide = model.guide {
                        resultSection(guide)
                    } else {
                        composeSection
                    }
                }
                .padding(Theme.pageMargin)
                .animation(Theme.settle, value: model.phase)
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .paperPage()
            .navigationTitle("Prep")
            .toolbar {
                if let guide = model.guide {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: PrepModel.markdown(for: guide, brief: model.brief))
                    }
                }
            }
        }
    }

    // MARK: - Compose

    private var composeSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Paste a job description or a meeting agenda. Notelore drafts the questions likely to come up and the points worth making, so you can study before you walk in.")
                .font(.nlProse)
                .foregroundStyle(Color.inkMuted)

            briefEditor

            Button("Prepare") {
                model.prepare()
            }
            .buttonStyle(NLPrimaryButtonStyle())
            .disabled(!model.canPrepare)
            .opacity(model.canPrepare ? 1 : 0.5)
            .animation(Theme.fade, value: model.canPrepare)

            if model.isRunning {
                Text("Drafting your study notes…")
                    .font(.nlProseItalic)
                    .foregroundStyle(Color.inkMuted)
            }

            if let error = model.error {
                Text(error.errorDescription ?? "The service had trouble answering. Try again shortly.")
                    .font(.nlChromeSmall)
                    .foregroundStyle(Color.inkMuted)
            }

            if model.showsEmptyState {
                EpigraphView(text: "Walk in prepared. Paste what you're walking into.")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
            }
        }
    }

    private var briefEditor: some View {
        TextEditor(text: $model.brief)
            .font(.nlProse)
            .foregroundStyle(Color.ink)
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(minHeight: 160)
            .background(Color.paperRaised)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .strokeBorder(Color.inkHairline, lineWidth: Theme.hairline)
            )
            .overlay(alignment: .topLeading) {
                if model.brief.isEmpty {
                    Text("A job description, an agenda, a syllabus…")
                        .font(.nlProseItalic)
                        .foregroundStyle(Color.inkMuted)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
            .disabled(model.isRunning)
    }

    // MARK: - Result

    private func resultSection(_ guide: PrepGuide) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if !guide.likelyQuestions.isEmpty {
                SectionLabel("LIKELY QUESTIONS")
                ForEach(Array(guide.likelyQuestions.enumerated()), id: \.offset) { index, item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.question)
                            .font(.nlHeading)
                            .foregroundStyle(Color.ink)
                        ForEach(Array(item.pointsToMake.enumerated()), id: \.offset) { _, point in
                            Text("•  \(point)")
                                .font(.nlProse)
                                .foregroundStyle(Color.ink)
                        }
                    }
                    if index < guide.likelyQuestions.count - 1 {
                        InkDivider()
                    }
                }
            }

            if !guide.talkingPoints.isEmpty {
                SectionLabel("TALKING POINTS")
                    .padding(.top, guide.likelyQuestions.isEmpty ? 0 : 8)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(guide.talkingPoints.enumerated()), id: \.offset) { _, point in
                        Text("•  \(point)")
                            .font(.nlProse)
                            .foregroundStyle(Color.ink)
                    }
                }
            }

            Button("Start over") {
                model.startOver()
            }
            .buttonStyle(.plain)
            .font(.nlChrome)
            .foregroundStyle(Color.inkMuted)
            .padding(.top, 12)
        }
    }
}
