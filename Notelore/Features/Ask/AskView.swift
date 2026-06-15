import Foundation
import SwiftUI

/// "Ask the lore" — one question, one answer drawn from the user's own
/// notes. No chat history; each ask replaces the last.
struct AskView: View {
    @State private var model: AskModel
    private let services: AppServices

    init(services: AppServices) {
        self.services = services
        _model = State(initialValue: AskModel(services: services))
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.hasSessions {
                    content
                } else {
                    EpigraphView(text: "There is nothing to ask yet. Record a sitting first.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .paperPage()
            .navigationTitle("Ask the lore")
        }
        .onAppear { model.refresh() }
        .onDisappear { model.cancel() }
    }

    // MARK: Layout

    private var content: some View {
        VStack(spacing: 0) {
            questionArea
                .padding(Theme.pageMargin)
            InkDivider()
            ScrollView {
                resultArea
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.pageMargin)
                    .animation(Theme.fade, value: model.phase)
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var questionArea: some View {
        VStack(spacing: 12) {
            TextField("Ask your notes…", text: $model.question)
                .font(.nlProse)
                .foregroundStyle(Color.ink)
                .submitLabel(.send)
                .onSubmit { model.ask() }
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .background(Color.paperRaised)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius)
                        .strokeBorder(Color.inkHairline, lineWidth: Theme.hairline)
                )

            Button("Ask") { model.ask() }
                .buttonStyle(NLPrimaryButtonStyle())
                .disabled(!model.canAsk)
                .opacity(model.canAsk ? 1 : 0.4)
                .animation(Theme.fade, value: model.canAsk)
        }
    }

    @ViewBuilder
    private var resultArea: some View {
        if !model.hasKey {
            Text("Add your key in Settings to ask the lore.")
                .font(.nlProse)
                .foregroundStyle(Color.inkMuted)
                .padding(.top, 8)
        } else {
            switch model.phase {
            case .idle:
                EpigraphView(text: "Ask, and the lore answers from what you have kept.")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 72)
            case .nothingRelevant:
                Text("Nothing in your notes speaks to that yet.")
                    .font(.nlProseItalic)
                    .foregroundStyle(Color.inkMuted)
                    .padding(.top, 8)
            case .consulting:
                Text("Consulting the lore…")
                    .font(.nlProseItalic)
                    .foregroundStyle(Color.inkMuted)
                    .padding(.top, 8)
                    .transition(.opacity)
            case .streaming, .finished:
                answerArea
            case .failed:
                errorFootnote
                    .padding(.top, 8)
            }
        }
    }

    @ViewBuilder
    private var answerArea: some View {
        VStack(alignment: .leading, spacing: Theme.pageMargin) {
            Text(model.answer)
                .font(.nlProse)
                .foregroundStyle(Color.ink)
                .lineSpacing(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            errorFootnote

            if model.phase == .finished, !model.sources.isEmpty {
                sourcesArea
            }
        }
    }

    private var sourcesArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("DRAWN FROM")
                .padding(.bottom, 4)
            ForEach(Array(model.sources.enumerated()), id: \.element.id) { index, session in
                if index > 0 {
                    InkDivider()
                }
                NavigationLink {
                    SessionDetailView(session: session, services: services)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(session.title)
                            .font(.nlProseSmall)
                            .foregroundStyle(Color.ink)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(session.createdAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.nlTimestamp)
                            .foregroundStyle(Color.inkMuted)
                    }
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var errorFootnote: some View {
        if let errorText = model.errorText {
            Text(errorText)
                .font(.nlChromeSmall)
                .foregroundStyle(model.errorNeedsAction ? Color.vermillion : Color.inkMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
