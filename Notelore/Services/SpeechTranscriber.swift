import AVFoundation
import Foundation
import Observation
import Speech
import os

/// The concrete TranscriptionService, wrapping SFSpeechRecognizer.
///
/// On-device recognition is required whenever the locale supports it, so
/// recording + transcription work fully offline. Because recognition tasks
/// finalize after roughly a minute, the transcriber rotates to a fresh
/// request whenever a final result arrives (and proactively ends audio once
/// a partial result runs past ~50 seconds), carrying a `runningOffset` so
/// utterance timestamps stay relative to the start of the whole recording.
@MainActor
@Observable
final class SpeechTranscriber: TranscriptionService {

    /// Live snapshot for the UI, updated on the main actor.
    private(set) var snapshot = TranscriptSnapshot()

    // MARK: - Private state (main actor)

    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    /// Seconds of audio already finalized by earlier (rotated-out) requests.
    @ObservationIgnored private var runningOffset: TimeInterval = 0
    @ObservationIgnored private var finalizedUtterances: [Utterance] = []
    /// Segments of the latest partial result, kept so a volatile tail can be
    /// given sensible timestamps if no final result arrives on finish().
    @ObservationIgnored private var volatileSegments: [SegmentData] = []
    /// Bumped whenever a request is replaced or the session resets, so stale
    /// recognition callbacks from older tasks are ignored.
    @ObservationIgnored private var generation = 0
    /// True after endAudio() was sent to force an early rotation.
    @ObservationIgnored private var rotationPending = false
    /// True while finish() is waiting for the last final result.
    @ObservationIgnored private var isFinishing = false
    @ObservationIgnored private var finishContinuation: CheckedContinuation<Void, Never>?

    /// The live request, reachable from the audio capture thread. Guarded by
    /// an unfair lock because `append(_:)` is nonisolated.
    private let liveRequest = OSAllocatedUnfairLock<SFSpeechAudioBufferRecognitionRequest?>(uncheckedState: nil)

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
        beginRequest()
    }

    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        liveRequest.withLockUnchecked { request in
            request?.append(buffer)
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
        let request = liveRequest.withLockUnchecked { box -> SFSpeechAudioBufferRecognitionRequest? in
            let current = box
            box = nil
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

        // No final result arrived in time: fold the volatile tail into a
        // last utterance so nothing the user saw is lost.
        let tail = snapshot.volatileText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            let utterance: Utterance
            if let first = volatileSegments.first, let last = volatileSegments.last {
                utterance = Utterance(
                    text: tail,
                    start: first.timestamp + runningOffset,
                    end: last.timestamp + last.duration + runningOffset
                )
            } else {
                utterance = Utterance(text: tail, start: runningOffset, end: runningOffset)
            }
            finalizedUtterances.append(utterance)
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

    /// Starts a fresh request + task; live transcription continues from
    /// wherever the previous request left off (`runningOffset`).
    private func beginRequest() {
        guard let recognizer else { return }
        generation += 1
        let gen = generation
        rotationPending = false

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        liveRequest.withLockUnchecked { $0 = request }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
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
        guard gen == generation else { return }

        if isFinal {
            // Fold the finalized stretch in, advance the offset by this
            // result's audio extent, and rotate to a fresh request.
            let newUtterances = utterances(from: segments, offset: runningOffset)
            finalizedUtterances.append(contentsOf: newUtterances)
            if let last = segments.last {
                runningOffset += last.timestamp + last.duration
            }
            volatileSegments = []
            snapshot.finalized = finalizedUtterances
            snapshot.volatileText = ""
            if isFinishing {
                resolveFinish()
            } else {
                beginRequest()
            }
            return
        }

        if failed {
            // Keep everything already finalized; recording continues
            // independently of transcription.
            volatileSegments = []
            snapshot.volatileText = ""
            if isFinishing {
                resolveFinish()
            } else if rotationPending, recognizer != nil {
                // The rotation we asked for ended in an error instead of a
                // final result; start fresh so transcription keeps going.
                beginRequest()
            } else {
                task = nil
                liveRequest.withLockUnchecked { $0 = nil }
            }
            return
        }

        // Partial result: update the in-flight tail.
        volatileSegments = segments
        snapshot.volatileText = formattedText

        // Rotate proactively before the recognizer's ~1 minute limit; the
        // final result it produces triggers the actual swap above.
        if !rotationPending, !isFinishing,
           let last = segments.last, last.timestamp > Self.rotationThreshold {
            rotationPending = true
            let request = liveRequest.withLockUnchecked { $0 }
            request?.endAudio()
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
        recognizer = nil
        liveRequest.withLockUnchecked { $0 = nil }
        runningOffset = 0
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
