import Foundation

/// Renders a session as a Markdown document for export, and owns the small
/// shared date/duration formatting the Library uses. Pure formatting — no
/// UI, no persistence.
enum NoteMarkdown {
    /// "# Title", a date line, the note's sections (empty ones omitted),
    /// ending with the timestamped transcript.
    static func markdown(for session: Session) -> String {
        var blocks: [String] = []
        blocks.append("# \(session.title)")
        blocks.append("\(mediumDate(session.createdAt)) · \(durationText(session.duration))")

        if let note = session.note {
            if !note.summary.isEmpty {
                blocks.append("## Summary\n\n\(note.summary)")
            }
            if !note.keyPoints.isEmpty {
                blocks.append("## Key points\n\n" + bullets(note.keyPoints))
            }
            if !note.decisions.isEmpty {
                blocks.append("## Decisions\n\n" + bullets(note.decisions))
            }
            if !note.actionItems.isEmpty {
                let lines = note.actionItems.map { item -> String in
                    var line = "- [\(item.isDone ? "x" : " ")] \(item.text)"
                    if let owner = item.owner, !owner.isEmpty {
                        line += " — \(owner)"
                    }
                    return line
                }
                blocks.append("## Action items\n\n" + lines.joined(separator: "\n"))
            }
            if !note.openQuestions.isEmpty {
                blocks.append("## Open questions\n\n" + bullets(note.openQuestions))
            }
        }

        if !session.transcript.isEmpty {
            let lines = session.transcript.map {
                "[\(Distiller.timestamp($0.start))] \($0.text)"
            }
            blocks.append("## Transcript\n\n" + lines.joined(separator: "\n"))
        }

        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// Medium date, e.g. "Jun 12, 2026".
    static func mediumDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    /// Whole minutes, e.g. "24 min"; anything under a minute reads "1 min".
    static func durationText(_ seconds: TimeInterval) -> String {
        guard seconds >= 1 else { return "0 min" }
        return "\(max(1, Int(seconds / 60))) min"
    }

    private static func bullets(_ items: [String]) -> String {
        items.map { "- \($0)" }.joined(separator: "\n")
    }
}
