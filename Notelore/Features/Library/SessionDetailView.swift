import SwiftUI

/// One sitting in full: an editable title and tags, then either its Minutes
/// or its transcript. On iPad the two are shown side by side.
struct SessionDetailView: View {
    @State private var model: SessionDetailModel
    @State private var titleText: String
    @State private var pane: Pane = .minutes
    @State private var newTag = ""
    @Environment(\.horizontalSizeClass) private var sizeClass

    private let session: Session

    enum Pane: Hashable {
        case minutes
        case transcript
    }

    init(session: Session, services: AppServices) {
        self.session = session
        _model = State(initialValue: SessionDetailModel(session: session, services: services))
        _titleText = State(initialValue: session.title)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.pageMargin) {
                header
                InkDivider()
                if sizeClass == .regular {
                    splitPanes
                } else {
                    paneToggle

                    switch pane {
                    case .minutes:
                        MinutesView(model: model)
                    case .transcript:
                        TranscriptView(session: session)
                    }
                }
            }
            .padding(Theme.pageMargin)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .paperPage()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(
                    item: NoteMarkdown.markdown(for: session),
                    preview: SharePreview(session.title)
                ) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
    }

    // MARK: Pane toggle

    /// A flat, paper toggle between Minutes and Transcript: small-caps labels
    /// over a 1px ink underline that marks the active pane. No system chrome.
    private var paneToggle: some View {
        HStack(spacing: 28) {
            ForEach([Pane.minutes, Pane.transcript], id: \.self) { item in
                Button {
                    withAnimation(Theme.fade) { pane = item }
                } label: {
                    VStack(spacing: 6) {
                        Text(item == .minutes ? "Minutes" : "Transcript")
                            .font(.nlLabel)
                            .tracking(1.4)
                            .foregroundStyle(pane == item ? Color.ink : Color.inkMuted)
                        Rectangle()
                            .fill(pane == item ? Color.ink : Color.clear)
                            .frame(height: Theme.hairline)
                    }
                    .fixedSize()
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Untitled sitting", text: $titleText)
                .font(.nlTitle)
                .foregroundStyle(Color.ink)
                .textInputAutocapitalization(.sentences)
                .submitLabel(.done)
                .onSubmit { model.renameTitle(titleText) }

            Text(metaLine)
                .font(.nlTimestamp)
                .foregroundStyle(Color.inkMuted)

            tagEditor
        }
    }

    private var metaLine: String {
        "\(LibraryFormat.mediumDate(session.createdAt)) · \(LibraryFormat.minutes(session.duration))"
    }

    private var tagEditor: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.session.tags, id: \.self) { tag in
                    Button {
                        withAnimation(Theme.fade) { model.removeTag(tag) }
                    } label: {
                        HStack(spacing: 4) {
                            Text(tag)
                                .font(.nlChromeSmall)
                                .foregroundStyle(Color.inkMuted)
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.inkMuted)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 10)
                        .background(Color.paperRaised)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
                    }
                    .buttonStyle(.plain)
                }

                TextField("Add a tag", text: $newTag)
                    .font(.nlChromeSmall)
                    .foregroundStyle(Color.ink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(minWidth: 80)
                    .submitLabel(.done)
                    .onSubmit {
                        model.addTag(newTag)
                        newTag = ""
                    }
            }
        }
    }

    // MARK: iPad split

    private var splitPanes: some View {
        HStack(alignment: .top, spacing: Theme.pageMargin) {
            MinutesView(model: model)
                .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle()
                .fill(Color.inkHairline)
                .frame(width: Theme.hairline)
            TranscriptView(session: session)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Minutes

/// The distilled Minutes: editorial sections, with a hand-edit mode and a
/// way to write or rewrite them.
private struct MinutesView: View {
    @Bindable var model: SessionDetailModel
    @State private var confirmRewrite = false

    // Working copies used while editing by hand.
    @State private var draftSummary = ""
    @State private var draftKeyPoints = ""
    @State private var draftDecisions = ""
    @State private var draftQuestions = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.pageMargin) {
            if model.session.note != nil {
                if model.isEditingMinutes {
                    editor
                } else {
                    reader
                }
            } else {
                unwritten
            }
        }
    }

    private var note: Note? { model.session.note }

    // MARK: Reading

    @ViewBuilder
    private var reader: some View {
        if let note {
            VStack(alignment: .leading, spacing: Theme.pageMargin) {
                if !note.summary.isEmpty {
                    section("SUMMARY") {
                        Text(note.summary)
                            .font(.nlProse)
                            .foregroundStyle(Color.ink)
                            .lineSpacing(5)
                    }
                }
                if !note.keyPoints.isEmpty {
                    InkDivider()
                    section("KEY POINTS") { bullets(note.keyPoints) }
                }
                if !note.decisions.isEmpty {
                    InkDivider()
                    section("DECISIONS") { bullets(note.decisions) }
                }
                if !note.actionItems.isEmpty {
                    InkDivider()
                    section("ACTION ITEMS") { actionItems(note.actionItems) }
                }
                if !note.openQuestions.isEmpty {
                    InkDivider()
                    section("OPEN QUESTIONS") { bullets(note.openQuestions) }
                }

                InkDivider()
                footer(note: note)
            }
        }
    }

    private func footer(note: Note) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(footerText(note: note))
                .font(.nlChromeSmall)
                .foregroundStyle(Color.inkMuted)

            if model.isWriting {
                Text("Writing minutes…")
                    .font(.nlProseItalic)
                    .foregroundStyle(Color.inkMuted)
            }

            if let errorText = model.errorText {
                Text(errorText)
                    .font(.nlChromeSmall)
                    .foregroundStyle(Color.inkMuted)
            }

            HStack(spacing: 16) {
                Button("Edit") { beginEditing(note: note) }
                    .buttonStyle(NLSecondaryButtonStyle())
                    .disabled(model.isWriting)

                Button("Rewrite the minutes") {
                    if note.userEdited {
                        confirmRewrite = true
                    } else {
                        Task { await model.writeMinutes() }
                    }
                }
                .buttonStyle(NLSecondaryButtonStyle())
                .disabled(model.isWriting)
                .opacity(model.isWriting ? 0.5 : 1)
            }
            .confirmationDialog(
                "Rewriting will replace the edits you made by hand.",
                isPresented: $confirmRewrite,
                titleVisibility: .visible
            ) {
                Button("Rewrite", role: .destructive) {
                    Task { await model.writeMinutes() }
                }
                Button("Keep my edits", role: .cancel) {}
            }
        }
    }

    private func footerText(note: Note) -> String {
        var text = "Minutes written " + LibraryFormat.mediumDate(note.generatedAt)
        if note.userEdited {
            text += " · edited by hand"
        }
        return text
    }

    // MARK: Editing

    private var editor: some View {
        VStack(alignment: .leading, spacing: Theme.pageMargin) {
            editField("SUMMARY", text: $draftSummary)
            InkDivider()
            editField("KEY POINTS", text: $draftKeyPoints, hint: "One per line")
            InkDivider()
            editField("DECISIONS", text: $draftDecisions, hint: "One per line")
            InkDivider()
            editField("OPEN QUESTIONS", text: $draftQuestions, hint: "One per line")

            InkDivider()
            HStack(spacing: 16) {
                Button("Save") { commitEditing() }
                    .buttonStyle(NLPrimaryButtonStyle())
                Button("Cancel") { model.isEditingMinutes = false }
                    .buttonStyle(NLSecondaryButtonStyle())
            }
        }
    }

    private func editField(_ label: String, text: Binding<String>, hint: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(label)
            if let hint {
                Text(hint)
                    .font(.nlChromeSmall)
                    .foregroundStyle(Color.inkMuted)
            }
            TextEditor(text: text)
                .font(.nlProse)
                .foregroundStyle(Color.ink)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 80)
                .padding(8)
                .background(Color.paperRaised)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius)
                        .strokeBorder(Color.inkHairline, lineWidth: Theme.hairline)
                )
        }
    }

    private func beginEditing(note: Note) {
        draftSummary = note.summary
        draftKeyPoints = note.keyPoints.joined(separator: "\n")
        draftDecisions = note.decisions.joined(separator: "\n")
        draftQuestions = note.openQuestions.joined(separator: "\n")
        model.isEditingMinutes = true
    }

    private func commitEditing() {
        model.commitEdits(
            summary: draftSummary.trimmingCharacters(in: .whitespacesAndNewlines),
            keyPoints: lines(draftKeyPoints),
            decisions: lines(draftDecisions),
            openQuestions: lines(draftQuestions)
        )
    }

    private func lines(_ text: String) -> [String] {
        text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: Unwritten

    private var unwritten: some View {
        VStack(spacing: Theme.pageMargin) {
            EpigraphView(text: "The minutes for this sitting are not yet written.")
                .frame(maxWidth: .infinity)

            if model.isWriting {
                Text("Writing minutes…")
                    .font(.nlProseItalic)
                    .foregroundStyle(Color.inkMuted)
            } else {
                Button("Write minutes") {
                    Task { await model.writeMinutes() }
                }
                .buttonStyle(NLPrimaryButtonStyle())
                .disabled(!model.hasKey)
                .opacity(model.hasKey ? 1 : 0.5)
            }

            if let errorText = model.errorText {
                Text(errorText)
                    .font(.nlChromeSmall)
                    .foregroundStyle(Color.inkMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    // MARK: Building blocks

    private func section<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(label)
            content()
        }
    }

    private func bullets(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("·")
                        .font(.nlProse)
                        .foregroundStyle(Color.inkMuted)
                    Text(item)
                        .font(.nlProse)
                        .foregroundStyle(Color.ink)
                        .lineSpacing(5)
                }
            }
        }
    }

    private func actionItems(_ items: [ActionItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Button {
                        model.toggle(item)
                    } label: {
                        Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.isDone ? Color.sage : Color.inkMuted)
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.text)
                            .font(.nlProse)
                            .foregroundStyle(Color.ink)
                            .lineSpacing(5)
                        if let owner = item.owner, !owner.isEmpty {
                            Text("— \(owner)")
                                .font(.nlLabel)
                                .tracking(1.2)
                                .foregroundStyle(Color.inkMuted)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Transcript

/// The transcript as timestamped manuscript lines.
private struct TranscriptView: View {
    let session: Session

    var body: some View {
        if session.transcript.isEmpty {
            EpigraphView(text: "No transcript was written for this sitting.")
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(session.transcript) { utterance in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("[\(Distiller.timestamp(utterance.start))]")
                            .font(.nlTimestamp)
                            .foregroundStyle(Color.inkMuted)
                        Text(utterance.text)
                            .font(.nlProse)
                            .foregroundStyle(Color.ink)
                            .lineSpacing(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}
