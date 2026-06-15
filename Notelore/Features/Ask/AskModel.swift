import Foundation
import Observation

/// Drives "Ask the lore": one question at a time, answered from the user's
/// own notes. No chat history — each ask replaces the last.
@MainActor
@Observable
final class AskModel {
    enum Phase: Equatable {
        /// Nothing asked yet, or a guard stopped the ask before it began.
        case idle
        /// Retrieval found nothing relevant; no network call was made.
        case nothingRelevant
        /// Waiting on the first chunk of the answer.
        case consulting
        /// Chunks are arriving.
        case streaming
        /// The answer completed (possibly cut short by an error).
        case finished
        /// The ask failed before any answer text arrived.
        case failed
    }

    private let services: AppServices

    var question = ""
    private(set) var answer = ""
    private(set) var phase: Phase = .idle
    private(set) var errorText: String?
    /// True when the error calls for the user to act (missing or invalid key).
    private(set) var errorNeedsAction = false
    /// Sessions the finished answer drew from, in retrieval order.
    private(set) var sources: [Session] = []
    private(set) var hasSessions = false
    private(set) var hasKey = false

    private var askTask: Task<Void, Never>?

    init(services: AppServices) {
        self.services = services
    }

    var isStreaming: Bool {
        phase == .consulting || phase == .streaming
    }

    var canAsk: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isStreaming
    }

    /// Re-reads the cheap environment checks. Called when the screen appears
    /// and before every ask, so returning from Settings or Record is seen.
    func refresh() {
        hasSessions = !services.notesStore.allSessions().isEmpty
        hasKey = services.keychain.apiKey(for: .gemini) != nil
    }

    func ask() {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // A new ask supersedes the one in flight.
        askTask?.cancel()
        askTask = nil

        refresh()
        answer = ""
        errorText = nil
        errorNeedsAction = false
        sources = []

        // Guards, in order: the view renders the matching state.
        guard hasSessions else {
            phase = .idle
            return
        }
        guard hasKey else {
            phase = .idle
            return
        }
        let excerpts = services.notesStore.excerpts(for: trimmed)
        guard !excerpts.isEmpty else {
            phase = .nothingRelevant
            return
        }

        phase = .consulting
        let stream = services.llm.answer(question: trimmed, excerpts: excerpts)
        askTask = Task { [weak self] in
            do {
                for try await chunk in stream {
                    guard let self, !Task.isCancelled else { return }
                    self.answer += chunk
                    self.phase = .streaming
                }
                guard let self, !Task.isCancelled else { return }
                self.phase = .finished
                self.sources = self.resolveSessions(for: excerpts)
            } catch is CancellationError {
                // Superseded by a newer ask; say nothing.
            } catch let error as LLMError {
                guard let self, !Task.isCancelled else { return }
                self.errorText = error.errorDescription
                self.errorNeedsAction = error == .missingKey || error == .invalidKey
                self.phase = self.answer.isEmpty ? .failed : .finished
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.errorText = LLMError.server(status: 0, message: "").errorDescription
                self.phase = self.answer.isEmpty ? .failed : .finished
            }
        }
    }

    /// Maps the used excerpts back onto live sessions, in order, skipping
    /// any that have since been deleted and never repeating a session.
    private func resolveSessions(for excerpts: [SourceExcerpt]) -> [Session] {
        let sessions = services.notesStore.allSessions()
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        var seen = Set<UUID>()
        return excerpts.compactMap { excerpt in
            guard seen.insert(excerpt.sessionID).inserted else { return nil }
            return byID[excerpt.sessionID]
        }
    }
}
