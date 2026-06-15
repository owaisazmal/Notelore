import Foundation
import Observation
import SwiftData

/// The app's service container, created once at launch and handed to each
/// feature view. Views → view models → these services; nothing reaches
/// around the layer below it.
@MainActor
@Observable
final class AppServices {
    let settings: AppSettings
    let keychain: KeychainStore
    let recorder: any AudioRecordingService
    let transcriber: any TranscriptionService
    let llm: any LLMService
    let notesStore: NotesStore
    let distiller: Distiller

    init(modelContainer: ModelContainer) {
        let settings = AppSettings()
        let keychain = KeychainStore()
        let llm = GeminiService(keychain: keychain, settings: settings)
        let notesStore = NotesStore(context: modelContainer.mainContext)

        self.settings = settings
        self.keychain = keychain
        self.recorder = AudioEngineRecorder()
        self.transcriber = SpeechTranscriber()
        self.llm = llm
        self.notesStore = notesStore
        self.distiller = Distiller(llm: llm, store: notesStore)
    }
}
