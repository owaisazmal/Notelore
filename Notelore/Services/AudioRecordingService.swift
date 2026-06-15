import AVFoundation
import Observation

enum RecordingState: Equatable {
    case idle
    case recording
    case paused
    /// Paused by the system (phone call, Siri) rather than the user.
    case interrupted
}

enum RecordingEvent: Equatable {
    /// A call or Siri took the session; recording has been auto-paused.
    case interruptionBegan
    /// The interruption ended. If `shouldResume`, the conformer has already
    /// resumed capture; otherwise the user must resume by hand.
    case interruptionEnded(shouldResume: Bool)
    /// The input route changed (AirPods connected, wired mic removed, …).
    case routeChanged(description: String)
    /// Capture failed irrecoverably mid-recording.
    case failed(message: String)
}

struct RecordingResult: Equatable {
    /// File name inside AudioStorage.directory().
    let fileName: String
    let duration: TimeInterval
}

enum RecordingError: LocalizedError {
    case permissionDenied
    case alreadyRecording
    case engineStartFailed(String)
    case fileWriteFailed(String)
    case nothingRecorded

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Notelore needs the microphone to record. You can allow it in Settings."
        case .alreadyRecording:
            return "A recording is already in progress."
        case .engineStartFailed:
            return "The microphone could not be started. Try again."
        case .fileWriteFailed:
            return "The recording could not be saved."
        case .nothingRecorded:
            return "Nothing was recorded."
        }
    }
}

/// Captures microphone audio with AVAudioEngine and writes an .m4a (AAC)
/// file into AudioStorage.directory(). Conformers must:
///  - configure AVAudioSession (.record) on start and deactivate (with
///    `.notifyOthersOnDeactivation`) after stop,
///  - keep capturing in the background (the audio background mode is on),
///  - auto-pause on interruption (call/Siri), emit events, support resume,
///  - survive route changes (AirPods connect/disconnect) without losing
///    the file, and
///  - update `state`/`elapsed` on the main actor for the UI.
@MainActor
protocol AudioRecordingService: AnyObject, Observable {
    var state: RecordingState { get }
    /// Seconds captured so far, excluding paused time. Updated ~1 Hz.
    var elapsed: TimeInterval { get }
    /// UI event feed. A fresh stream is created for each recording.
    var events: AsyncStream<RecordingEvent> { get }
    /// Called on the audio capture thread with every tapped buffer while
    /// recording (never while paused). Used to feed live transcription.
    /// The closure must be fast and must not touch main-actor state.
    var bufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)? { get set }

    /// True if microphone permission is granted (requests it if undetermined).
    func requestPermission() async -> Bool
    func start() async throws
    func pause()
    func resume() throws
    /// Stops capture, finalizes the m4a, deactivates the audio session.
    func stop() async throws -> RecordingResult
    /// Abandons the current recording and deletes its partial file.
    func discard()
}
