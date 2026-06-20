//
//  GeminiServiceTests.swift
//  NoteloreTests
//
//  Exercises the `nonisolated static` parsing/error-mapping helpers on
//  GeminiService with inline Gemini REST JSON fixtures. No network.
//

import Foundation
import Testing
@testable import Notelore

@Suite struct GeminiServiceTests {

    // MARK: - Fixture helpers

    /// Wraps an inner model-produced string into a `generateContent`
    /// envelope: `{"candidates":[{"content":{"parts":[{"text":"..."}]}}]}`.
    /// The inner text is JSON-escaped via JSONEncoder so arbitrary content
    /// (quotes, newlines, unicode) is embedded safely.
    private func envelope(innerText: String) -> Data {
        let escaped = encodedJSONString(innerText)
        let json = """
        {"candidates":[{"content":{"parts":[{"text":\(escaped)}]}}]}
        """
        return Data(json.utf8)
    }

    /// Encodes a Swift string as a JSON string literal, e.g. `a"b` -> `"a\"b"`.
    private func encodedJSONString(_ value: String) -> String {
        let data = try! JSONEncoder().encode([value])
        let array = String(decoding: data, as: UTF8.self)
        // ["..."] -> "..."
        let inner = array.dropFirst().dropLast()
        return String(inner)
    }

    // A well-formed DistilledNote payload as the model would emit it.
    private let distilledInnerJSON = """
    {
      "summary": "The team agreed on a launch date. Scope was trimmed to the core flow.",
      "keyPoints": ["Cut onboarding from v1", "Ship dark mode"],
      "decisions": ["Launch on the 30th"],
      "actionItems": [
        {"text": "Draft the release notes", "owner": "Maya"},
        {"text": "File the App Store metadata"}
      ],
      "openQuestions": ["Do we need a TestFlight round?"]
    }
    """

    // MARK: - parseMarginNotes

    @Test func parseMarginNotes_decodesDefinitionsAndQuestions() throws {
        let inner = """
        {"notes":[
          {"headword":"SLO","note":"A service level objective: a target for reliability.","isQuestion":false},
          {"headword":"What's our error budget?","note":"The allowed unreliability before features must pause.","isQuestion":true}
        ]}
        """
        let notes = try GeminiService.parseMarginNotes(from: envelope(innerText: inner))
        #expect(notes.count == 2)
        #expect(notes[0].headword == "SLO")
        #expect(notes[0].isQuestion == false)
        #expect(notes[1].isQuestion == true)
        // Distinct ids are attached on parse.
        #expect(Set(notes.map(\.id)).count == 2)
    }

    @Test func parseMarginNotes_emptyListIsAllowed() throws {
        let notes = try GeminiService.parseMarginNotes(from: envelope(innerText: #"{"notes":[]}"#))
        #expect(notes.isEmpty)
    }

    @Test func parseMarginNotes_dropsBlankEntries() throws {
        let inner = #"{"notes":[{"headword":"  ","note":"x","isQuestion":false},{"headword":"Term","note":"   ","isQuestion":false},{"headword":"Good","note":"A kept note.","isQuestion":false}]}"#
        let notes = try GeminiService.parseMarginNotes(from: envelope(innerText: inner))
        #expect(notes.map(\.headword) == ["Good"])
    }

    @Test func parseMarginNotes_throwsOnBadShape() {
        #expect(throws: (any Error).self) {
            _ = try GeminiService.parseMarginNotes(from: envelope(innerText: #"{"notes":"nope"}"#))
        }
    }

    // MARK: - parseDistilledNote

    @Test func parseDistilledNote_decodesEveryField_andOwnerNilWhenAbsent() throws {
        let data = envelope(innerText: distilledInnerJSON)
        let note = try GeminiService.parseDistilledNote(from: data)

        #expect(note.summary == "The team agreed on a launch date. Scope was trimmed to the core flow.")
        #expect(note.keyPoints == ["Cut onboarding from v1", "Ship dark mode"])
        #expect(note.decisions == ["Launch on the 30th"])
        #expect(note.openQuestions == ["Do we need a TestFlight round?"])

        #expect(note.actionItems.count == 2)
        #expect(note.actionItems[0].text == "Draft the release notes")
        #expect(note.actionItems[0].owner == "Maya")
        #expect(note.actionItems[1].text == "File the App Store metadata")
        #expect(note.actionItems[1].owner == nil)
    }

    @Test func parseDistilledNote_stripsMarkdownCodeFence() throws {
        let fenced = """
        ```json
        \(distilledInnerJSON)
        ```
        """
        let data = envelope(innerText: fenced)
        let note = try GeminiService.parseDistilledNote(from: data)

        #expect(note.summary == "The team agreed on a launch date. Scope was trimmed to the core flow.")
        #expect(note.actionItems.count == 2)
        #expect(note.actionItems[1].owner == nil)
    }

    @Test func parseDistilledNote_emptyCandidatesThrowsUnparseable() {
        let data = Data(#"{"candidates":[]}"#.utf8)
        #expect(throws: LLMError.self) {
            _ = try GeminiService.parseDistilledNote(from: data)
        }
    }

    @Test func parseDistilledNote_missingCandidatesKeyThrows() {
        let data = Data(#"{}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try GeminiService.parseDistilledNote(from: data)
        }
    }

    @Test func parseDistilledNote_nonJSONPartTextThrows() {
        let data = envelope(innerText: "This is not JSON at all, just prose.")
        #expect(throws: LLMError.self) {
            _ = try GeminiService.parseDistilledNote(from: data)
        }
    }

    @Test func parseDistilledNote_unicodeAndMultilineRoundTrip() throws {
        let inner = """
        {
          "summary": "café — déjà vu in the meeting. Line one.\\nLine two follows.",
          "keyPoints": ["naïve façade"],
          "decisions": [],
          "actionItems": [],
          "openQuestions": []
        }
        """
        let data = envelope(innerText: inner)
        let note = try GeminiService.parseDistilledNote(from: data)

        #expect(note.summary == "café — déjà vu in the meeting. Line one.\nLine two follows.")
        #expect(note.keyPoints == ["naïve façade"])
        #expect(note.decisions.isEmpty)
        #expect(note.actionItems.isEmpty)
        #expect(note.openQuestions.isEmpty)
    }

    // MARK: - parsePrepGuide

    @Test func parsePrepGuide_decodesQuestionsAndTalkingPoints() throws {
        let inner = """
        {
          "likelyQuestions": [
            {"question": "Why this role?", "pointsToMake": ["Mission fit", "Past wins"]}
          ],
          "talkingPoints": ["Lead with metrics"]
        }
        """
        let data = envelope(innerText: inner)
        let guide = try GeminiService.parsePrepGuide(from: data)

        #expect(guide.likelyQuestions.count == 1)
        #expect(guide.likelyQuestions[0].question == "Why this role?")
        #expect(guide.likelyQuestions[0].pointsToMake == ["Mission fit", "Past wins"])
        #expect(guide.talkingPoints == ["Lead with metrics"])
    }

    // MARK: - textChunk(fromSSELine:)

    @Test func textChunk_returnsTextForDataLine() {
        let line = #"data: {"candidates":[{"content":{"parts":[{"text":"Hello"}]}}]}"#
        #expect(GeminiService.textChunk(fromSSELine: line) == "Hello")
    }

    @Test func textChunk_concatenatesMultipleParts() {
        let line = #"data: {"candidates":[{"content":{"parts":[{"text":"Hel"},{"text":"lo"}]}}]}"#
        #expect(GeminiService.textChunk(fromSSELine: line) == "Hello")
    }

    @Test func textChunk_emptyStringIsNil() {
        #expect(GeminiService.textChunk(fromSSELine: "") == nil)
    }

    @Test func textChunk_commentLineIsNil() {
        #expect(GeminiService.textChunk(fromSSELine: ": keep-alive") == nil)
    }

    @Test func textChunk_doneSentinelIsNil() {
        #expect(GeminiService.textChunk(fromSSELine: "data: [DONE]") == nil)
    }

    @Test func textChunk_dataLineWithNoTextPartsIsNil() {
        let line = #"data: {"candidates":[{"content":{"parts":[]}}]}"#
        #expect(GeminiService.textChunk(fromSSELine: line) == nil)
    }

    @Test func textChunk_dataLineWithNoCandidatesIsNil() {
        let line = #"data: {"candidates":[]}"#
        #expect(GeminiService.textChunk(fromSSELine: line) == nil)
    }

    // MARK: - mapHTTPError

    @Test func mapHTTPError_429WithRetryDelayReturnsRateLimited() {
        let body = """
        {
          "error": {
            "code": 429,
            "status": "RESOURCE_EXHAUSTED",
            "details": [
              {"@type": "type.googleapis.com/google.rpc.RetryInfo", "retryDelay": "37s"}
            ]
          }
        }
        """
        let result = GeminiService.mapHTTPError(status: 429, data: Data(body.utf8))
        #expect(result == .rateLimited(retryAfterSeconds: 37))
    }

    @Test func mapHTTPError_429WithoutRetryDelayReturnsRateLimitedNil() {
        let body = #"{"error":{"code":429,"status":"RESOURCE_EXHAUSTED"}}"#
        let result = GeminiService.mapHTTPError(status: 429, data: Data(body.utf8))
        #expect(result == .rateLimited(retryAfterSeconds: nil))
    }

    @Test func mapHTTPError_400WithInvalidKeyReturnsInvalidKey() {
        let body = """
        {"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT","details":[{"reason":"API_KEY_INVALID"}]}}
        """
        let result = GeminiService.mapHTTPError(status: 400, data: Data(body.utf8))
        #expect(result == .invalidKey)
    }

    @Test func mapHTTPError_401ReturnsInvalidKey() {
        let result = GeminiService.mapHTTPError(status: 401, data: Data())
        #expect(result == .invalidKey)
    }

    @Test func mapHTTPError_503ReturnsServer() {
        let body = #"{"error":{"code":503,"message":"The model is overloaded.","status":"UNAVAILABLE"}}"#
        let result = GeminiService.mapHTTPError(status: 503, data: Data(body.utf8))
        switch result {
        case let .server(status, message):
            #expect(status == 503)
            #expect(message == "The model is overloaded.")
        default:
            Issue.record("Expected .server, got \(result)")
        }
    }

    @Test func mapHTTPError_genericNon200ReturnsServerWithStatus() {
        let result = GeminiService.mapHTTPError(status: 418, data: Data())
        switch result {
        case let .server(status, _):
            #expect(status == 418)
        default:
            Issue.record("Expected .server, got \(result)")
        }
    }

    // MARK: - retryDelaySeconds (rounds up fractional seconds)

    @Test func retryDelaySeconds_roundsUpFractional() {
        let body = #"{"error":{"details":[{"retryDelay":"12.4s"}]}}"#
        #expect(GeminiService.retryDelaySeconds(in: Data(body.utf8)) == 13)
    }

    @Test func retryDelaySeconds_absentReturnsNil() {
        #expect(GeminiService.retryDelaySeconds(in: Data(#"{}"#.utf8)) == nil)
    }
}
