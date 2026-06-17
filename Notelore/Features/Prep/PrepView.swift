import SwiftUI

/// Prep — paste a job description or meeting agenda and Notelore drafts a
/// study guide to read in the days before. Preparation only; nothing here
/// happens during a conversation.
struct PrepView: View {
    @State private var model: PrepModel
    @State private var entryBeingRenamed: PrepEntry?
    @State private var renameText = ""

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
            .navigationBarTitleDisplayMode(model.guide == nil ? .large : .inline)
            .onAppear { model.loadHistory() }
            .toolbar {
                if let guide = model.guide {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            model.back()
                        } label: {
                            Label("Prep", systemImage: "chevron.left")
                        }
                        .tint(Color.vermillion)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: PrepModel.markdown(for: guide, brief: model.brief))
                    }
                }
            }
            .alert("Rename", isPresented: renamePresented, presenting: entryBeingRenamed) { entry in
                TextField("Title", text: $renameText)
                Button("Save") {
                    model.rename(entry, to: renameText)
                    entryBeingRenamed = nil
                }
                Button("Cancel", role: .cancel) { entryBeingRenamed = nil }
            }
        }
    }

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { entryBeingRenamed != nil },
            set: { if !$0 { entryBeingRenamed = nil } }
        )
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

            if !model.history.isEmpty {
                historySection
                    .padding(.top, 12)
            }
        }
    }

    // MARK: - History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("RECENTLY PREPARED")
                .padding(.bottom, 4)
            ForEach(model.history, id: \.id) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Button {
                        model.show(entry)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title)
                                .font(.nlProseSmall)
                                .foregroundStyle(Color.ink)
                                .multilineTextAlignment(.leading)
                            Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.nlTimestamp)
                                .foregroundStyle(Color.inkMuted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)

                    Menu {
                        Button {
                            renameText = entry.title
                            entryBeingRenamed = entry
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            model.delete(entry)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.nlChromeSmall)
                            .foregroundStyle(Color.inkMuted)
                            .frame(width: 32, height: 32, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("More actions for this preparation")
                }
                .padding(.vertical, 12)

                if entry.id != model.history.last?.id {
                    InkDivider()
                }
            }
        }
    }

    private var briefEditor: some View {
        TextEditor(text: $model.brief)
            .font(.nlProse)
            .foregroundStyle(Color.ink)
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(height: 200)
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
