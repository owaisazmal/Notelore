import Foundation
import Observation

/// Runs minutes distillation in the background, off the recording flow, so
/// ending a long session returns to the UI immediately. It outlives the Record
/// screen (it belongs to AppServices), so switching tabs or starting another
/// recording never cancels an in-flight distillation. The session's audio and
/// transcript are already saved before this runs — only the minutes are pending.
@MainActor
@Observable
final class ProcessingCoordinator {
    /// Sessions whose minutes are currently being written.
    private(set) var processingIDs: Set<UUID> = []

    private let distiller: Distiller

    init(distiller: Distiller) {
        self.distiller = distiller
    }

    func isProcessing(_ id: UUID) -> Bool {
        processingIDs.contains(id)
    }

    /// Begins writing the session's minutes in the background. A no-op if that
    /// session is already being processed. On failure the session simply keeps
    /// no minutes — it can be written by hand later from the Library.
    func distill(_ session: Session) {
        let id = session.id
        guard !processingIDs.contains(id) else { return }
        processingIDs.insert(id)
        Task { @MainActor in
            do {
                try await distiller.distill(session)
            } catch {
                // Best-effort: leave the minutes unwritten; the Library detail
                // offers a manual "Write minutes" once processing ends.
            }
            processingIDs.remove(id)
        }
    }
}
