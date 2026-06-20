import Foundation
import os

/// The concrete `LLMService` speaking to the Gemini REST API with the
/// user's own key (bring-your-own-key, BYOK).
///
/// The key travels exclusively in the `x-goog-api-key` header — never in
/// the URL, never in logs, never echoed into error messages. All parsing
/// helpers are `nonisolated static` so unit tests can call them directly.
@MainActor
final class GeminiService: LLMService {

    /// Diagnostics only — request shape and failures. The API key and the
    /// transcript text are never logged; only sizes, models, and Google's own
    /// short error text reach the log.
    private nonisolated static let log = Logger(subsystem: "com.owaiskhan.notelore", category: "gemini")

    private nonisolated static let baseURLString = "https://generativelanguage.googleapis.com/v1beta"
    /// A fast model for the live margin-notes overlay, independent of the
    /// minutes-quality model chosen in Settings — latency matters most here.
    private nonisolated static let liveModel = "gemini-2.5-flash-lite"

    private let keychain: KeychainStore
    private let settings: AppSettings
    private let session: URLSession

    init(keychain: KeychainStore, settings: AppSettings, session: URLSession = .shared) {
        self.keychain = keychain
        self.settings = settings
        self.session = session
    }

    // MARK: - LLMService

    func validateKey(_ key: String) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        // Validate with the very request the features use — a generateContent
        // call on the selected model — so a key that "validates" is guaranteed
        // to work for Minutes, Ask, and Prep. Listing models can succeed for a
        // key (or model) that still can't generate, which would mislead the
        // user with a false "accepted".
        let body = RequestBody(
            systemInstruction: nil,
            contents: [RequestContent(role: "user", parts: [RequestPart(text: "Hi")])],
            generationConfig: GenerationConfig(maxOutputTokens: 1)
        )
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(body)
        } catch {
            throw LLMError.server(status: -1, message: "The request could not be encoded.")
        }
        let request = try Self.makeRequest(
            path: "/models/\(settings.geminiModel):generateContent",
            key: trimmed,
            jsonBody: encoded
        )
        _ = try await perform(request)
    }

    func distill(transcript: String) async throws -> DistilledNote {
        let data = try await generate(
            systemInstruction: Self.distillInstruction,
            userText: transcript,
            schema: Self.distilledNoteSchema
        )
        return try Self.parseDistilledNote(from: data)
    }

    func answer(question: String, excerpts: [SourceExcerpt]) -> AsyncThrowingStream<String, Error> {
        guard let key = keychain.apiKey(for: .gemini) else {
            return AsyncThrowingStream { $0.finish(throwing: LLMError.missingKey) }
        }
        let request: URLRequest
        do {
            let body = RequestBody(
                systemInstruction: RequestContent(parts: [RequestPart(text: Self.answerInstruction)]),
                contents: [
                    RequestContent(
                        role: "user",
                        parts: [RequestPart(text: Self.answerPrompt(question: question, excerpts: excerpts))]
                    )
                ],
                generationConfig: nil
            )
            request = try Self.makeRequest(
                path: "/models/\(settings.geminiModel):streamGenerateContent",
                query: "alt=sse",
                key: key,
                jsonBody: JSONEncoder().encode(body),
                timeout: 120
            )
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: Self.mapTransportError(error)) }
        }
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for attempt in 0..<2 {
                        let (bytes, response) = try await session.bytes(for: request)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                        if status == 200 {
                            for try await line in bytes.lines {
                                if Task.isCancelled { break }
                                if let chunk = Self.textChunk(fromSSELine: line) {
                                    continuation.yield(chunk)
                                }
                            }
                            continuation.finish()
                            return
                        }
                        var body = Data()
                        for try await byte in bytes { body.append(byte) }
                        let mapped = Self.mapHTTPError(status: status, data: body)
                        // Absorb one brief rate limit before answering; surface
                        // longer waits and every other failure.
                        if attempt == 0, case let .rateLimited(retry) = mapped,
                           TimeInterval(retry ?? 3) <= 12 {
                            try await Task.sleep(for: .seconds(TimeInterval(retry ?? 3)))
                            continue
                        }
                        throw mapped
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapTransportError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func prepGuide(from brief: String) async throws -> PrepGuide {
        let data = try await generate(
            systemInstruction: Self.prepInstruction,
            userText: brief,
            schema: Self.prepGuideSchema
        )
        return try Self.parsePrepGuide(from: data)
    }

    func marginNotes(forTranscript transcript: String, covered: [String]) async throws -> [MarginNote] {
        let coveredList = covered.isEmpty ? "(none)" : covered.joined(separator: ", ")
        let userText = "Already noted: \(coveredList)\n\nRecent passage:\n\(transcript)"
        // Live overlay: a fast model, a short timeout, and no retry — a missed
        // cycle just refreshes on the next one rather than stalling.
        let data = try await generate(
            systemInstruction: Self.marginNotesInstruction,
            userText: userText,
            schema: Self.marginNotesSchema,
            model: Self.liveModel,
            timeout: 15,
            retry: false
        )
        return try Self.parseMarginNotes(from: data)
    }

    // MARK: - Requests

    /// JSON-mode `generateContent` call shared by `distill` and `prepGuide`.
    private func generate(
        systemInstruction: String,
        userText: String,
        schema: Schema,
        model: String? = nil,
        timeout: TimeInterval = 120,
        retry: Bool = true
    ) async throws -> Data {
        guard let key = keychain.apiKey(for: .gemini) else { throw LLMError.missingKey }
        let body = RequestBody(
            systemInstruction: RequestContent(parts: [RequestPart(text: systemInstruction)]),
            contents: [RequestContent(role: "user", parts: [RequestPart(text: userText)])],
            generationConfig: GenerationConfig(
                responseMimeType: "application/json",
                responseSchema: schema
            )
        )
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(body)
        } catch {
            throw LLMError.server(status: -1, message: "The request could not be encoded.")
        }
        // The default 120 s timeout suits Minutes/Prep, where the first call
        // can be slow while the model warms up; the live overlay overrides it.
        let request = try Self.makeRequest(
            path: "/models/\(model ?? settings.geminiModel):generateContent",
            key: key,
            jsonBody: encoded,
            timeout: timeout
        )
        // Log the request shape for the user-triggered calls (Minutes/Prep);
        // the live overlay passes an explicit `model` and stays quiet to avoid
        // spamming the log every few seconds.
        let chosenModel = model ?? settings.geminiModel
        if model == nil {
            Self.log.notice("generate: model \(chosenModel, privacy: .public), input \(userText.count) chars")
        }
        let data = retry ? try await performWithRetry(request) : try await perform(request)
        if let reason = Self.finishReason(in: data), reason != "STOP" {
            // MAX_TOKENS, SAFETY, RECITATION, etc. — the body may be truncated
            // or empty, which then shows up as an unreadable reply downstream.
            Self.log.error("generate: model \(chosenModel, privacy: .public) finished abnormally: \(reason, privacy: .public)")
        }
        return data
    }

    /// Runs a request, transparently retrying once on a transient failure (a
    /// timeout or a 5xx) — this is what made the *first* Prep/Minutes call of a
    /// session fail and the next one succeed. Deterministic errors (invalid
    /// key, bad response) are surfaced immediately, not retried.
    private func performWithRetry(_ request: URLRequest, attempts: Int = 3) async throws -> Data {
        var lastError: LLMError = .server(status: -1, message: "")
        for attempt in 0..<attempts {
            do {
                return try await perform(request)
            } catch let error as LLMError {
                lastError = error
                guard attempt < attempts - 1 else { throw error }
                if case let .rateLimited(retry) = error {
                    // Absorb a *brief* rate limit by waiting the suggested delay
                    // and trying again; surface longer ones to the user.
                    let wait = TimeInterval(retry ?? 3)
                    guard wait <= 12 else { throw error }
                    try? await Task.sleep(for: .seconds(wait))
                } else if case let .server(status, _) = error, status >= 500 {
                    // Transient overload (503) or server error: these come back
                    // fast, so ride them out with a short escalating back-off
                    // (1 s, then 2 s) rather than making the user retry by hand.
                    Self.log.notice("retrying after HTTP \(status, privacy: .public) (attempt \(attempt + 1, privacy: .public))")
                    try? await Task.sleep(for: .seconds(TimeInterval(1 << attempt)))
                } else if Self.isRetryable(error) {
                    // Timeout / dropped connection: each attempt is slow, so try
                    // just once more before surfacing it.
                    guard attempt == 0 else { throw error }
                    try? await Task.sleep(for: .seconds(1))
                } else {
                    throw error
                }
            }
        }
        throw lastError
    }

    /// Transient failures worth one automatic retry: connection/timeout
    /// (status -1 from the transport) and server-side 5xx.
    private nonisolated static func isRetryable(_ error: LLMError) -> Bool {
        if case let .server(status, _) = error {
            return status == -1 || status >= 500
        }
        return false
    }

    /// Runs a non-streaming request, mapping every failure to `LLMError`.
    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // Timeout / lost connection / offline — the transport never reached
            // a status code. Surfaced as `.server(status: -1, …)` or `.offline`.
            Self.log.error("request transport failure: \(error.localizedDescription, privacy: .public)")
            throw Self.mapTransportError(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            // The single most useful line for diagnosing "trouble answering":
            // the real HTTP status and Google's own error text (never the key).
            let message = Self.shortErrorMessage(in: data)
            Self.log.error("request failed: HTTP \(status, privacy: .public) — \(message.isEmpty ? "(no message)" : message, privacy: .public)")
            throw Self.mapHTTPError(status: status, data: data)
        }
        return data
    }

    /// Builds a request against the v1beta base. GET when `jsonBody` is nil,
    /// POST otherwise. The key goes only into the `x-goog-api-key` header.
    private nonisolated static func makeRequest(
        path: String,
        query: String? = nil,
        key: String,
        jsonBody: Data? = nil,
        timeout: TimeInterval = 60
    ) throws -> URLRequest {
        var urlString = baseURLString + path
        if let query { urlString += "?" + query }
        guard let url = URL(string: urlString) else {
            throw LLMError.server(status: -1, message: "The request URL could not be formed.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = jsonBody == nil ? "GET" : "POST"
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonBody
        }
        return request
    }

    // MARK: - Prompts

    private nonisolated static let distillInstruction = """
        You are a careful editor distilling a conversation transcript into meeting minutes.
        Respond in the same language the transcript is written in.
        Write "summary" as exactly two sentences.
        List the key points, the decisions that were made, and the questions left open, \
        each as one short plain sentence.
        List the action items as they were stated. Set "owner" only when a person's name \
        is explicitly mentioned for that item; otherwise leave owner null.
        Never invent names, facts, dates, or commitments that are not present in the \
        transcript. If a section has nothing, return an empty array for it.
        """

    private nonisolated static let answerInstruction = """
        You answer questions using only the notes provided in the message.
        If the notes do not contain the answer, say so plainly and briefly.
        Do not add citations, source markers, or references to sessions in the answer; \
        the app shows sources separately.
        Answer in the same language the question is asked in, in a calm, plain voice.
        """

    private nonisolated static let prepInstruction = """
        You help someone study and rehearse on their own, ahead of time, before a \
        meeting, presentation, or conversation takes place.
        Given a pasted job description, agenda, or brief, draft the questions most \
        likely to come up and, for each, the strongest points worth making, plus a \
        short list of general talking points worth practicing beforehand.
        This is a study guide for preparation in advance only.
        Respond in the same language the brief is written in.
        Keep every question and point short, concrete, and grounded in the brief; \
        never invent facts the brief does not support.
        """

    private nonisolated static let marginNotesInstruction = """
        You annotate the transcript of a live conversation or talk with short \
        "margin notes" that help the reader follow and remember it.
        Produce two kinds of notes:
        1. Definitions — for meaningful, technical, or potentially unfamiliar \
        terms, jargon, acronyms, names, places, or concepts that appear, give a \
        one- or two-sentence plain definition. Put the term in "headword" and \
        set isQuestion to false.
        2. Answers — for a genuine question of fact or general knowledge raised \
        in the discussion, give a brief, neutral answer or the relevant \
        background in one or two sentences. Put the question in "headword" and \
        set isQuestion to true.
        Only include notes genuinely useful for understanding the content. Never \
        repeat anything in the "already noted" list. Skip small talk, filler, \
        and obvious everyday words.
        You are a neutral reference in the margin: never tell anyone what to say, \
        how to respond, what to do, how to negotiate, or how to handle the \
        conversation; give no advice and take no side. Notes describe the \
        content only.
        Respond in the language of the transcript. If nothing new is worth \
        noting, return an empty list.
        """

    /// One user turn: each excerpt labeled with its session, then the question.
    nonisolated static func answerPrompt(question: String, excerpts: [SourceExcerpt]) -> String {
        var lines: [String] = []
        for excerpt in excerpts {
            let date = excerpt.createdAt.formatted(date: .abbreviated, time: .omitted)
            lines.append("[Session: \(excerpt.title) — \(date)]")
            lines.append(excerpt.text)
            lines.append("")
        }
        lines.append(question)
        return lines.joined(separator: "\n")
    }

    // MARK: - Response schemas (Gemini OpenAPI subset)

    private nonisolated static let distilledNoteSchema = Schema(
        type: "OBJECT",
        properties: [
            "summary": Schema(type: "STRING"),
            "keyPoints": Schema(type: "ARRAY", items: Schema(type: "STRING")),
            "decisions": Schema(type: "ARRAY", items: Schema(type: "STRING")),
            "actionItems": Schema(
                type: "ARRAY",
                items: Schema(
                    type: "OBJECT",
                    properties: [
                        "text": Schema(type: "STRING"),
                        "owner": Schema(type: "STRING", nullable: true),
                    ],
                    required: ["text"]
                )
            ),
            "openQuestions": Schema(type: "ARRAY", items: Schema(type: "STRING")),
        ],
        required: ["summary", "keyPoints", "decisions", "actionItems", "openQuestions"]
    )

    private nonisolated static let prepGuideSchema = Schema(
        type: "OBJECT",
        properties: [
            "likelyQuestions": Schema(
                type: "ARRAY",
                items: Schema(
                    type: "OBJECT",
                    properties: [
                        "question": Schema(type: "STRING"),
                        "pointsToMake": Schema(type: "ARRAY", items: Schema(type: "STRING")),
                    ],
                    required: ["question", "pointsToMake"]
                )
            ),
            "talkingPoints": Schema(type: "ARRAY", items: Schema(type: "STRING")),
        ],
        required: ["likelyQuestions", "talkingPoints"]
    )

    private nonisolated static let marginNotesSchema = Schema(
        type: "OBJECT",
        properties: [
            "notes": Schema(
                type: "ARRAY",
                items: Schema(
                    type: "OBJECT",
                    properties: [
                        "headword": Schema(type: "STRING"),
                        "note": Schema(type: "STRING"),
                        "isQuestion": Schema(type: "BOOLEAN"),
                    ],
                    required: ["headword", "note", "isQuestion"]
                )
            ),
        ],
        required: ["notes"]
    )

    // MARK: - Parsing (nonisolated; unit tests call these directly)

    /// Digs `candidates[0].content.parts[0].text` out of a `generateContent`
    /// response, strips markdown code fences, and decodes `DistilledNote`.
    /// Throws `LLMError.unparseableResponse` with a short reason on any shape
    /// problem; transcript content is never echoed into errors.
    nonisolated static func parseDistilledNote(from data: Data) throws -> DistilledNote {
        let payload = try innerJSONData(from: data)
        do {
            return try JSONDecoder().decode(DistilledNote.self, from: payload)
        } catch {
            throw LLMError.unparseableResponse("The minutes did not match the expected shape.")
        }
    }

    nonisolated static func parsePrepGuide(from data: Data) throws -> PrepGuide {
        let payload = try innerJSONData(from: data)
        do {
            return try JSONDecoder().decode(PrepGuide.self, from: payload)
        } catch {
            throw LLMError.unparseableResponse("The guide did not match the expected shape.")
        }
    }

    nonisolated static func parseMarginNotes(from data: Data) throws -> [MarginNote] {
        struct Wrapper: Decodable { var notes: [MarginNoteData] }
        let payload = try innerJSONData(from: data)
        do {
            let wrapper = try JSONDecoder().decode(Wrapper.self, from: payload)
            return wrapper.notes
                .filter {
                    !$0.headword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && !$0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                .map { MarginNote(headword: $0.headword, note: $0.note, isQuestion: $0.isQuestion) }
        } catch {
            throw LLMError.unparseableResponse("The notes did not match the expected shape.")
        }
    }

    /// The model's JSON, extracted from the response envelope and re-encoded
    /// as UTF-8 data ready for a second decode.
    private nonisolated static func innerJSONData(from data: Data) throws -> Data {
        guard let envelope = try? JSONDecoder().decode(ResponseEnvelope.self, from: data) else {
            throw LLMError.unparseableResponse("The response envelope could not be read.")
        }
        guard let text = envelope.candidates?.first?.content?.parts?.first?.text,
              !text.isEmpty
        else {
            throw LLMError.unparseableResponse("The response contained no text.")
        }
        let stripped = stripCodeFences(from: text)
        guard !stripped.isEmpty, let payload = stripped.data(using: .utf8) else {
            throw LLMError.unparseableResponse("The response text was empty.")
        }
        return payload
    }

    /// Removes a surrounding markdown code fence (``` or ```json) if present.
    nonisolated static func stripCodeFences(from text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        if let firstNewline = trimmed.firstIndex(of: "\n") {
            trimmed = String(trimmed[trimmed.index(after: firstNewline)...])
        } else {
            trimmed = ""
        }
        if trimmed.hasSuffix("```") {
            trimmed = String(trimmed.dropLast(3))
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parses one server-sent-events line. Returns the concatenated parts
    /// text for a `data: {json}` line; nil for keep-alives, comments, empty
    /// lines, `data: [DONE]`, and chunks carrying no text.
    nonisolated static func textChunk(fromSSELine line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]" else { return nil }
        guard let data = payload.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(ResponseEnvelope.self, from: data)
        else { return nil }
        let text = (envelope.candidates?.first?.content?.parts ?? [])
            .compactMap(\.text)
            .joined()
        return text.isEmpty ? nil : text
    }

    // MARK: - Error mapping

    /// Maps a non-200 HTTP response to `LLMError`. The body is inspected for
    /// Google's error envelope; the API key is never part of any output.
    nonisolated static func mapHTTPError(status: Int, data: Data) -> LLMError {
        if status == 429 {
            return .rateLimited(retryAfterSeconds: retryDelaySeconds(in: data))
        }
        if status == 401 || status == 403 {
            return .invalidKey
        }
        if status == 400 {
            let body = String(decoding: data, as: UTF8.self)
            if body.contains("API_KEY_INVALID") || body.contains("API key not valid") {
                return .invalidKey
            }
        }
        return .server(status: status, message: shortErrorMessage(in: data))
    }

    /// Finds a RetryInfo delay like `"retryDelay": "37s"` anywhere in the body.
    nonisolated static func retryDelaySeconds(in data: Data) -> Int? {
        let body = String(decoding: data, as: UTF8.self)
        let pattern = #""retryDelay"\s*:\s*"([0-9]+(?:\.[0-9]+)?)s""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: body),
              let seconds = Double(body[range])
        else { return nil }
        return Int(seconds.rounded(.up))
    }

    /// The short `error.message` from Google's error envelope, if parseable.
    private nonisolated static func shortErrorMessage(in data: Data) -> String {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(ErrorEnvelope.self, from: data),
           let message = envelope.error?.message {
            return String(message.prefix(200))
        }
        if let envelopes = try? decoder.decode([ErrorEnvelope].self, from: data),
           let message = envelopes.compactMap({ $0.error?.message }).first {
            return String(message.prefix(200))
        }
        return ""
    }

    /// The `finishReason` of the first candidate, if the response carried one.
    /// "STOP" is the healthy case; "MAX_TOKENS"/"SAFETY"/"RECITATION" mean the
    /// reply was cut short or withheld, which is worth logging.
    private nonisolated static func finishReason(in data: Data) -> String? {
        guard let envelope = try? JSONDecoder().decode(ResponseEnvelope.self, from: data) else {
            return nil
        }
        return envelope.candidates?.first?.finishReason
    }

    /// Maps transport-layer failures to `LLMError`; `LLMError` passes through.
    nonisolated static func mapTransportError(_ error: Error) -> LLMError {
        if let llmError = error as? LLMError { return llmError }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return .offline
            default:
                return .server(status: -1, message: urlError.localizedDescription)
            }
        }
        return .server(status: -1, message: "The connection failed.")
    }

    // MARK: - Wire types

    private nonisolated struct RequestBody: Encodable {
        var systemInstruction: RequestContent?
        var contents: [RequestContent]
        var generationConfig: GenerationConfig?
    }

    private nonisolated struct RequestContent: Encodable {
        var role: String?
        var parts: [RequestPart]

        init(role: String? = nil, parts: [RequestPart]) {
            self.role = role
            self.parts = parts
        }
    }

    private nonisolated struct RequestPart: Encodable {
        var text: String
    }

    private nonisolated struct GenerationConfig: Encodable {
        var responseMimeType: String?
        var responseSchema: Schema?
        var maxOutputTokens: Int?

        init(responseMimeType: String? = nil, responseSchema: Schema? = nil, maxOutputTokens: Int? = nil) {
            self.responseMimeType = responseMimeType
            self.responseSchema = responseSchema
            self.maxOutputTokens = maxOutputTokens
        }
    }

    /// A node of Gemini's OpenAPI-subset response schema. A class so it can
    /// nest recursively; optional fields are omitted from the encoded JSON.
    private nonisolated final class Schema: Encodable, Sendable {
        let type: String
        let properties: [String: Schema]?
        let required: [String]?
        let items: Schema?
        let nullable: Bool?

        init(
            type: String,
            properties: [String: Schema]? = nil,
            required: [String]? = nil,
            items: Schema? = nil,
            nullable: Bool? = nil
        ) {
            self.type = type
            self.properties = properties
            self.required = required
            self.items = items
            self.nullable = nullable
        }
    }

    private nonisolated struct ResponseEnvelope: Decodable {
        nonisolated struct Candidate: Decodable {
            var content: CandidateContent?
            var finishReason: String?
        }
        nonisolated struct CandidateContent: Decodable {
            var parts: [CandidatePart]?
        }
        nonisolated struct CandidatePart: Decodable {
            var text: String?
        }
        var candidates: [Candidate]?
    }

    private nonisolated struct ErrorEnvelope: Decodable {
        nonisolated struct Status: Decodable {
            var message: String?
        }
        var error: Status?
    }
}
