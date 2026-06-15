import Foundation
import Observation

/// Drives the Prep screen: turns a pasted job description or meeting agenda
/// into a quiet study guide — the questions likely to come up and the points
/// worth making. Strictly for studying beforehand.
@MainActor
@Observable
final class PrepModel {
    enum Phase: Equatable {
        case idle
        case running
        case finished(PrepGuide)
    }

    /// The pasted job description or agenda.
    var brief: String = ""
    private(set) var phase: Phase = .idle
    private(set) var error: LLMError?

    private let services: AppServices
    private var generation: Task<Void, Never>?

    init(services: AppServices) {
        self.services = services
    }

    var trimmedBrief: String {
        brief.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isRunning: Bool { phase == .running }

    var canPrepare: Bool { !trimmedBrief.isEmpty && !isRunning }

    var guide: PrepGuide? {
        if case .finished(let guide) = phase { return guide }
        return nil
    }

    /// The epigraph shows before anything has been drafted.
    var showsEmptyState: Bool { phase == .idle && error == nil }

    func prepare() {
        guard canPrepare else { return }
        error = nil
        guard services.keychain.apiKey(for: .gemini) != nil else {
            error = .missingKey
            return
        }
        let brief = trimmedBrief
        phase = .running
        generation?.cancel()
        generation = Task { [weak self] in
            guard let self else { return }
            do {
                let guide = try await self.services.llm.prepGuide(from: brief)
                guard !Task.isCancelled else { return }
                self.phase = .finished(guide)
            } catch let llmError as LLMError {
                guard !Task.isCancelled else { return }
                self.error = llmError
                self.phase = .idle
            } catch {
                guard !Task.isCancelled else { return }
                if !(error is CancellationError) {
                    self.error = .server(status: 0, message: error.localizedDescription)
                }
                self.phase = .idle
            }
        }
    }

    func startOver() {
        generation?.cancel()
        generation = nil
        brief = ""
        error = nil
        phase = .idle
    }

    /// A Markdown rendering of the guide for export via ShareLink.
    nonisolated static func markdown(for guide: PrepGuide, brief: String) -> String {
        var lines: [String] = ["# Prep notes", ""]

        let trimmed = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstLine = trimmed
            .components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        {
            let shortened = firstLine.count > 120
                ? String(firstLine.prefix(120)) + "…"
                : firstLine
            lines.append("> \(shortened)")
            lines.append("")
        }

        lines.append("## Likely questions")
        lines.append("")
        for item in guide.likelyQuestions {
            lines.append("### \(item.question)")
            lines.append("")
            for point in item.pointsToMake {
                lines.append("- \(point)")
            }
            lines.append("")
        }

        lines.append("## Talking points")
        lines.append("")
        for point in guide.talkingPoints {
            lines.append("- \(point)")
        }

        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}
