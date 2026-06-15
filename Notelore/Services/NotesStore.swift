import Foundation
import SwiftData

/// All reads and writes of Sessions and Notes go through here, so audio
/// files, the denormalized search text, and SwiftData stay consistent.
@MainActor
final class NotesStore {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: Sessions

    @discardableResult
    func createSession(
        title: String,
        transcript: [Utterance],
        audioFileName: String?,
        duration: TimeInterval,
        languageCode: String?
    ) -> Session {
        let session = Session(
            title: title,
            duration: duration,
            audioFileName: audioFileName,
            transcript: transcript,
            languageCode: languageCode
        )
        context.insert(session)
        save()
        return session
    }

    func updateTranscript(_ session: Session, transcript: [Utterance]) {
        session.transcript = transcript
        session.transcriptText = transcript.map(\.text).joined(separator: " ")
        save()
    }

    func delete(_ session: Session) {
        AudioStorage.delete(fileName: session.audioFileName)
        context.delete(session)
        save()
    }

    func deleteAllData() {
        try? context.delete(model: Session.self)
        AudioStorage.deleteAll()
        save()
    }

    func allSessions() -> [Session] {
        let descriptor = FetchDescriptor<Session>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func allTags() -> [String] {
        Array(Set(allSessions().flatMap(\.tags))).sorted()
    }

    // MARK: Notes

    /// Writes freshly distilled minutes onto the session, replacing any
    /// previous generation.
    func attach(_ distilled: DistilledNote, to session: Session) {
        let actionItems = distilled.actionItems.map { ActionItem(text: $0.text, owner: $0.owner) }
        if let note = session.note {
            note.summary = distilled.summary
            note.keyPoints = distilled.keyPoints
            note.decisions = distilled.decisions
            note.actionItems = actionItems
            note.openQuestions = distilled.openQuestions
            note.userEdited = false
            note.generatedAt = Date()
        } else {
            let note = Note(
                summary: distilled.summary,
                keyPoints: distilled.keyPoints,
                decisions: distilled.decisions,
                actionItems: actionItems,
                openQuestions: distilled.openQuestions
            )
            session.note = note
        }
        save()
    }

    // MARK: Search

    func search(_ query: String) -> [(session: Session, snippet: String)] {
        let sessions = allSessions()
        let hits = SearchRanker.rank(query: query, documents: sessions.map(Self.document(for:)))
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        return hits.compactMap { hit in byID[hit.id].map { ($0, hit.snippet) } }
    }

    /// Context for Ask: the most relevant transcripts, clipped around the
    /// best keyword match so a long session doesn't blow the prompt budget.
    func excerpts(for question: String, limit: Int = 5, maxLength: Int = 4000) -> [SourceExcerpt] {
        let sessions = allSessions()
        let hits = SearchRanker.rank(query: question, documents: sessions.map(Self.document(for:)))
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        return hits.prefix(limit).compactMap { hit in
            guard let session = byID[hit.id] else { return nil }
            var text = session.transcriptText
            if text.count > maxLength {
                let tokens = SearchRanker.tokenize(question)
                text = SearchRanker.snippet(tokens: tokens, in: Self.document(for: session), radius: maxLength / 2)
            }
            if let summary = session.note?.summary, !summary.isEmpty {
                text = "Summary: \(summary)\n\(text)"
            }
            return SourceExcerpt(
                sessionID: session.id,
                title: session.title,
                createdAt: session.createdAt,
                text: text
            )
        }
    }

    static func document(for session: Session) -> SearchDocument {
        let summaryParts = [
            session.note?.summary ?? "",
            session.note?.keyPoints.joined(separator: " ") ?? "",
        ]
        return SearchDocument(
            id: session.id,
            title: session.title,
            body: session.transcriptText,
            summary: summaryParts.joined(separator: " "),
            tags: session.tags,
            createdAt: session.createdAt
        )
    }

    func save() {
        try? context.save()
    }
}
