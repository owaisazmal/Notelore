import Foundation
import Observation

/// User preferences, backed by UserDefaults. The API key is deliberately
/// not here — it lives in KeychainStore.
@MainActor
@Observable
final class AppSettings {
    static let geminiModels = [
        "gemini-2.5-flash",
        "gemini-2.5-flash-lite",
        "gemini-2.5-pro",
    ]

    var geminiModel: String {
        didSet { defaults.set(geminiModel, forKey: Keys.geminiModel) }
    }
    /// Locale identifier used for transcription, e.g. "en-US".
    var transcriptionLocaleID: String {
        didSet { defaults.set(transcriptionLocaleID, forKey: Keys.transcriptionLocaleID) }
    }
    /// One-time reminder before the first recording: the user is responsible
    /// for getting consent to record where the law requires it.
    var hasAcknowledgedRecordingConsent: Bool {
        didSet { defaults.set(hasAcknowledgedRecordingConsent, forKey: Keys.consent) }
    }

    var transcriptionLocale: Locale { Locale(identifier: transcriptionLocaleID) }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.geminiModel = defaults.string(forKey: Keys.geminiModel) ?? Self.geminiModels[0]
        self.transcriptionLocaleID = defaults.string(forKey: Keys.transcriptionLocaleID)
            ?? Locale.current.identifier
        self.hasAcknowledgedRecordingConsent = defaults.bool(forKey: Keys.consent)
    }

    func resetAll() {
        geminiModel = Self.geminiModels[0]
        transcriptionLocaleID = Locale.current.identifier
        hasAcknowledgedRecordingConsent = false
    }

    private enum Keys {
        static let geminiModel = "settings.geminiModel"
        static let transcriptionLocaleID = "settings.transcriptionLocaleID"
        static let consent = "settings.hasAcknowledgedRecordingConsent"
    }
}
