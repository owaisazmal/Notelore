import Foundation

/// Turns a finished session's transcript into its Minutes (a Note).
@MainActor
final class Distiller {
    private let llm: any LLMService
    private let store: NotesStore

    init(llm: any LLMService, store: NotesStore) {
        self.llm = llm
        self.store = store
    }

    /// Generates (or regenerates) the session's note in place.
    /// Throws LLMError; the recording and transcript are never touched.
    func distill(_ session: Session) async throws {
        let transcript = Self.transcriptText(for: session)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.unparseableResponse("Transcript is empty.")
        }
        let distilled = try await llm.distill(transcript: transcript)
        store.attach(distilled, to: session)
    }

    /// The transcript as timestamped manuscript lines, e.g. "[03:24] …".
    static func transcriptText(for session: Session) -> String {
        session.transcript
            .map { "[\(timestamp($0.start))] \($0.text)" }
            .joined(separator: "\n")
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}
