import SwiftUI
import SwiftData

/// The shelf of everything recorded: a reverse-chronological list of
/// sittings, searchable, filterable by tag, each opening to its Minutes
/// and transcript.
struct LibraryView: View {
    let services: AppServices
    @Query(sort: \Session.createdAt, order: .reverse) private var sessions: [Session]

    @State private var searchText = ""
    @State private var selectedTag: String?
    @State private var pendingDelete: Session?

    init(services: AppServices) {
        self.services = services
    }

    var body: some View {
        NavigationStack {
            Group {
                if !searchText.isEmpty {
                    searchList
                } else if filteredSessions.isEmpty {
                    emptyState
                } else {
                    sessionList
                }
            }
            .paperPage()
            .navigationTitle("Library")
            .searchable(text: $searchText, prompt: "Search the lore")
            .confirmationDialog(
                "Remove this session and its recording?",
                isPresented: deleteDialogBinding,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let pendingDelete {
                        services.notesStore.delete(pendingDelete)
                    }
                    pendingDelete = nil
                }
                Button("Keep", role: .cancel) { pendingDelete = nil }
            }
        }
    }

    // MARK: Lists

    private var sessionList: some View {
        List {
            if !services.notesStore.allTags().isEmpty {
                tagFilter
                    .listRowInsets(EdgeInsets(top: 8, leading: Theme.pageMargin, bottom: 8, trailing: 0))
                    .listRowBackground(Color.paper)
                    .listRowSeparator(.hidden)
            }
            ForEach(filteredSessions) { session in
                NavigationLink {
                    SessionDetailView(session: session, services: services)
                } label: {
                    SessionRow(session: session, isProcessing: services.processing.isProcessing(session.id))
                }
                .listRowBackground(Color.paper)
                .listRowSeparatorTint(Color.inkHairline)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingDelete = session
                    } label: {
                        Text("Delete")
                    }
                    .tint(Color.vermillion)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var searchList: some View {
        let results = services.notesStore.search(searchText)
        return Group {
            if results.isEmpty {
                EpigraphView(text: "Nothing in the lore answers to that yet.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(results, id: \.session.id) { result in
                        NavigationLink {
                            SessionDetailView(session: result.session, services: services)
                        } label: {
                            SearchResultRow(session: result.session, snippet: result.snippet)
                        }
                        .listRowBackground(Color.paper)
                        .listRowSeparatorTint(Color.inkHairline)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    // MARK: Tag filter

    private var tagFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(services.notesStore.allTags(), id: \.self) { tag in
                    Button {
                        withAnimation(Theme.fade) {
                            selectedTag = (selectedTag == tag) ? nil : tag
                        }
                    } label: {
                        TagChip(text: tag, selected: selectedTag == tag)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.trailing, Theme.pageMargin)
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        EpigraphView(text: "Nothing is written yet. What you record will be kept here, word for word.")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Derived state

    private var filteredSessions: [Session] {
        guard let selectedTag else { return sessions }
        return sessions.filter { $0.tags.contains(selectedTag) }
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { isPresented in if !isPresented { pendingDelete = nil } }
        )
    }
}

/// A single shelf line: title, the sitting's date and length, a short
/// preview, and any tags.
private struct SessionRow: View {
    let session: Session
    var isProcessing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.title)
                .font(.nlHeading)
                .foregroundStyle(Color.ink)
                .lineLimit(1)

            Text(metaLine)
                .font(.nlTimestamp)
                .foregroundStyle(Color.inkMuted)

            if isProcessing {
                Text("WRITING MINUTES…")
                    .font(.nlLabel)
                    .tracking(1.4)
                    .foregroundStyle(Color.inkMuted)
            }

            if !preview.isEmpty {
                Text(preview)
                    .font(.nlProseSmall)
                    .foregroundStyle(Color.inkMuted)
                    .lineLimit(2)
            }

            if !session.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(session.tags, id: \.self) { tag in
                            TagChip(text: tag)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var metaLine: String {
        "\(LibraryFormat.mediumDate(session.createdAt)) · \(LibraryFormat.minutes(session.duration))"
    }

    private var preview: String {
        if let summary = session.note?.summary, !summary.isEmpty {
            return summary
        }
        let text = session.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.prefix(140))
    }
}

/// A search hit: the title and the matched snippet beneath it.
private struct SearchResultRow: View {
    let session: Session
    let snippet: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.title)
                .font(.nlHeading)
                .foregroundStyle(Color.ink)
                .lineLimit(1)
            if !snippet.isEmpty {
                Text(snippet)
                    .font(.nlProseItalic)
                    .foregroundStyle(Color.inkMuted)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 6)
    }
}

/// Shared date/duration formatting for the Library and detail screens.
enum LibraryFormat {
    /// Medium date, e.g. "12 Jun 2026".
    static func mediumDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    /// Whole minutes, e.g. "23 min"; anything under a minute reads "1 min".
    static func minutes(_ seconds: TimeInterval) -> String {
        guard seconds >= 1 else { return "0 min" }
        return "\(max(1, Int(seconds / 60))) min"
    }
}
