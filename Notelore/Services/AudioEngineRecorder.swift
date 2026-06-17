import AVFoundation
import Foundation
import Observation
import os

/// The concrete AudioRecordingService, built on AVAudioEngine.
///
/// A tap on the input node feeds every buffer into an AVAudioFile (AAC / m4a)
/// and into `bufferHandler` for live transcription. The tap closure runs on a
/// background audio thread, so everything it touches is Sendable and guarded
/// by unfair locks: the file box, the "active" flag, the one-time error flag,
/// and a snapshot of `bufferHandler`. Main-actor state (`state`, `elapsed`,
/// the events continuation) is only mutated by hopping back to the main actor.
@MainActor
@Observable
final class AudioEngineRecorder: AudioRecordingService {

    // MARK: - Observable UI state

    private(set) var state: RecordingState = .idle
    private(set) var elapsed: TimeInterval = 0

    var events: AsyncStream<RecordingEvent> {
        eventStream ?? AsyncStream { $0.finish() }
    }

    var bufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)? {
        didSet {
            let handler = bufferHandler
            handlerBox.withLock { $0 = handler }
        }
    }

    // MARK: - Private main-actor state

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var fileName: String?
    /// The file's writing format, captured at start so route changes can decide
    /// whether tap buffers need converting back into it.
    @ObservationIgnored private var fileProcessingFormat: AVAudioFormat?
    /// True once a tap is installed on the input node.
    @ObservationIgnored private var tapInstalled = false

    @ObservationIgnored private var eventStream: AsyncStream<RecordingEvent>?
    @ObservationIgnored private var eventContinuation: AsyncStream<RecordingEvent>.Continuation?

    // Elapsed-time bookkeeping (excludes paused time).
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var accumulatedElapsed: TimeInterval = 0
    @ObservationIgnored private var segmentStart: Date?

    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var routeChangeObserver: NSObjectProtocol?

    // MARK: - Audio-thread shared state (lock-guarded, Sendable)

    /// Holds the live AVAudioFile so the @Sendable tap can reach it. `nil`ing
    /// the wrapped value flushes and closes the file.
    private let fileBox = FileBox()
    /// Optional converter installed after a route change when the new input
    /// format differs from the file's processing format.
    private let converterBox = ConverterBox()
    /// True only while capture should be written (recording, not paused).
    private let activeFlag = OSAllocatedUnfairLock<Bool>(initialState: false)
    /// One-shot guard so a write failure yields exactly one `.failed` event.
    private let writeFailedFlag = OSAllocatedUnfairLock<Bool>(initialState: false)
    /// Snapshot of `bufferHandler`, read by the tap.
    private let handlerBox = OSAllocatedUnfairLock<(@Sendable (AVAudioPCMBuffer) -> Void)?>(initialState: nil)

    init() {}

    // MARK: - Boxes

    /// Sendable wrapper around the (non-Sendable) AVAudioFile so the tap can
    /// reach it through a lock without capturing main-actor state.
    private final class FileBox: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<AVAudioFile?>(initialState: nil)
        func set(_ file: AVAudioFile?) { lock.withLock { $0 = file } }
        func withFile<R>(_ body: (AVAudioFile?) -> R) -> R { lock.withLock { body($0) } }
    }

    private final class ConverterBox: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<AVAudioConverter?>(initialState: nil)
        func set(_ converter: AVAudioConverter?) { lock.withLock { $0 = converter } }
        func get() -> AVAudioConverter? { lock.withLock { $0 } }
    }

    // MARK: - Permission

    func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        @unknown default:
            return await AVAudioApplication.requestRecordPermission()
        }
    }

    // MARK: - Start

    func start() async throws {
        guard state == .idle else { throw RecordingError.alreadyRecording }

        // Permission gate.
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            break
        case .denied:
            throw RecordingError.permissionDenied
        case .undetermined:
            let granted = await AVAudioApplication.requestRecordPermission()
            if !granted { throw RecordingError.permissionDenied }
        @unknown default:
            let granted = await AVAudioApplication.requestRecordPermission()
            if !granted { throw RecordingError.permissionDenied }
        }

        // Configure the audio session.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default, options: [.allowBluetooth])
            try session.setActive(true)
        } catch {
            throw RecordingError.engineStartFailed(error.localizedDescription)
        }

        // Create the destination file.
        let name = AudioStorage.newFileName()
        guard let url = AudioStorage.url(forFileName: name) else {
            throw RecordingError.fileWriteFailed("Could not build a recording URL.")
        }

        let inputNode = engine.inputNode
        var inputFormat = inputNode.outputFormat(forBus: 0)
        // The simulator (and, briefly, a device just after the session goes
        // active) can report a 0 Hz / 0-channel input. Preparing the engine
        // forces the hardware format to resolve; if it's still invalid, fail
        // gracefully — feeding an invalid format to AVAudioFile / installTap
        // throws an uncaught AVFAudio exception that crashes the whole app.
        if inputFormat.sampleRate <= 0 || inputFormat.channelCount == 0 {
            engine.prepare()
            inputFormat = inputNode.outputFormat(forBus: 0)
        }
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw RecordingError.engineStartFailed("The microphone reported no usable audio input.")
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: settings)
        } catch {
            AudioStorage.delete(fileName: name)
            throw RecordingError.fileWriteFailed(error.localizedDescription)
        }

        // Reset shared state for this recording.
        fileName = name
        fileProcessingFormat = file.processingFormat
        fileBox.set(file)
        converterBox.set(nil)
        writeFailedFlag.withLock { $0 = false }
        let handler = bufferHandler
        handlerBox.withLock { $0 = handler }
        accumulatedElapsed = 0
        segmentStart = nil
        elapsed = 0

        // Fresh event stream for this recording.
        let stream = AsyncStream<RecordingEvent> { continuation in
            self.eventContinuation = continuation
        }
        eventStream = stream

        // Install the tap.
        installTap(format: inputFormat)

        // Start the engine.
        engine.prepare()
        do {
            try engine.start()
        } catch {
            removeTap()
            teardownEngine()
            fileBox.set(nil)
            AudioStorage.delete(fileName: name)
            fileName = nil
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            eventContinuation?.finish()
            eventContinuation = nil
            eventStream = nil
            throw RecordingError.engineStartFailed(error.localizedDescription)
        }

        // Go active.
        activeFlag.withLock { $0 = true }
        state = .recording
        registerObservers()
        startTimerSegment()
    }

    /// Installs the input-node tap. The closure is @Sendable and captures only
    /// Sendable boxes/locks — never `self`'s main-actor state directly.
    private func installTap(format: AVAudioFormat) {
        let fileBox = self.fileBox
        let converterBox = self.converterBox
        let activeFlag = self.activeFlag
        let writeFailedFlag = self.writeFailedFlag
        let handlerBox = self.handlerBox

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            // Only write/forward while actively capturing.
            guard activeFlag.withLock({ $0 }) else { return }

            fileBox.withFile { file in
                guard let file else { return }
                do {
                    if let converter = converterBox.get() {
                        let outFormat = file.processingFormat
                        let ratio = outFormat.sampleRate / buffer.format.sampleRate
                        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
                        guard let outBuffer = AVAudioPCMBuffer(
                            pcmFormat: outFormat,
                            frameCapacity: capacity
                        ) else { return }

                        var fed = false
                        var convErr: NSError?
                        let status = converter.convert(to: outBuffer, error: &convErr) { _, inputStatus in
                            if fed {
                                inputStatus.pointee = .noDataNow
                                return nil
                            }
                            fed = true
                            inputStatus.pointee = .haveData
                            return buffer
                        }
                        if status == .error { if let convErr { throw convErr } }
                        if outBuffer.frameLength > 0 {
                            try file.write(from: outBuffer)
                        }
                    } else {
                        try file.write(from: buffer)
                    }
                } catch {
                    // Yield .failed exactly once, then keep best-effort going.
                    let firstFailure = writeFailedFlag.withLock { failed -> Bool in
                        if failed { return false }
                        failed = true
                        return true
                    }
                    if firstFailure {
                        let message = error.localizedDescription
                        Task { @MainActor [weak self] in
                            self?.yield(.failed(message: message))
                        }
                    }
                }
            }

            // Forward to the live transcription handler.
            handlerBox.withLock { $0 }?(buffer)
        }
        tapInstalled = true
    }

    private func removeTap() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    /// Re-points the input tap (and any needed format converter) at the
    /// hardware's current input format. Safe whether or not the engine is
    /// running — the caller owns engine start/stop around this. Used on every
    /// restart (resume, interruption-end) and on route changes, so the tap and
    /// converter always match the live input even if it changed while paused.
    private func reconcileInputFormat() {
        removeTap()
        let newFormat = engine.inputNode.outputFormat(forBus: 0)
        if let fileFormat = fileProcessingFormat, fileFormat != newFormat {
            if let converter = AVAudioConverter(from: newFormat, to: fileFormat) {
                converterBox.set(converter)
            } else {
                converterBox.set(nil)
                // Keep already-written audio; surface one failure, continue.
                yield(.failed(message: "The new microphone format could not be matched."))
            }
        } else {
            converterBox.set(nil)
        }
        installTap(format: newFormat)
    }

    // MARK: - Pause / Resume

    func pause() {
        guard state == .recording else { return }
        activeFlag.withLock { $0 = false }
        engine.pause() // Keep the session active so background resume works.
        accumulateSegment()
        stopTimer()
        state = .paused
    }

    func resume() throws {
        guard state == .paused || state == .interrupted else { return }
        // The input route may have changed while paused; re-point the tap at
        // the current hardware format before restarting.
        reconcileInputFormat()
        do {
            try engine.start()
        } catch {
            throw RecordingError.engineStartFailed(error.localizedDescription)
        }
        activeFlag.withLock { $0 = true }
        state = .recording
        startTimerSegment()
    }

    // MARK: - Stop / Discard

    func stop() async throws -> RecordingResult {
        let name = fileName
        let duration = teardown(deleteFile: false)

        guard let name else {
            throw RecordingError.nothingRecorded
        }

        if duration < 0.5 {
            AudioStorage.delete(fileName: name)
            throw RecordingError.nothingRecorded
        }
        return RecordingResult(fileName: name, duration: duration)
    }

    func discard() {
        _ = teardown(deleteFile: true)
    }

    /// Shared teardown for stop()/discard(). Returns the captured duration.
    /// Always finishes the events stream and returns the recorder to `.idle`.
    @discardableResult
    private func teardown(deleteFile: Bool) -> TimeInterval {
        // Freeze elapsed time before tearing down.
        if state == .recording { accumulateSegment() }
        stopTimer()
        let duration = accumulatedElapsed

        activeFlag.withLock { $0 = false }
        removeTap()
        teardownEngine()

        // Flush + close the file.
        fileBox.set(nil)
        converterBox.set(nil)

        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)

        unregisterObservers()

        eventContinuation?.finish()
        eventContinuation = nil
        eventStream = nil

        if deleteFile {
            AudioStorage.delete(fileName: fileName)
        }
        fileName = nil
        fileProcessingFormat = nil
        accumulatedElapsed = 0
        segmentStart = nil
        elapsed = 0
        state = .idle
        return duration
    }

    private func teardownEngine() {
        if engine.isRunning { engine.stop() }
    }

    // MARK: - Timer / elapsed

    private func startTimerSegment() {
        segmentStart = Date()
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.elapsed = self.currentElapsed()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        elapsed = currentElapsed()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// Moves the running segment into the accumulator (used on pause/stop).
    private func accumulateSegment() {
        if let start = segmentStart {
            accumulatedElapsed += Date().timeIntervalSince(start)
            segmentStart = nil
        }
    }

    private func currentElapsed() -> TimeInterval {
        if let start = segmentStart {
            return accumulatedElapsed + Date().timeIntervalSince(start)
        }
        return accumulatedElapsed
    }

    // MARK: - Events

    private func yield(_ event: RecordingEvent) {
        eventContinuation?.yield(event)
    }

    // MARK: - Notifications

    private func registerObservers() {
        let center = NotificationCenter.default
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.handleInterruption(note)
            }
        }
        routeChangeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.handleRouteChange(note)
            }
        }
    }

    private func unregisterObservers() {
        let center = NotificationCenter.default
        if let interruptionObserver {
            center.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        if let routeChangeObserver {
            center.removeObserver(routeChangeObserver)
            self.routeChangeObserver = nil
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard
            let info = note.userInfo,
            let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        switch type {
        case .began:
            guard state == .recording else { return }
            activeFlag.withLock { $0 = false }
            engine.pause()
            accumulateSegment()
            stopTimer()
            state = .interrupted
            yield(.interruptionBegan)

        case .ended:
            guard state == .interrupted else { return }
            var shouldResume = false
            if let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
                shouldResume = options.contains(.shouldResume)
            }
            if shouldResume {
                try? AVAudioSession.sharedInstance().setActive(true)
                // The route/format may have changed during the interruption
                // (a call may have connected AirPods); reconcile before restart.
                reconcileInputFormat()
                do {
                    try engine.start()
                    activeFlag.withLock { $0 = true }
                    state = .recording
                    startTimerSegment()
                    yield(.interruptionEnded(shouldResume: true))
                } catch {
                    state = .paused
                    yield(.interruptionEnded(shouldResume: false))
                }
            } else {
                state = .paused
                yield(.interruptionEnded(shouldResume: false))
            }

        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard
            let info = note.userInfo,
            let rawReason = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
        else { return }

        guard reason == .newDeviceAvailable || reason == .oldDeviceUnavailable else { return }
        // Handle the change whether recording or paused/interrupted, so a tap
        // bound to the old format is never carried into a later resume.
        guard state == .recording || state == .paused || state == .interrupted else { return }

        let wasRunning = engine.isRunning
        if wasRunning { engine.pause() }

        reconcileInputFormat()

        // Only restart if we were actively running; a paused/interrupted
        // recording stays paused with its tap now matching the new input.
        if wasRunning {
            try? engine.start()
        }

        let inputName = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "the current input"
        yield(.routeChanged(description: inputName))
    }

    // MARK: - Cleanup

    deinit {
        // deinit is nonisolated. Remove observer tokens and invalidate the
        // timer directly (these calls are thread-safe). Do not touch the
        // main-actor engine teardown here.
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
        timer?.invalidate()
        eventContinuation?.finish()
    }
}
