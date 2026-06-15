import Foundation
import SwiftUI

/// The Settings page: your key, how minutes are written, the transcription
/// language, and what happens to your data.
struct SettingsView: View {
    @State private var model: SettingsModel
    @Bindable private var settings: AppSettings

    init(services: AppServices) {
        _model = State(initialValue: SettingsModel(services: services))
        _settings = Bindable(services.settings)
    }

    var body: some View {
        NavigationStack {
            List {
                keySection
                minutesSection
                transcriptionSection
                dataSection
                colophon
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .paperPage()
            .navigationTitle("Settings")
            .onAppear { model.loadKey() }
            .onChange(of: model.keyField) {
                model.keyFieldChanged()
            }
            .animation(Theme.fade, value: model.keyValidation)
            .animation(Theme.fade, value: model.hasStoredKey)
            .confirmationDialog(
                "This removes every recording, transcript, and minute, and your key. There is no undo.",
                isPresented: $model.confirmingRemoveAll,
                titleVisibility: .visible
            ) {
                Button("Remove everything", role: .destructive) {
                    model.removeEverything()
                }
                Button("Keep everything", role: .cancel) {}
            }
        }
    }

    // MARK: Your key

    private var keySection: some View {
        Section {
            SecureField("Your Gemini key", text: $model.keyField)
                .font(.nlChrome)
                .foregroundStyle(Color.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { model.persistKey() }

            HStack {
                Button("Validate key") {
                    Task { await model.validate() }
                }
                .font(.nlChrome)
                .foregroundStyle(model.canValidate ? Color.ink : Color.inkMuted)
                .disabled(!model.canValidate)

                Spacer()

                switch model.keyValidation {
                case .validating:
                    Text("Checking…")
                        .font(.nlLabel)
                        .tracking(1.4)
                        .foregroundStyle(Color.inkMuted)
                case .accepted:
                    Text("Key accepted")
                        .font(.nlLabel)
                        .tracking(1.4)
                        .foregroundStyle(Color.sage)
                case .idle, .failed:
                    EmptyView()
                }
            }

            if case .failed(let message) = model.keyValidation {
                Text(message)
                    .font(.nlChromeSmall)
                    .foregroundStyle(Color.inkMuted)
            }

            if model.hasStoredKey {
                Button("Remove key") {
                    model.removeKey()
                }
                .font(.nlChrome)
                .foregroundStyle(Color.vermillion)
            }
        } header: {
            SectionLabel("Your Key")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Minutes, answers, and prep notes are written by Google's Gemini service, using your own free key. Recordings and transcripts stay on this device, and are sent to Google only when you ask for one of those.")
                Link(
                    "Get a free key from Google",
                    destination: URL(string: "https://aistudio.google.com/apikey")!
                )
                .foregroundStyle(Color.vermillion)
            }
            .font(.nlChromeSmall)
            .foregroundStyle(Color.inkMuted)
        }
        .listRowBackground(Color.paperRaised)
        .listRowSeparatorTint(Color.inkHairline)
    }

    // MARK: Minutes

    private var minutesSection: some View {
        Section {
            Picker("Model", selection: $settings.geminiModel) {
                ForEach(AppSettings.geminiModels, id: \.self) { id in
                    Text(id).tag(id)
                }
            }
            .pickerStyle(.menu)
            .tint(Color.ink)
            .font(.nlChrome)
            .foregroundStyle(Color.ink)
        } header: {
            SectionLabel("Minutes")
        }
        .listRowBackground(Color.paperRaised)
        .listRowSeparatorTint(Color.inkHairline)
    }

    // MARK: Transcription

    private var transcriptionSection: some View {
        Section {
            Picker("Language", selection: $settings.transcriptionLocaleID) {
                ForEach(model.transcriptionLanguages) { language in
                    Text(language.name).tag(language.id)
                }
            }
            .pickerStyle(.menu)
            .tint(Color.ink)
            .font(.nlChrome)
            .foregroundStyle(Color.ink)
        } header: {
            SectionLabel("Transcription")
        } footer: {
            Text("Transcription happens on this device when the language allows. On-device support varies by language.")
                .font(.nlChromeSmall)
                .foregroundStyle(Color.inkMuted)
        }
        .listRowBackground(Color.paperRaised)
        .listRowSeparatorTint(Color.inkHairline)
    }

    // MARK: Your data

    private var dataSection: some View {
        Section {
            Button("Remove everything") {
                model.confirmingRemoveAll = true
            }
            .font(.nlChrome)
            .foregroundStyle(Color.vermillion)
        } header: {
            SectionLabel("Your Data")
        } footer: {
            Text("Recordings, transcripts, and minutes are kept on this device, and nowhere else. They are yours to keep — or to remove, completely.")
                .font(.nlProseSmall)
                .foregroundStyle(Color.inkMuted)
        }
        .listRowBackground(Color.paperRaised)
        .listRowSeparatorTint(Color.inkHairline)
    }

    // MARK: Colophon

    private var colophon: some View {
        Section {
        } footer: {
            Text("Notelore — a second memory, kept on paper.")
                .font(.nlChromeSmall)
                .foregroundStyle(Color.inkMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 8)
        }
    }
}
