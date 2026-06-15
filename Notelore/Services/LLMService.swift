import Foundation

/// Identity of a language-model backend. Only Gemini ships in v1; the
/// protocol below exists so an Anthropic or OpenAI provider can be added
/// without touching any feature code.
enum LLMProviderID: String, CaseIterable, Codable, Sendable {
    case gemini

    var displayName: String {
        switch self {
        case .gemini: return "Google Gemini"
        }
    }
}

/// Structured minutes distilled from one session's transcript.
struct DistilledNote: Codable, Equatable, Sendable {
    /// Exactly two sentences.
    var summary: String
    var keyPoints: [String]
    var decisions: [String]
    var actionItems: [DistilledActionItem]
    var openQuestions: [String]
}

struct DistilledActionItem: Codable, Equatable, Sendable {
    var text: String
    /// Only set when a name was actually mentioned.
    var owner: String?
}

/// A retrieved transcript excerpt handed to the model as context for Ask.
/// Which sessions an answer drew from is decided by retrieval, not the model.
struct SourceExcerpt: Equatable, Sendable {
    let sessionID: UUID
    let title: String
    let createdAt: Date
    let text: String
}

/// One likely question with the points worth making — for studying
/// beforehand, never for live use.
struct PrepItem: Codable, Equatable, Sendable {
    var question: String
    var pointsToMake: [String]
}

struct PrepGuide: Codable, Equatable, Sendable {
    var likelyQuestions: [PrepItem]
    var talkingPoints: [String]
}

/// Errors surfaced to the UI in the app's calm editorial voice.
enum LLMError: LocalizedError, Equatable {
    case missingKey
    case invalidKey
    case rateLimited(retryAfterSeconds: Int?)
    case offline
    case server(status: Int, message: String)
    case unparseableResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "Add your key in Settings to have minutes written for you."
        case .invalidKey:
            return "That key wasn't accepted. You can check it in Settings."
        case .rateLimited(let seconds):
            if let seconds {
                return "The service is busy. Try again in about \(seconds) seconds."
            }
            return "The service is busy. Give it a moment, then try again."
        case .offline:
            return "You're offline. Recordings and transcripts still work; minutes can wait until you're connected."
        case .server:
            return "The service had trouble answering. Try again shortly."
        case .unparseableResponse:
            return "The reply couldn't be read. Try regenerating."
        }
    }
}

/// A language-model backend. Conformers must never log the API key.
@MainActor
protocol LLMService: AnyObject {
    /// A cheap call proving the key works. Throws LLMError on failure.
    func validateKey(_ key: String) async throws
    /// Structured minutes from a transcript.
    func distill(transcript: String) async throws -> DistilledNote
    /// Streams the answer text as it is generated.
    func answer(question: String, excerpts: [SourceExcerpt]) -> AsyncThrowingStream<String, Error>
    /// A study guide from a pasted job description or agenda. Preparation
    /// and practice beforehand only.
    func prepGuide(from brief: String) async throws -> PrepGuide
}
