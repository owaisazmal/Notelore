import Foundation
import SwiftData

/// One spoken utterance with timestamps (seconds from the start of the
/// recording). Speaker-agnostic by design.
struct Utterance: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

/// An action item inside a Note. `owner` is only set when a name was
/// actually mentioned in the conversation.
struct ActionItem: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var text: String
    var owner: String?
    var isDone: Bool = false
}

/// A recorded sitting: audio, transcript, and (once distilled) its Note.
@Model
final class Session {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    /// Seconds of audio captured.
    var duration: TimeInterval
    /// File name inside AudioStorage.directory(); nil if the file is gone.
    var audioFileName: String?
    var transcript: [Utterance]
    /// Denormalized plain text of the transcript, kept in sync for search.
    var transcriptText: String
    var tags: [String]
    /// BCP-47 code the transcription ran in, e.g. "en-US".
    var languageCode: String?
    @Relationship(deleteRule: .cascade, inverse: \Note.session)
    var note: Note?

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        duration: TimeInterval = 0,
        audioFileName: String? = nil,
        transcript: [Utterance] = [],
        tags: [String] = [],
        languageCode: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.audioFileName = audioFileName
        self.transcript = transcript
        self.transcriptText = transcript.map(\.text).joined(separator: " ")
        self.tags = tags
        self.languageCode = languageCode
    }
}

/// The distilled "Minutes" of a session, plus any edits the user makes.
@Model
final class Note {
    var summary: String
    var keyPoints: [String]
    var decisions: [String]
    var actionItems: [ActionItem]
    var openQuestions: [String]
    /// True once the user has edited the generated text by hand.
    var userEdited: Bool
    var generatedAt: Date
    var session: Session?

    init(
        summary: String,
        keyPoints: [String] = [],
        decisions: [String] = [],
        actionItems: [ActionItem] = [],
        openQuestions: [String] = [],
        userEdited: Bool = false,
        generatedAt: Date = Date()
    ) {
        self.summary = summary
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.userEdited = userEdited
        self.generatedAt = generatedAt
    }
}
