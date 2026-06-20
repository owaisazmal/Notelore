import SwiftUI

/// The Record tab: an unhurried paper page that becomes a typewritten
/// manuscript while Notelore listens.
struct RecordView: View {
    @State private var model: RecordModel
    @State private var showDiscardConfirm = false

    init(services: AppServices) {
        _model = State(initialValue: RecordModel(services: services))
    }

    var body: some View {
        Group {
            switch model.phase {
            case .idle:
                idleView
            case .recording:
                recordingView
            case .saving:
                savingView
            case .saved(let session):
                savedView(session)
            }
        }
        .animation(Theme.settle, value: model.phaseKey)
        .paperPage()
        .sheet(isPresented: $model.showConsent) {
            ConsentView(
                onAcknowledge: { model.consentAcknowledged() },
                onDecline: { model.consentDeclined() }
            )
        }
    }

    // MARK: Idle

    private var idleView: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 16) {
                SectionLabel("A Second Memory")
                Text("When the conversation begins, press record. Notelore listens, and remembers.")
                    .font(.nlTitle)
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, Theme.pageMargin)
            Spacer()
            VStack(spacing: 12) {
                if let notice = model.notice {
                    Text(notice)
                        .font(.nlChromeSmall)
                        .foregroundStyle(Color.inkMuted)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                }
                if model.showsOpenSettings {
                    Button("Open Settings") { model.openSettings() }
                        .buttonStyle(NLSecondaryButtonStyle())
                }
                Button("Begin recording") { model.beginTapped() }
                    .buttonStyle(NLPrimaryButtonStyle())
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, Theme.pageMargin)
            .padding(.bottom, 32)
            .animation(Theme.fade, value: model.notice)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Recording

    private var recordingView: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                ListeningBadge(paused: model.isPaused)
                Text(model.elapsedText)
                    .font(.nlClock)
                    .foregroundStyle(Color.ink)
                if let note = model.recordingNotice {
                    Text(note)
                        .font(.nlChromeSmall)
                        .foregroundStyle(Color.inkMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Theme.pageMargin)
                        .transition(.opacity)
                }
            }
            .padding(.top, 28)
            .padding(.bottom, 20)
            .animation(Theme.fade, value: model.recordingNotice)

            InkDivider()

            if model.transcriptionActive {
                if model.marginNotesAvailable {
                    paneToggle
                        .padding(.horizontal, Theme.pageMargin)
                        .padding(.top, 12)
                        .padding(.bottom, 2)
                }
                if model.showsMarginNotes {
                    marginNotesScroll
                } else {
                    transcriptScroll
                }
            } else {
                VStack {
                    Spacer()
                    Text("Listening. The transcript will not be written this time.")
                        .font(.nlProseItalic)
                        .foregroundStyle(Color.inkMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 36)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }

            InkDivider()

            VStack(spacing: 14) {
                if let footnote = model.routeFootnote {
                    Text(footnote)
                        .font(.nlChromeSmall)
                        .foregroundStyle(Color.inkMuted)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                }
                HStack(spacing: 12) {
                    Button(model.isPaused ? "Resume" : "Pause") { model.togglePause() }
                        .buttonStyle(NLSecondaryButtonStyle())
                    Button("End recording") { model.endTapped() }
                        .buttonStyle(NLPrimaryButtonStyle())
                }
                Button("Discard") { showDiscardConfirm = true }
                    .font(.nlChromeSmall)
                    .foregroundStyle(Color.inkMuted)
            }
            .padding(.horizontal, Theme.pageMargin)
            .padding(.top, 16)
            .padding(.bottom, 12)
            .animation(Theme.fade, value: model.routeFootnote)
        }
        .confirmationDialog(
            "Discard this recording?",
            isPresented: $showDiscardConfirm,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) { model.discard() }
            Button("Keep recording", role: .cancel) {}
        }
    }

    private var transcriptScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.snapshot.finalized) { utterance in
                        Text(utterance.text)
                            .font(.nlProse)
                            .foregroundStyle(Color.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !model.snapshot.volatileText.isEmpty {
                        Text(model.snapshot.volatileText)
                            .font(.nlProse)
                            .foregroundStyle(Color.inkMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(transcriptBottomID)
                }
                .padding(.horizontal, Theme.pageMargin)
                .padding(.vertical, 18)
            }
            .scrollContentBackground(.hidden)
            .onChange(of: model.snapshot) { _, _ in
                withAnimation(Theme.fade) {
                    proxy.scrollTo(transcriptBottomID, anchor: .bottom)
                }
            }
        }
    }

    private var transcriptBottomID: String { "transcript-bottom" }

    // MARK: Margin notes (live)

    /// Flat paper toggle between the live transcript and the live margin notes.
    private var paneToggle: some View {
        HStack(spacing: 28) {
            paneButton(title: "Transcript", selected: !model.showsMarginNotes) {
                model.showsMarginNotes = false
            }
            paneButton(title: marginTitle, selected: model.showsMarginNotes) {
                model.showsMarginNotes = true
            }
            Spacer(minLength: 0)
        }
    }

    private var marginTitle: String {
        model.marginNotes.isEmpty ? "Live Definitions" : "Live Definitions (\(model.marginNotes.count))"
    }

    private func paneButton(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(title)
                    .font(.nlLabel)
                    .tracking(1.4)
                    .foregroundStyle(selected ? Color.ink : Color.inkMuted)
                Rectangle()
                    .fill(selected ? Color.ink : Color.clear)
                    .frame(height: Theme.hairline)
            }
            .fixedSize()
        }
        .buttonStyle(.plain)
        .animation(Theme.fade, value: selected)
    }

    @ViewBuilder
    private var marginNotesScroll: some View {
        if model.marginNotes.isEmpty {
            VStack {
                Spacer()
                Text("Defining what's being said…")
                    .font(.nlProseItalic)
                    .foregroundStyle(Color.inkMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(model.marginNotes) { note in
                        marginNoteRow(note)
                    }
                }
                .padding(.horizontal, Theme.pageMargin)
                .padding(.vertical, 18)
                .animation(Theme.fade, value: model.marginNotes.count)
            }
            .scrollContentBackground(.hidden)
        }
    }

    private func marginNoteRow(_ note: MarginNote) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if note.isQuestion {
                Text("QUESTION")
                    .font(.nlLabel)
                    .tracking(1.4)
                    .foregroundStyle(Color.inkMuted)
            }
            Text(note.headword)
                .font(.nlHeading)
                .foregroundStyle(Color.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(note.note)
                .font(.nlProse)
                .foregroundStyle(Color.inkMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Saving

    private var savingView: some View {
        Text(model.savingMessage)
            .font(.nlProseItalic)
            .foregroundStyle(Color.inkMuted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Saved

    private func savedView(_ session: Session) -> some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 16) {
                Text("Saved to Library")
                    .font(.nlLabel)
                    .tracking(1.4)
                    .foregroundStyle(Color.sage)
                Text(session.title)
                    .font(.nlTitle)
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
                if let footnote = model.savedFootnote {
                    Text(footnote)
                        .font(.nlProseSmall)
                        .foregroundStyle(Color.inkMuted)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, Theme.pageMargin)
            Spacer()
            Button("Record another") { model.recordAnother() }
                .buttonStyle(NLSecondaryButtonStyle())
                .frame(maxWidth: 420)
                .padding(.horizontal, Theme.pageMargin)
                .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity)
    }
}
