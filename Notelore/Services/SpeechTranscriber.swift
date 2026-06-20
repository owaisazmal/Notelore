import AVFoundation
import Foundation
import Observation
import Speech
import os

/// The concrete TranscriptionService, wrapping SFSpeechRecognizer.
///
/// On-device recognition is required whenever the locale supports it, so
/// recording + transcription work fully offline. A single recognition task
/// finalizes after roughly a minute, so the transcriber ends the current
/// request a little before that and starts a fresh one, carrying a running
/// offset so utterance timestamps stay relative to the whole recording.
///
/// The recognizer's partial results are NOT reliably cumulative — for long
/// audio it drops earlier words from the window, and after a pause it can
/// restart segment timestamps for a new sentence. So instead of trusting the
/// latest partial, this accumulates every segment it sees (merging the moving
/// window and re-basing after a reset) into the request's full passage, which
/// is what gets committed. That's what keeps earlier sentences from being lost.
@MainActor
@Observable
final class SpeechTranscriber: TranscriptionService {

    /// Live snapshot for the UI, updated on the main actor.
    private(set) var snapshot = TranscriptSnapshot()

    static let log = Logger(subsystem: "com.owaiskhan.notelore", category: "transcriber")

    // MARK: - Private state (main actor)

    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    /// Utterances committed by earlier (already-ended) requests.
    @ObservationIgnored private var committed: [Utterance] = []
    /// Where the current request's audio begins, in seconds from the start of
    /// the whole recording. Advanced by the measured audio fed to each request.
    @ObservationIgnored private var baseOffset: TimeInterval = 0

    // Accumulated segments for the *current* request, robust to the recognizer
    // dropping old words and restarting timestamps after a pause:
    /// Completed chunks of the current request (sentences the recognizer reset
    /// past), re-based onto one monotonic timeline.
    @ObservationIgnored private var stableSegments: [SegmentData] = []
    /// Re-base offset for the in-progress chunk (advances each time the
    /// recognizer restarts its timeline after a pause).
    @ObservationIgnored private var chunkOffset: TimeInterval = 0
    /// The latest partial's segments for the in-progress chunk.
    @ObservationIgnored private var livePartial: [SegmentData] = []

    /// Identifies the live request; stale callbacks from earlier ones ignored.
    @ObservationIgnored private var generation = 0
    /// True once the live request has been asked to end early (rotate).
    @ObservationIgnored private var rotateRequested = false
    /// True while finish() is awaiting the last final result.
    @ObservationIgnored private var isFinishing = false
    @ObservationIgnored private var finishContinuation: CheckedContinuation<Void, Never>?

    /// The live request plus the measured seconds of audio fed to it, reachable
    /// from the audio capture thread. Guarded by an unfair lock because
    /// `append(_:)` is nonisolated.
    private struct LiveState {
        var request: SFSpeechAudioBufferRecognitionRequest?
        var fedDuration: TimeInterval = 0
    }
    private let live = OSAllocatedUnfairLock<LiveState>(uncheckedState: LiveState())

    /// A new utterance group starts when the silence between segments
    /// exceeds this many seconds.
    private static let utteranceGap: TimeInterval = 0.8
    /// A backwards jump larger than this in segment time means the recognizer
    /// restarted for a new sentence (vs. a small in-window revision).
    private static let resetJump: TimeInterval = 0.5
    /// End the request and start a fresh one once this much audio has been fed,
    /// comfortably before the recognizer's ~1 minute limit.
    private static let rotateAfter: TimeInterval = 45

    /// A Sendable copy of one SFTranscriptionSegment.
    private struct SegmentData: Sendable {
        let text: String
        let timestamp: TimeInterval
        let duration: TimeInterval
    }

    init() {}

    // MARK: - TranscriptionService

    func isAvailable(for locale: Locale) -> Bool {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { return false }
        return recognizer.isAvailable
    }

    func requestPermission() async -> Bool {
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        return status == .authorized
    }

    func start(locale: Locale) throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            let name = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
            Self.log.error("start: unavailable for \(locale.identifier, privacy: .public)")
            throw TranscriptionError.unavailableForLocale(name)
        }
        resetSession()
        self.recognizer = recognizer
        Self.log.notice("start: locale=\(locale.identifier, privacy: .public) onDevice=\(recognizer.supportsOnDeviceRecognition)")
        beginRequest()
    }

    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        let rate = buffer.format.sampleRate
        let seconds = rate > 0 ? Double(buffer.frameLength) / rate : 0
        live.withLockUnchecked { state in
            state.request?.append(buffer)
            state.fedDuration += seconds
        }
    }

    func finish() async -> [Utterance] {
        guard task != nil else {
            let collected = committed
            resetSession()
            return collected
        }

        isFinishing = true
        let request = live.withLockUnchecked { state -> SFSpeechAudioBufferRecognitionRequest? in
            let current = state.request
            state.request = nil
            return current
        }
        request?.endAudio()

        // Wait for the final result, racing a ~3 second timeout.
        let gen = generation
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finishContinuation = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.generation == gen else { return }
                Self.log.notice("finish: final did not arrive in time; committing accumulated")
                self.resolveFinish()
            }
        }

        // Commit whatever the request accumulated — the full passage, not just
        // the last partial — so nothing is lost even if the final timed out.
        commitCurrent()

        let collected = committed
        Self.log.notice("finish: returning \(collected.count) utterances")
        resetSession()
        return collected
    }

    func cancel() {
        resetSession()
    }

    // MARK: - Recognition lifecycle

    private func beginRequest() {
        guard let recognizer else { return }
        generation += 1
        let gen = generation
        rotateRequested = false
        stableSegments = []
        chunkOffset = 0
        livePartial = []

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        live.withLockUnchecked { state in
            state.request = request
            state.fedDuration = 0
        }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handleRecognition(generation: gen, result: result, error: error)
        }
        Self.log.debug("beginRequest gen=\(gen) baseOffset=\(self.baseOffset, format: .fixed(precision: 1))")
    }

    /// Recognition callbacks arrive on an arbitrary queue: extract Sendable
    /// data here, then hop to the main actor.
    nonisolated private func handleRecognition(
        generation gen: Int,
        result: SFSpeechRecognitionResult?,
        error: Error?
    ) {
        let isFinal = result?.isFinal ?? false
        let formatted = result?.bestTranscription.formattedString ?? ""
        let segments: [SegmentData] = result?.bestTranscription.segments.map { segment in
            SegmentData(text: segment.substring, timestamp: segment.timestamp, duration: segment.duration)
        } ?? []
        let failed = error != nil
        let errorText = error?.localizedDescription
        Task { @MainActor [weak self] in
            self?.apply(generation: gen, isFinal: isFinal, formattedText: formatted, segments: segments, failed: failed, errorText: errorText)
        }
    }

    private func apply(
        generation gen: Int,
        isFinal: Bool,
        formattedText: String,
        segments: [SegmentData],
        failed: Bool,
        errorText: String?
    ) {
        guard gen == generation else { return }

        if failed {
            Self.log.notice("recog gen=\(gen) ERROR \(errorText ?? "?", privacy: .public) — committing & continuing")
            commitCurrent()
            if isFinishing { resolveFinish() } else { advanceAndBegin() }
            return
        }

        ingest(segments)
        let full = livePassageSegments()
        snapshot.volatileText = full.map(\.text).joined(separator: " ")

        Self.log.debug("recog gen=\(gen) final=\(isFinal) segs=\(segments.count) accumulated=\(full.count) chars=\(self.snapshot.volatileText.count)")

        if isFinal {
            commitCurrent()
            if isFinishing { resolveFinish() } else { advanceAndBegin() }
            return
        }

        // Rotate on real audio fed (not segment time), comfortably before the
        // recognizer's ~1 minute limit.
        let fed = live.withLockUnchecked { $0.fedDuration }
        if !rotateRequested, !isFinishing, fed > Self.rotateAfter {
            rotateRequested = true
            Self.log.notice("rotate gen=\(gen) at fed=\(fed, format: .fixed(precision: 1))s")
            live.withLockUnchecked { $0.request }?.endAudio()
        }
    }

    // MARK: - Segment accumulation

    /// Folds a new partial's segments into the request's accumulated passage,
    /// handling both the moving window (old words drop, timestamps grow) and a
    /// reset (timestamps jump back for a new sentence).
    private func ingest(_ segs: [SegmentData]) {
        guard let newFirst = segs.first, let newLast = segs.last else { return }
        if let prevLast = livePartial.last, newLast.timestamp + Self.resetJump < prevLast.timestamp {
            // Reset: the previous partial is a completed chunk. Re-base it onto
            // the running timeline and stash it; the new sentence starts after.
            stableSegments.append(contentsOf: livePartial.map { rebased($0, by: chunkOffset) })
            chunkOffset += prevLast.timestamp + prevLast.duration
            livePartial = segs
        } else {
            // Window/cumulative: keep whatever we had before the new window,
            // then take the new (revised) tail.
            let kept = livePartial.filter { $0.timestamp < newFirst.timestamp - 0.01 }
            livePartial = kept + segs
        }
    }

    /// The current request's full passage so far, on one monotonic timeline.
    private func livePassageSegments() -> [SegmentData] {
        stableSegments + livePartial.map { rebased($0, by: chunkOffset) }
    }

    private func rebased(_ s: SegmentData, by offset: TimeInterval) -> SegmentData {
        offset == 0 ? s : SegmentData(text: s.text, timestamp: s.timestamp + offset, duration: s.duration)
    }

    /// Folds the current request's full passage into the committed transcript.
    private func commitCurrent() {
        let full = livePassageSegments()
        if !full.isEmpty {
            committed.append(contentsOf: utterances(from: full, offset: baseOffset))
            snapshot.finalized = committed
        }
        stableSegments = []
        chunkOffset = 0
        livePartial = []
        snapshot.volatileText = ""
    }

    /// Advances the offset by the audio the just-ended request consumed and
    /// starts the next request.
    private func advanceAndBegin() {
        let consumed = live.withLockUnchecked { state -> TimeInterval in
            let fed = state.fedDuration
            state.request = nil
            return fed
        }
        baseOffset += consumed
        beginRequest()
    }

    private func resolveFinish() {
        finishContinuation?.resume()
        finishContinuation = nil
    }

    private func resetSession() {
        generation += 1
        task?.cancel()
        task = nil
        recognizer = nil
        live.withLockUnchecked { $0 = LiveState() }
        committed = []
        stableSegments = []
        chunkOffset = 0
        livePartial = []
        baseOffset = 0
        rotateRequested = false
        isFinishing = false
        snapshot = TranscriptSnapshot()
        finishContinuation?.resume()
        finishContinuation = nil
    }

    // MARK: - Utterance building

    /// Groups consecutive segments into utterances, starting a new group
    /// when the silence between segments exceeds `utteranceGap`.
    private func utterances(from segments: [SegmentData], offset: TimeInterval) -> [Utterance] {
        var built: [Utterance] = []
        var groupTexts: [String] = []
        var groupStart: TimeInterval = 0
        var groupEnd: TimeInterval = 0

        func closeGroup() {
            guard !groupTexts.isEmpty else { return }
            built.append(Utterance(
                text: groupTexts.joined(separator: " "),
                start: groupStart + offset,
                end: groupEnd + offset
            ))
            groupTexts = []
        }

        for segment in segments where !segment.text.isEmpty {
            if groupTexts.isEmpty {
                groupTexts = [segment.text]
                groupStart = segment.timestamp
                groupEnd = segment.timestamp + segment.duration
            } else if segment.timestamp - groupEnd > Self.utteranceGap {
                closeGroup()
                groupTexts = [segment.text]
                groupStart = segment.timestamp
                groupEnd = segment.timestamp + segment.duration
            } else {
                groupTexts.append(segment.text)
                groupEnd = max(groupEnd, segment.timestamp + segment.duration)
            }
        }
        closeGroup()
        return built
    }
}
