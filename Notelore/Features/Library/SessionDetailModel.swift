import Foundation
import Observation

/// Drives one session's detail: writing or rewriting its Minutes, toggling
/// action items done, and the small in-place edits to title, tags, and the
/// note's prose. All persistence goes through NotesStore.
@MainActor
@Observable
final class SessionDetailModel {
    let session: Session
    private let services: AppServices

    /// True while distillation is in flight; the view shows "Writing minutes…".
    private(set) var isWriting = false
    /// A calm footnote when writing fails; nil otherwise.
    private(set) var errorText: String?
    /// Whether the Minutes are in hand-edit mode (TextEditors exposed).
    var isEditingMinutes = false

    init(session: Session, services: AppServices) {
        self.session = session
        self.services = services
    }

    /// True when a Gemini key is present, so the view can offer to write.
    var hasKey: Bool {
        services.keychain.apiKey(for: .gemini) != nil
    }

    /// True while the minutes are being written in the background — started
    /// automatically when a recording ends, so a long session can finish
    /// processing after you've left the Record screen.
    var isProcessing: Bool {
        services.processing.isProcessing(session.id)
    }

    /// Generates (or regenerates) the session's Minutes in place.
    func writeMinutes() async {
        guard !isWriting, !isProcessing else { return }
        isWriting = true
        errorText = nil
        defer { isWriting = false }
        do {
            try await services.distiller.distill(session)
            isEditingMinutes = false
        } catch let error as LLMError {
            errorText = error.errorDescription
        } catch {
            errorText = LLMError.server(status: 0, message: "").errorDescription
        }
    }

    /// Flips an action item's done state and persists it. ActionItem is a
    /// value type in an array, so we find by id, mutate, and reassign.
    func toggle(_ item: ActionItem) {
        guard let note = session.note,
              let index = note.actionItems.firstIndex(where: { $0.id == item.id })
        else { return }
        var items = note.actionItems
        items[index].isDone.toggle()
        note.actionItems = items
        services.notesStore.save()
    }

    // MARK: Hand edits to the Minutes

    func saveSummary(_ summary: String) {
        guard let note = session.note else { return }
        note.summary = summary
        markEditedAndSave(note)
    }

    func saveKeyPoints(_ lines: [String]) {
        guard let note = session.note else { return }
        note.keyPoints = lines
        markEditedAndSave(note)
    }

    func saveDecisions(_ lines: [String]) {
        guard let note = session.note else { return }
        note.decisions = lines
        markEditedAndSave(note)
    }

    func saveOpenQuestions(_ lines: [String]) {
        guard let note = session.note else { return }
        note.openQuestions = lines
        markEditedAndSave(note)
    }

    /// Commits every Minutes field at once when the user leaves edit mode.
    func commitEdits(summary: String, keyPoints: [String], decisions: [String], openQuestions: [String]) {
        guard let note = session.note else { return }
        note.summary = summary
        note.keyPoints = keyPoints
        note.decisions = decisions
        note.openQuestions = openQuestions
        markEditedAndSave(note)
        isEditingMinutes = false
    }

    private func markEditedAndSave(_ note: Note) {
        note.userEdited = true
        services.notesStore.save()
    }

    // MARK: Title and tags

    func renameTitle(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != session.title else { return }
        session.title = trimmed
        services.notesStore.save()
    }

    func addTag(_ tag: String) {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !session.tags.contains(trimmed) else { return }
        session.tags.append(trimmed)
        services.notesStore.save()
    }

    func removeTag(_ tag: String) {
        session.tags.removeAll { $0 == tag }
        services.notesStore.save()
    }
}
