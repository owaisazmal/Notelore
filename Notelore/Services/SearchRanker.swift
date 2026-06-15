import Foundation

/// A search candidate flattened out of a Session, kept free of SwiftData so
/// ranking stays a pure, unit-testable function.
struct SearchDocument: Sendable {
    let id: UUID
    let title: String
    /// Transcript plain text.
    let body: String
    /// Note summary and key points, joined.
    let summary: String
    let tags: [String]
    let createdAt: Date
}

struct SearchHit: Equatable, Sendable {
    let id: UUID
    let score: Double
    let snippet: String
}

/// The lightweight full-text index, v1: simple keyword scoring with a
/// recency boost. Title and tag matches weigh most, then summaries, then
/// transcript occurrences; sessions from the last month get a gentle lift.
enum SearchRanker {
    static func rank(query: String, documents: [SearchDocument], now: Date = Date()) -> [SearchHit] {
        let tokens = tokenize(query)
        guard !tokens.isEmpty else { return [] }
        let phrase = tokens.joined(separator: " ")

        var hits: [SearchHit] = []
        for doc in documents {
            let title = doc.title.lowercased()
            let body = doc.body.lowercased()
            let summary = doc.summary.lowercased()
            let tags = doc.tags.map { $0.lowercased() }

            var score = 0.0
            var matchedAll = true
            for token in tokens {
                var matched = false
                if title.contains(token) { score += 5; matched = true }
                if tags.contains(where: { $0.contains(token) }) { score += 4; matched = true }
                if summary.contains(token) { score += 2; matched = true }
                let bodyCount = occurrences(of: token, in: body)
                if bodyCount > 0 { score += Double(min(bodyCount, 5)); matched = true }
                if !matched { matchedAll = false }
            }
            guard score > 0 else { continue }
            if matchedAll { score *= 1.5 }
            if tokens.count > 1,
               title.contains(phrase) || body.contains(phrase) || summary.contains(phrase) {
                score += 6
            }
            // Recency boost: doubles a brand-new session, fades over ~a month.
            let ageDays = max(0, now.timeIntervalSince(doc.createdAt) / 86_400)
            score *= 1 + exp(-ageDays / 30)

            hits.append(SearchHit(id: doc.id, score: score, snippet: snippet(tokens: tokens, in: doc)))
        }
        return hits.sorted { $0.score > $1.score }
    }

    static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func occurrences(of token: String, in text: String) -> Int {
        guard !token.isEmpty, !text.isEmpty else { return 0 }
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: token, range: searchRange) {
            count += 1
            searchRange = found.upperBound..<text.endIndex
        }
        return count
    }

    /// A short window of transcript (or summary) around the first match.
    static func snippet(tokens: [String], in doc: SearchDocument, radius: Int = 60) -> String {
        let source = doc.body.isEmpty ? doc.summary : doc.body
        // Match case-insensitively against `source` itself; tokens are already
        // lowercased. Working on `source` (never a separate lowercased copy)
        // keeps every index valid for slicing — lowercasing can change string
        // length for some scripts and would invalidate cross-string indices.
        guard let match = tokens.lazy
            .compactMap({ source.range(of: $0, options: .caseInsensitive) })
            .first
        else {
            return String(source.prefix(radius * 2))
        }
        let start = source.index(match.lowerBound, offsetBy: -radius, limitedBy: source.startIndex) ?? source.startIndex
        let end = source.index(match.upperBound, offsetBy: radius, limitedBy: source.endIndex) ?? source.endIndex
        var clip = String(source[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        if start > source.startIndex { clip = "…" + clip }
        if end < source.endIndex { clip += "…" }
        return clip
    }
}
