import Testing
@testable import Notelore

/// The sliding-window reconcile that makes live margin notes ephemeral:
/// terms still in play persist (keeping their id), terms the talk has moved
/// past clear out, and newly-relevant terms are appended.
@MainActor
@Suite struct MarginNotesReconcileTests {

    private func note(_ headword: String, _ text: String = "x", q: Bool = false) -> MarginNote {
        MarginNote(headword: headword, note: text, isQuestion: q)
    }

    @Test func keepsPersistingTermWithSameIdAndRefreshedText() {
        let slo = note("SLO", "old")
        let current = [slo, note("RPO")]
        let fresh = [note("SLO", "new"), note("error budget")]

        let result = RecordModel.reconcile(current: current, fresh: fresh)

        // RPO dropped (gone from the window); SLO kept first; new term appended.
        #expect(result.map(\.headword) == ["SLO", "error budget"])
        #expect(result[0].id == slo.id)      // id preserved → row doesn't re-animate
        #expect(result[0].note == "new")     // text refreshed
    }

    @Test func clearsTermsTheTalkMovedPast() {
        let result = RecordModel.reconcile(current: [note("A"), note("B")], fresh: [note("C")])
        #expect(result.map(\.headword) == ["C"])
    }

    @Test func emptyFreshClearsEverything() {
        let result = RecordModel.reconcile(current: [note("A")], fresh: [])
        #expect(result.isEmpty)
    }

    @Test func dedupesFreshByHeadwordCaseInsensitively() {
        let result = RecordModel.reconcile(current: [], fresh: [note("API"), note("api", "dup")])
        #expect(result.count == 1)
        #expect(result[0].headword == "API")
    }
}
