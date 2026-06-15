import Foundation
import Observation
import Speech

/// Drives the Settings page: the Gemini key (keychain only, never logged),
/// the minutes model choice, the transcription language, and the
/// remove-everything action.
@MainActor
@Observable
final class SettingsModel {
    enum KeyValidation: Equatable {
        case idle
        case validating
        case accepted
        case failed(String)
    }

    struct TranscriptionLanguage: Identifiable, Hashable {
        /// Locale identifier, e.g. "en-US".
        let id: String
        /// Display name in the user's own language.
        let name: String
    }

    /// The contents of the key field. Persisted to the keychain on every
    /// change; deliberately never written to UserDefaults or logged.
    var keyField = ""
    var hasStoredKey = false
    var keyValidation: KeyValidation = .idle
    var confirmingRemoveAll = false

    let settings: AppSettings
    /// Languages the speech recognizer supports, sorted by display name.
    let transcriptionLanguages: [TranscriptionLanguage]

    private let services: AppServices
    private var hasLoadedKey = false

    init(services: AppServices) {
        self.services = services
        self.settings = services.settings

        var languages = SFSpeechRecognizer.supportedLocales().map { locale in
            TranscriptionLanguage(
                id: locale.identifier,
                name: Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
            )
        }

        // The stored preference can spell the identifier differently than
        // the recognizer does ("en_US" vs "en-US"). Prefer the recognizer's
        // spelling; failing that, keep the stored value selectable so the
        // picker never shows an empty selection.
        let storedID = services.settings.transcriptionLocaleID
        if !languages.contains(where: { $0.id == storedID }) {
            if let match = languages.first(where: { Self.normalized($0.id) == Self.normalized(storedID) }) {
                services.settings.transcriptionLocaleID = match.id
            } else {
                languages.append(TranscriptionLanguage(
                    id: storedID,
                    name: Locale.current.localizedString(forIdentifier: storedID) ?? storedID
                ))
            }
        }

        self.transcriptionLanguages = languages.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var canValidate: Bool {
        !keyField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && keyValidation != .validating
    }

    /// Loads the saved key into the field once, on first appearance.
    func loadKey() {
        guard !hasLoadedKey else { return }
        hasLoadedKey = true
        if let key = services.keychain.apiKey(for: .gemini) {
            keyField = key
            hasStoredKey = true
        }
    }

    /// Called whenever the field changes: persist quietly and let any
    /// earlier verdict lapse, since it no longer describes this key.
    func keyFieldChanged() {
        if keyValidation != .validating {
            keyValidation = .idle
        }
        persistKey()
    }

    func persistKey() {
        let trimmed = keyField.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            services.keychain.deleteAPIKey(for: .gemini)
            hasStoredKey = false
        } else {
            services.keychain.setAPIKey(trimmed, for: .gemini)
            hasStoredKey = true
        }
    }

    func validate() async {
        let key = keyField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            keyValidation = .failed(LLMError.missingKey.errorDescription ?? "")
            return
        }
        persistKey()
        keyValidation = .validating
        do {
            try await services.llm.validateKey(key)
            keyValidation = .accepted
        } catch {
            let message = (error as? LLMError)?.errorDescription
                ?? "The service had trouble answering. Try again shortly."
            keyValidation = .failed(message)
        }
    }

    func removeKey() {
        services.keychain.deleteAPIKey(for: .gemini)
        keyField = ""
        hasStoredKey = false
        keyValidation = .idle
    }

    func removeEverything() {
        services.notesStore.deleteAllData()
        services.keychain.deleteAll()
        services.settings.resetAll()
        keyField = ""
        hasStoredKey = false
        keyValidation = .idle
    }

    private static func normalized(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}
