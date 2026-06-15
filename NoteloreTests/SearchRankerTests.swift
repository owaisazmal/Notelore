//
//  SearchRankerTests.swift
//  NoteloreTests
//
//  Deterministic tests for the pure SearchRanker scoring function and its
//  tokenize / occurrences / snippet helpers. All dates are fixed and a fixed
//  `now` is passed so the recency multiplier never drifts.
//

import Foundation
import Testing
@testable import Notelore

@Suite struct SearchRankerTests {

    // A fixed reference clock for every ranking call.
    private let now = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14

    // A single shared creation date so recency cancels out when comparing text.
    private let createdAt = Date(timeIntervalSince1970: 1_699_000_000)

    private func doc(
        id: UUID = UUID(),
        title: String = "",
        body: String = "",
        summary: String = "",
        tags: [String] = [],
        createdAt: Date? = nil
    ) -> SearchDocument {
        SearchDocument(
            id: id,
            title: title,
            body: body,
            summary: summary,
            tags: tags,
            createdAt: createdAt ?? self.createdAt
        )
    }

    private func score(of id: UUID, in hits: [SearchHit]) -> Double? {
        hits.first(where: { $0.id == id })?.score
    }

    // MARK: - Field weighting

    @Test func titleMatchOutranksBodyOnlyMatch() throws {
        let titleDoc = doc(title: "Roadmap planning", body: "unrelated text")
        let bodyDoc = doc(title: "Untitled", body: "the roadmap was discussed at length")

        let hits = SearchRanker.rank(query: "roadmap", documents: [bodyDoc, titleDoc], now: now)
        #expect(hits.first?.id == titleDoc.id)
        #expect(try #require(score(of: titleDoc.id, in: hits)) > #require(score(of: bodyDoc.id, in: hits)))
    }

    @Test func tagMatchOutranksSummaryOnlyMatch() throws {
        let tagDoc = doc(title: "A", tags: ["budget"])
        let summaryDoc = doc(title: "B", summary: "we reviewed the budget carefully")

        let hits = SearchRanker.rank(query: "budget", documents: [summaryDoc, tagDoc], now: now)
        #expect(hits.first?.id == tagDoc.id)
        #expect(try #require(score(of: tagDoc.id, in: hits)) > #require(score(of: summaryDoc.id, in: hits)))
    }

    // MARK: - Body occurrence counting + per-token cap

    @Test func moreBodyOccurrencesScoreHigher() throws {
        let few = doc(title: "x", body: "alpha beta gamma")            // 1 occurrence
        let many = doc(title: "y", body: "alpha alpha alpha alpha")    // 4 occurrences

        let hits = SearchRanker.rank(query: "alpha", documents: [few, many], now: now)
        #expect(try #require(score(of: many.id, in: hits)) > #require(score(of: few.id, in: hits)))
    }

    @Test func bodyOccurrenceContributionIsCappedAtFive() {
        // min(count, 5): 5 vs 50 occurrences must yield identical scores
        // (everything else, including createdAt, is equal).
        let fiveBody = String(repeating: "alpha ", count: 5)
        let fiftyBody = String(repeating: "alpha ", count: 50)
        let capped = doc(title: "t", body: fiveBody)
        let saturated = doc(title: "t", body: fiftyBody)

        let hits = SearchRanker.rank(query: "alpha", documents: [capped, saturated], now: now)
        let cappedScore = try! #require(score(of: capped.id, in: hits))
        let saturatedScore = try! #require(score(of: saturated.id, in: hits))
        // Linear scaling would make 50 occurrences ~10x the 5-occurrence score.
        // The cap forces them equal.
        #expect(abs(cappedScore - saturatedScore) < 0.0001)
    }

    // MARK: - matchedAll multiplier (2-token queries)

    @Test func docMatchingBothTokensOutranksDocMatchingOneTokenManyTimes() throws {
        // "design review" — bothDoc matches both tokens (title +5 each, then the
        // matchedAll x1.5 multiplier => 15). oneDoc matches only "design", many
        // times, but the per-token body cap holds it at +5. So matching BOTH
        // tokens beats matching ONE token a lot.
        let bothDoc = doc(title: "design review")
        let oneDoc = doc(
            title: "w",
            body: "design design design design design design design design"
        )

        let hits = SearchRanker.rank(query: "design review", documents: [oneDoc, bothDoc], now: now)
        #expect(hits.first?.id == bothDoc.id)
        #expect(try #require(score(of: bothDoc.id, in: hits)) > #require(score(of: oneDoc.id, in: hits)))
    }

    // MARK: - Phrase bonus

    @Test func exactPhraseOutranksScatteredWords() throws {
        // Both docs match both tokens equally; only word order differs, so the
        // +6 phrase bonus is the deciding factor.
        let phraseDoc = doc(title: "p", body: "we held a design review yesterday")
        let scatteredDoc = doc(title: "p", body: "the review covered the new design")

        let hits = SearchRanker.rank(
            query: "design review",
            documents: [scatteredDoc, phraseDoc],
            now: now
        )
        #expect(hits.first?.id == phraseDoc.id)
        #expect(try #require(score(of: phraseDoc.id, in: hits)) > #require(score(of: scatteredDoc.id, in: hits)))
    }

    // MARK: - Recency

    @Test func newerDocRanksFirstWhenTextIdentical() throws {
        let older = doc(
            title: "Sprint",
            body: "sprint planning notes",
            createdAt: Date(timeIntervalSince1970: 1_600_000_000)
        )
        let newer = doc(
            title: "Sprint",
            body: "sprint planning notes",
            createdAt: Date(timeIntervalSince1970: 1_699_900_000) // closer to `now`
        )

        let hits = SearchRanker.rank(query: "sprint", documents: [older, newer], now: now)
        #expect(hits.first?.id == newer.id)
        #expect(try #require(score(of: newer.id, in: hits)) > #require(score(of: older.id, in: hits)))
    }

    // MARK: - Edge cases

    @Test func emptyQueryReturnsNoHits() {
        let hits = SearchRanker.rank(query: "", documents: [doc(title: "anything")], now: now)
        #expect(hits.isEmpty)
    }

    @Test func whitespaceOnlyQueryReturnsNoHits() {
        let hits = SearchRanker.rank(query: "   \n\t  ", documents: [doc(title: "anything")], now: now)
        #expect(hits.isEmpty)
    }

    @Test func docWithNoTokenMatchIsExcluded() {
        let matching = doc(title: "Onboarding flow")
        let nonMatching = doc(title: "Pricing page", body: "nothing relevant here")

        let hits = SearchRanker.rank(query: "onboarding", documents: [matching, nonMatching], now: now)
        #expect(hits.count == 1)
        #expect(hits.first?.id == matching.id)
        #expect(score(of: nonMatching.id, in: hits) == nil)
    }

    // MARK: - tokenize

    @Test func tokenizeSplitsOnPunctuationAndLowercases() {
        #expect(SearchRanker.tokenize("Hello, World!") == ["hello", "world"])
    }

    @Test func tokenizeDropsEmptyTokens() {
        #expect(SearchRanker.tokenize("  one---two  ") == ["one", "two"])
    }

    @Test func tokenizeEmptyStringIsEmptyArray() {
        #expect(SearchRanker.tokenize("") == [])
    }

    // MARK: - occurrences

    @Test func occurrencesCountsNonOverlapping() {
        // "aaa" scanned for "aa": one match consumes positions 0-1, leaving "a".
        #expect(SearchRanker.occurrences(of: "aa", in: "aaa") == 1)
    }

    @Test func occurrencesCountsDistinctMatches() {
        #expect(SearchRanker.occurrences(of: "ab", in: "ababab") == 3)
    }

    @Test func occurrencesZeroWhenAbsentOrEmpty() {
        #expect(SearchRanker.occurrences(of: "z", in: "abc") == 0)
        #expect(SearchRanker.occurrences(of: "", in: "abc") == 0)
        #expect(SearchRanker.occurrences(of: "a", in: "") == 0)
    }

    // MARK: - snippet

    @Test func snippetContainsTokenAndAddsEllipsisWhenClippedFromMiddle() {
        // A long body with the match buried in the middle so both ends clip.
        let lead = String(repeating: "x", count: 200)
        let tail = String(repeating: "y", count: 200)
        let body = lead + " needle " + tail
        let document = doc(title: "t", body: body)

        let snippet = SearchRanker.snippet(tokens: ["needle"], in: document)
        #expect(snippet.contains("needle"))
        #expect(snippet.contains("…"))
        #expect(snippet.hasPrefix("…"))
        #expect(snippet.hasSuffix("…"))
    }

    @Test func snippetFallsBackToPrefixWhenNoMatch() {
        let document = doc(title: "t", body: "a short body with no match token")
        let snippet = SearchRanker.snippet(tokens: ["absent"], in: document)
        // No token matched -> first radius*2 characters, no ellipsis logic.
        #expect(!snippet.contains("absent"))
        #expect(snippet.contains("short body"))
    }

    @Test func snippetSurvivesNonASCIIBodyWithoutCrashing() {
        // A body whose lowercasing changes character boundaries/length (the
        // Turkish dotted capital İ expands to two scalars when lowercased).
        // snippet() must index the original string, never a lowercased copy.
        let lead = String(repeating: "İ", count: 80)
        let tail = String(repeating: "Ş", count: 80)
        let body = lead + " RÉSUMÉ café déjà vu " + tail
        let document = doc(title: "t", body: body)

        // tokenize lowercases, so the stored token is the lowercased form.
        let snippet = SearchRanker.snippet(tokens: SearchRanker.tokenize("RÉSUMÉ"), in: document)
        #expect(snippet.localizedCaseInsensitiveContains("résumé"))
    }
}
