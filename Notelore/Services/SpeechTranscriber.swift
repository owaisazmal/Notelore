import AVFoundation
import Foundation
import Observation
import Speech
import os

/// The concrete TranscriptionService, wrapping SFSpeechRecognizer.
///
/// On-device recognition is required whenever the locale supports it, so
/// recording + transcription work fully offline. Because a single recognition
/// task finalizes after roughly a minute, the transcriber rotates to a fresh
/// request once a partial result runs past ~50 seconds. The rotation is
/// seamless: the replacement request is swapped in atomically *before* the old
/// one is ended, so no captured audio is dropped at the boundary, and each
/// request carries the running offset of the real audio fed to earlier
/// requests, so utterance timestamps stay relative to the whole recording.
@MainActor
@Observable
final class SpeechTranscriber: TranscriptionService {

    /// Live snapshot for the UI, updated on the main actor.
    private(set) var snapshot = TranscriptSnapshot()

    // MARK: - Private state (main actor)

    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    /// The task for the current (live) request.
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    /// Tasks for requests that have been ended and are draining their final
    /// result, keyed by generation. Cancelled on reset.
    @ObservationIgnored private var drainTasks: [Int: SFSpeechRecognitionTask] = [:]
    /// Where the next request's audio begins, in seconds from the start of the
    /// whole recording. Advanced by the *measured* audio fed to each request.
    @ObservationIgnored private var nextOffset: TimeInterval = 0
    /// Start offset of each in-flight request (live or draining), keyed by
    /// generation, so a late-arriving final folds in at the right place.
    @ObservationIgnored private var requestOffsets: [Int: TimeInterval] = [:]
    @ObservationIgnored private var finalizedUtterances: [Utterance] = []
    /// Segments of the latest partial result, kept so a volatile tail can be
    /// given sensible timestamps if no final result arrives on finish().
    @ObservationIgnored private var volatileSegments: [SegmentData] = []
    /// Bumped whenever a request is created or the session resets; identifies
    /// the live generation and tags recognition callbacks.
    @ObservationIgnored private var generation = 0
    /// True after the live request has been asked to rotate (endAudio), so the
    /// proactive trigger fires only once per request.
    @ObservationIgnored private var rotationPending = false
    /// True while finish() is waiting for the last final result.
    @ObservationIgnored private var isFinishing = false
    @ObservationIgnored private var finishContinuation: CheckedContinuation<Void, Never>?

    /// The live request plus the measured seconds of audio fed to it, reachable
    /// from the audio capture thread. Guarded by an unfair lock because
    /// `append(_:)` is nonisolated. Swapping the request and reading/resetting
    /// the fed count happen under the same lock so rotation never loses audio.
    private struct LiveState {
        var request: SFSpeechAudioBufferRecognitionRequest?
        var fedDuration: TimeInterval = 0
    }
    private let live = OSAllocatedUnfairLock<LiveState>(uncheckedState: LiveState())

    /// A new utterance group starts when the silence between segments
    /// exceeds this many seconds.
    private static let utteranceGap: TimeInterval = 0.8
    /// Rotate proactively once a partial result runs past this many seconds.
    private static let rotationThreshold: TimeInterval = 50

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
            throw TranscriptionError.unavailableForLocale(name)
        }
        resetSession()
        self.recognizer = recognizer
        beginRequest(startOffset: 0)
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
            let collected = finalizedUtterances
            resetSession()
            return collected
        }

        isFinishing = true
        rotationPending = false
        let request = live.withLockUnchecked { state -> SFSpeechAudioBufferRecognitionRequest? in
            let current = state.request
            state.request = nil
            return current
        }
        request?.endAudio()

        // Wait for the final result, racing a ~2 second timeout.
        let gen = generation
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finishContinuation = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.generation == gen else { return }
                self.resolveFinish()
            }
        }

        // No final result arrived in time: fold the volatile tail into a last
        // utterance so nothing the user saw is lost.
        let tail = snapshot.volatileText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            let offset = requestOffsets[generation] ?? nextOffset
            let utterance: Utterance
            if let first = volatileSegments.first, let last = volatileSegments.last {
                utterance = Utterance(
                    text: tail,
                    start: first.timestamp + offset,
                    end: last.timestamp + last.duration + offset
                )
            } else {
                utterance = Utterance(text: tail, start: offset, end: offset)
            }
            finalizedUtterances.append(utterance)
            finalizedUtterances.sort { $0.start < $1.start }
            snapshot.finalized = finalizedUtterances
            snapshot.volatileText = ""
        }

        let collected = finalizedUtterances
        resetSession()
        return collected
    }

    func cancel() {
        resetSession()
    }

    // MARK: - Recognition lifecycle

    private func makeRequest() -> SFSpeechAudioBufferRecognitionRequest? {
        guard let recognizer else { return nil }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        return request
    }

    /// Starts a fresh live request + task beginning at `startOffset`. Used for
    /// the first request and for the fallback (natural-final) rotation, where
    /// there is no overlapping request to drain.
    private func beginRequest(startOffset: TimeInterval) {
        guard let recognizer, let request = makeRequest() else { return }
        generation += 1
        let gen = generation
        requestOffsets[gen] = startOffset
        rotationPending = false
        live.withLockUnchecked { state in
            state.request = request
            state.fedDuration = 0
        }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handleRecognition(generation: gen, result: result, error: error)
        }
    }

    /// Proactive, seamless rotation: publish a replacement request atomically
    /// in place of the live one (so `append(_:)` never feeds a nil request and
    /// no audio is dropped), advance the offset by the audio the old request
    /// actually consumed, then end the old request so it drains its final.
    private func rotate() {
        guard let recognizer, let newRequest = makeRequest() else { return }
        let oldGen = generation
        let oldTask = task

        generation += 1
        let gen = generation

        // Atomic swap: read what the old request consumed and install the new
        // request in one lock acquisition.
        let consumed = live.withLockUnchecked { state -> TimeInterval in
            let fed = state.fedDuration
            let old = state.request
            state.request = newRequest
            state.fedDuration = 0
            // End the old request inside the lock so no further buffers reach
            // it after the swap point.
            old?.endAudio()
            return fed
        }

        nextOffset += consumed
        requestOffsets[gen] = nextOffset
        rotationPending = false

        if let oldTask { drainTasks[oldGen] = oldTask }
        task = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            self?.handleRecognition(generation: gen, result: result, error: error)
        }
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
        Task { @MainActor [weak self] in
            self?.apply(generation: gen, isFinal: isFinal, formattedText: formatted, segments: segments, failed: failed)
        }
    }

    private func apply(
        generation gen: Int,
        isFinal: Bool,
        formattedText: String,
        segments: [SegmentData],
        failed: Bool
    ) {
        let isCurrent = (gen == generation)
        // Accept callbacks for the live request or any still-draining request;
        // ignore truly stale ones (e.g. after reset).
        guard isCurrent || requestOffsets[gen] != nil else { return }

        if isFinal {
            // Fold this request's finalized stretch in at its own start offset,
            // then retire it. A draining request keeps the live one untouched.
            let offset = requestOffsets[gen] ?? nextOffset
            finalizedUtterances.append(contentsOf: utterances(from: segments, offset: offset))
            finalizedUtterances.sort { $0.start < $1.start }
            requestOffsets[gen] = nil
            drainTasks[gen] = nil
            snapshot.finalized = finalizedUtterances

            if isCurrent {
                volatileSegments = []
                snapshot.volatileText = ""
                if isFinishing {
                    resolveFinish()
                } else {
                    // The live request finalized on its own (no proactive
                    // rotation happened in time); continue from the measured end.
                    let consumed = live.withLockUnchecked { state -> TimeInterval in
                        let fed = state.fedDuration
                        state.request = nil
                        return fed
                    }
                    nextOffset += consumed
                    beginRequest(startOffset: nextOffset)
                }
            }
            return
        }

        if failed {
            if isCurrent {
                // An error here is usually a silence/pause timeout from
                // on-device recognition — it must NOT drop the line already
                // spoken. Fold the in-flight volatile in first, then keep
                // transcribing with a fresh request so later speech is still
                // captured (never stop mid-recording).
                let offset = requestOffsets[gen] ?? nextOffset
                if !volatileSegments.isEmpty {
                    finalizedUtterances.append(contentsOf: utterances(from: volatileSegments, offset: offset))
                    finalizedUtterances.sort { $0.start < $1.start }
                    snapshot.finalized = finalizedUtterances
                }
                requestOffsets[gen] = nil
                volatileSegments = []
                snapshot.volatileText = ""
                if isFinishing {
                    resolveFinish()
                } else {
                    let consumed = live.withLockUnchecked { state -> TimeInterval in
                        let fed = state.fedDuration
                        state.request = nil
                        return fed
                    }
                    nextOffset += consumed
                    beginRequest(startOffset: nextOffset)
                }
            } else {
                // A draining request errored before delivering its final;
                // just retire it.
                requestOffsets[gen] = nil
                drainTasks[gen] = nil
            }
            return
        }

        // Partial result: only the live request drives the volatile tail.
        guard isCurrent else { return }

        // On-device recognition can start a new utterance within the same
        // request after a pause, restarting its segment timestamps and dropping
        // the earlier words from later results. Detect that regression and fold
        // the previous volatile in before it's overwritten, so nothing spoken
        // before the pause is lost.
        // A reset shows up as the transcript's extent going *backwards*: the
        // newest result's last-segment time is well before the previous one's
        // (a fresh utterance restarting near 0), rather than growing. The 0.2 s
        // margin ignores the small revisions a cumulative result normally makes.
        if let prevLast = volatileSegments.last,
           let newLast = segments.last,
           newLast.timestamp + 0.2 < prevLast.timestamp {
            let offset = requestOffsets[gen] ?? nextOffset
            finalizedUtterances.append(contentsOf: utterances(from: volatileSegments, offset: offset))
            finalizedUtterances.sort { $0.start < $1.start }
            snapshot.finalized = finalizedUtterances
            // The new utterance's timestamps restart near 0; shift this
            // request's offset forward so it lands after the folded text.
            nextOffset = offset + prevLast.timestamp + prevLast.duration
            requestOffsets[gen] = nextOffset
        }

        volatileSegments = segments
        snapshot.volatileText = formattedText

        // Rotate proactively before the recognizer's ~1 minute limit. Segment
        // timestamps are relative to this request's own audio.
        if !rotationPending, !isFinishing,
           let last = segments.last, last.timestamp > Self.rotationThreshold {
            rotationPending = true
            rotate()
        }
    }

    private func resolveFinish() {
        finishContinuation?.resume()
        finishContinuation = nil
    }

    private func resetSession() {
        generation += 1
        task?.cancel()
        task = nil
        for drained in drainTasks.values { drained.cancel() }
        drainTasks = [:]
        recognizer = nil
        live.withLockUnchecked { $0 = LiveState() }
        nextOffset = 0
        requestOffsets = [:]
        finalizedUtterances = []
        volatileSegments = []
        rotationPending = false
        isFinishing = false
        snapshot = TranscriptSnapshot()
        // Never strand a waiter (e.g. cancel() during finish()).
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
