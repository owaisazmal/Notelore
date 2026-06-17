import Foundation
import SwiftData

/// A saved Prep study guide, kept so earlier preparations can be reread.
@Model
final class PrepEntry {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    /// The brief the guide was drafted from.
    var brief: String
    /// A short heading derived from the brief, for the history list.
    var title: String
    var likelyQuestions: [PrepItem]
    var talkingPoints: [String]

    init(brief: String, guide: PrepGuide, createdAt: Date = Date()) {
        self.id = UUID()
        self.createdAt = createdAt
        self.brief = brief
        self.title = PrepEntry.makeTitle(from: brief)
        self.likelyQuestions = guide.likelyQuestions
        self.talkingPoints = guide.talkingPoints
    }

    var guide: PrepGuide {
        PrepGuide(likelyQuestions: likelyQuestions, talkingPoints: talkingPoints)
    }

    /// The first non-empty line of the brief, clipped — what the history row shows.
    static func makeTitle(from brief: String) -> String {
        let firstLine = brief
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? "Untitled brief"
        return firstLine.count > 80 ? String(firstLine.prefix(80)) + "…" : firstLine
    }
}
