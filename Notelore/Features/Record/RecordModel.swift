import AVFoundation
import Foundation
import Observation
import UIKit

/// Drives the Record screen: consent, permissions, the live recording,
/// and the save-and-distill hand-off into the library.
@MainActor
@Observable
final class RecordModel {
    enum Phase {
        case idle
        case recording
        case saving
        case saved(Session)
    }

    private(set) var phase: Phase = .idle
    /// A stable key for phase transitions (Session isn't Equatable).
    var phaseKey: Int {
        switch phase {
        case .idle: return 0
        case .recording: return 1
        case .saving: return 2
        case .saved: return 3
        }
    }

    /// One-time sheet before the very first recording.
    var showConsent = false
    /// Calm inline notice on the idle screen.
    private(set) var notice: String?
    /// True when the microphone was denied and Settings is the way out.
    private(set) var showsOpenSettings = false
    /// Whether the transcript is being written this session.
    private(set) var transcriptionActive = false
    /// Quiet note under the clock while recording (interruptions, etc.).
    private(set) var recordingNotice: String?
    /// Transient footnote for route changes; clears itself after ~3 s.
    private(set) var routeFootnote: String?
    /// Line shown on the saving screen.
    private(set) var savingMessage = "Saving…"
    /// Footnote on the saved screen ("Saved. …").
    private(set) var savedFootnote: String?

    private let services: AppServices
    private var recorder: any AudioRecordingService { services.recorder }
    private var transcriber: any TranscriptionService { services.transcriber }
    private var settings: AppSettings { services.settings }

    private var eventsTask: Task<Void, Never>?
    private var footnoteTask: Task<Void, Never>?

    init(services: AppServices) {
        self.services = services
    }

    // MARK: Observation pass-throughs for the view

    var isPaused: Bool { recorder.state != .recording }

    var snapshot: TranscriptSnapshot { transcriber.snapshot }

    /// mm:ss under an hour, h:mm:ss after.
    var elapsedText: String {
        let total = Int(recorder.elapsed)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    // MARK: Begin

    func beginTapped() {
        notice = nil
        showsOpenSettings = false
        if settings.hasAcknowledgedRecordingConsent {
            Task { await start() }
        } else {
            showConsent = true
        }
    }

    func consentAcknowledged() {
        settings.hasAcknowledgedRecordingConsent = true
        showConsent = false
        Task { await start() }
    }

    func consentDeclined() {
        showConsent = false
    }

    private func start() async {
        guard case .idle = phase else { return }
        notice = nil
        showsOpenSettings = false
        recordingNotice = nil
        routeFootnote = nil
        savedFootnote = nil

        guard await recorder.requestPermission() else {
            notice = "Notelore needs the microphone to record. You can allow it in Settings."
            showsOpenSettings = true
            return
        }

        // Transcription is best-effort: if speech permission or the locale's
        // recognizer is unavailable, the recording still goes ahead.
        let speechAllowed = await transcriber.requestPermission()
        let localeAvailable = transcriber.isAvailable(for: settings.transcriptionLocale)
        transcriptionActive = speechAllowed && localeAvailable
        if transcriptionActive {
            do {
                try transcriber.start(locale: settings.transcriptionLocale)
            } catch {
                transcriptionActive = false
            }
        }
        if transcriptionActive {
            recorder.bufferHandler = { [transcriber] buffer in
                transcriber.append(buffer)
            }
        } else {
            recorder.bufferHandler = nil
            recordingNotice = "The transcript can't be written this time — the recording itself will be kept."
        }

        do {
            try await recorder.start()
        } catch {
            if transcriptionActive { transcriber.cancel() }
            transcriptionActive = false
            recorder.bufferHandler = nil
            notice = (error as? LocalizedError)?.errorDescription
                ?? "The microphone could not be started. Try again."
            return
        }

        phase = .recording
        UIApplication.shared.isIdleTimerDisabled = true
        subscribeToEvents()
    }

    // MARK: Recording events

    private func subscribeToEvents() {
        eventsTask?.cancel()
        let events = recorder.events
        eventsTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: RecordingEvent) async {
        switch event {
        case .interruptionBegan:
            recordingNotice = "Paused for an interruption — a call or Siri."
        case .interruptionEnded(let shouldResume):
            recordingNotice = shouldResume ? nil : "Resume when you're ready."
        case .routeChanged(let description):
            showRouteFootnote("Now listening through \(description).")
        case .failed(let message):
            // Capture is gone; keep what was written so far.
            recordingNotice = message
            await endRecording()
        }
    }

    private func showRouteFootnote(_ text: String) {
        footnoteTask?.cancel()
        routeFootnote = text
        footnoteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.routeFootnote = nil
        }
    }

    // MARK: Pause / resume

    func togglePause() {
        switch recorder.state {
        case .recording:
            recorder.pause()
        case .paused, .interrupted:
            do {
                try recorder.resume()
                recordingNotice = nil
            } catch {
                recordingNotice = (error as? LocalizedError)?.errorDescription
                    ?? "The microphone could not be started. Try again."
            }
        case .idle:
            break
        }
    }

    // MARK: End

    func endTapped() {
        Task { await endRecording() }
    }

    private func endRecording() async {
        guard case .recording = phase else { return }
        phase = .saving
        savingMessage = "Saving…"
        UIApplication.shared.isIdleTimerDisabled = false
        eventsTask?.cancel()
        eventsTask = nil
        footnoteTask?.cancel()
        footnoteTask = nil
        routeFootnote = nil

        let result: RecordingResult
        do {
            result = try await recorder.stop()
        } catch RecordingError.nothingRecorded {
            cleanUpAfterFailedStop()
            notice = "Nothing was recorded."
            return
        } catch {
            cleanUpAfterFailedStop()
            notice = (error as? LocalizedError)?.errorDescription
                ?? "The recording could not be saved."
            return
        }
        recorder.bufferHandler = nil

        let utterances: [Utterance]
        if transcriptionActive {
            utterances = await transcriber.finish()
        } else {
            utterances = []
        }
        transcriptionActive = false
        recordingNotice = nil

        let session = services.notesStore.createSession(
            title: Self.defaultTitle(for: Date()),
            transcript: utterances,
            audioFileName: result.fileName,
            duration: result.duration,
            languageCode: settings.transcriptionLocaleID
        )

        var footnote: String?
        if services.keychain.apiKey(for: .gemini) == nil {
            footnote = "Saved. Add your key in Settings to have minutes written."
        } else if !utterances.isEmpty {
            savingMessage = "Writing the minutes…"
            do {
                try await services.distiller.distill(session)
            } catch let error as LLMError {
                footnote = "Saved. " + (error.errorDescription ?? "The minutes couldn't be written this time.")
            } catch {
                footnote = "Saved. The minutes couldn't be written this time."
            }
        }

        savedFootnote = footnote
        phase = .saved(session)
    }

    private func cleanUpAfterFailedStop() {
        transcriber.cancel()
        recorder.bufferHandler = nil
        transcriptionActive = false
        recordingNotice = nil
        phase = .idle
    }

    // MARK: Discard

    func discard() {
        eventsTask?.cancel()
        eventsTask = nil
        footnoteTask?.cancel()
        footnoteTask = nil
        recorder.discard()
        transcriber.cancel()
        recorder.bufferHandler = nil
        transcriptionActive = false
        recordingNotice = nil
        routeFootnote = nil
        UIApplication.shared.isIdleTimerDisabled = false
        phase = .idle
    }

    func recordAnother() {
        notice = nil
        savedFootnote = nil
        phase = .idle
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// The date in an editorial register, e.g. "Thursday 12 June, 2:41 PM".
    static func defaultTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "EEEE d MMMM, h:mm a"
        return formatter.string(from: date)
    }
}
