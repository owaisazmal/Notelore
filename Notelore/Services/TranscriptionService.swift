import AVFoundation
import Observation

/// A live transcription snapshot: utterances finalized so far, plus the
/// in-flight tail that may still be revised.
struct TranscriptSnapshot: Equatable, Sendable {
    var finalized: [Utterance] = []
    var volatileText: String = ""

    var isEmpty: Bool { finalized.isEmpty && volatileText.isEmpty }
}

enum TranscriptionError: LocalizedError {
    case permissionDenied
    case unavailableForLocale(String)
    case recognizerFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Notelore needs speech recognition to write the transcript. You can allow it in Settings."
        case .unavailableForLocale(let name):
            return "Transcription isn't available for \(name) on this device. The recording will still be kept."
        case .recognizerFailed:
            return "Transcription stopped unexpectedly. The recording is unaffected."
        }
    }
}

/// On-device-first speech-to-text wrapping SFSpeechRecognizer. Conformers:
///  - prefer on-device recognition where the locale supports it, and require
///    it when offline (recording + transcription must work fully offline),
///  - rotate recognition requests internally so long sessions keep working;
///    utterance timestamps are offsets from the start of the recording,
///  - publish `snapshot` on the main actor as partial results arrive.
@MainActor
protocol TranscriptionService: AnyObject, Observable {
    /// Live snapshot for the UI.
    var snapshot: TranscriptSnapshot { get }
    /// False when the locale has no recognizer or recognition is unavailable.
    func isAvailable(for locale: Locale) -> Bool
    /// True if speech permission is granted (requests it if undetermined).
    func requestPermission() async -> Bool
    /// Begin a live session. Buffer format is taken from the first append.
    func start(locale: Locale) throws
    /// Feed captured audio. Safe to call from the audio capture thread.
    nonisolated func append(_ buffer: AVAudioPCMBuffer)
    /// Finish, wait briefly for the final result, and return all utterances.
    func finish() async -> [Utterance]
    /// Abandon the session without waiting for results.
    func cancel()
}
