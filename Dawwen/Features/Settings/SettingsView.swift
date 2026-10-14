import SwiftUI
import Translation

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.sourceLanguage) private var language = "en-US"
    @AppStorage(SettingsKey.engine) private var engineRaw = EngineKind.auto.rawValue
    @AppStorage(SettingsKey.translationEnabled) private var translationEnabled = true
    @AppStorage(SettingsKey.targetLanguage) private var targetLanguage = "ar"
    @AppStorage(SettingsKey.claudeModel) private var modelRaw = ClaudeModelOption.sonnet.rawValue
    @AppStorage(SettingsKey.askModel) private var askModelRaw = ClaudeModelOption.haiku.rawValue
    @AppStorage(SettingsKey.refineModel) private var refineModelRaw = ClaudeModelOption.haiku.rawValue
    @AppStorage(SettingsKey.summaryLanguage) private var summaryLanguage = "en"
    @AppStorage(SettingsKey.bilingualAnswers) private var bilingualAnswers = true
    @AppStorage(SettingsKey.keepScreenOn) private var keepScreenOn = true
    @AppStorage(SettingsKey.allowBluetoothMic) private var allowBluetoothMic = false
    @AppStorage(SettingsKey.vocabulary) private var vocabulary = ""
    @AppStorage(SettingsKey.glossary) private var glossary = ""
    @AppStorage(SettingsKey.gatewayURL) private var gatewayURL = ""
    @AppStorage(SettingsKey.claudeViaGateway) private var claudeViaGateway = false
    @AppStorage(SettingsKey.sonioxViaGateway) private var sonioxViaGateway = false
    @AppStorage(SettingsKey.backupEnabled) private var backupEnabled = false
    @AppStorage(SettingsKey.refineEngine) private var refineEngine = "now"
    @State private var anthropicKey = ""
    @State private var sonioxKey = ""
    @State private var gatewayToken = ""
    @State private var freeKeys: [KeychainStore.Key: String] = [:]
    @State private var keyTestResult: String?
    @State private var testingKeys = false
    @State private var loaded = false
    @State private var speechStatus: String?
    @State private var translationStatus: String?
    @State private var translationPreparation: TranslationSession.Configuration?

    private var engine: EngineKind { EngineKind(rawValue: engineRaw) ?? .auto }
    private var model: AIModel { AIModel(rawValue: modelRaw) ?? .claude(.sonnet) }
    private static let freeKeyNames: [KeychainStore.Key] = FreeLLM.Provider.allCases.map(\.keychainKey) + [.cloudflareAccount]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Default lecture language", selection: $language) {
                        ForEach(Languages.lecture) { Text($0.name).tag($0.id) }
                    }
                    Picker("Transcription engine", selection: $engineRaw) {
                        ForEach(EngineKind.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Button("Download the transcription model for offline use") {
                        Task { await prepareSpeech() }
                    }
                    if let speechStatus {
                        Text(speechStatus).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Transcription")
                } footer: {
                    Text(engine.detail)
                }

                Section {
                    TextEditor(text: $vocabulary)
                        .frame(minHeight: 90)
                        .environment(\.layoutDirection, vocabulary.isMostlyRTL ? .rightToLeft : .leftToRight)
                } header: {
                    Text("Course vocabulary")
                } footer: {
                    Text("One term per line (names, concepts, abbreviations) to help the transcriber spell them correctly.")
                }

                Section {
                    Toggle("Live translation by default", isOn: $translationEnabled)
                    Picker("Translation language", selection: $targetLanguage) {
                        ForEach(Languages.translation) { Text($0.name).tag($0.id) }
                    }
                    Button("Download both translation languages now (once, before lectures)") {
                        prepareTranslation()
                    }
                    if let translationStatus {
                        Text(translationStatus).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Translation")
                } footer: {
                    Text("On-device translation is free and works offline, but it won't run during a lecture unless both languages are downloaded.")
                }
                .translationTask(translationPreparation) { session in
                    do {
                        try await session.prepareTranslation()
                        translationStatus = "Both languages are ready offline."
                    } catch {
                        translationStatus = "Download failed: \(error.localizedDescription)"
                    }
                }

                Section {
                    TextEditor(text: $glossary)
                        .frame(minHeight: 90)
                        .environment(\.layoutDirection, .leftToRight)
                    Picker("Refinement model", selection: $refineModelRaw) {
                        modelChoices
                    }
                    Picker("Refinement method", selection: $refineEngine) {
                        Text("Now, from the iPad").tag("now")
                        Text("Later at half price (server, Batch)").tag("claude-batch")
                        Text("Home server (local model)").tag("home")
                    }
                } header: {
                    Text("Refine translation after the lecture")
                } footer: {
                    Text("One line per term: English term = translated term. The refinement pass uses it to keep terms consistent across all lectures.")
                }

                Section {
                    Picker("Summary model", selection: $modelRaw) {
                        modelChoices
                    }
                    LabeledContent("Price", value: model.priceNote)
                    Picker("Ask model", selection: $askModelRaw) {
                        modelChoices
                    }
                    Picker("Summary and answer language", selection: $summaryLanguage) {
                        ForEach(Languages.translation) { Text($0.name).tag($0.id) }
                    }
                    Toggle("Answer questions in both Arabic and English", isOn: $bilingualAnswers)
                } header: {
                    Text("AI models")
                } footer: {
                    Text("Each task can use Claude or a free model. The ask model also answers Ask AI while recording; Claude Haiku or Groq reply fastest there. Answers adapt to the question: short for quick ones, step by step with examples when you ask to understand something.")
                }

                Section {
                    SecureField("Claude API key", text: $anthropicKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Claude (optional)")
                } footer: {
                    Text("Get the key from console.anthropic.com. It is stored in this device's Keychain. Not needed if you use Claude through the server.")
                }

                Section {
                    ForEach(FreeLLM.Provider.allCases) { provider in
                        SecureField("\(provider.title) key", text: freeKey(provider.keychainKey))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    TextField("Cloudflare account ID", text: freeKey(.cloudflareAccount))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .environment(\.layoutDirection, .leftToRight)
                    Button("Paste keys copied from a free-llms .env file") {
                        pasteEnvKeys()
                    }
                    Button(testingKeys ? "Testing…" : "Test free keys") {
                        Task { await testFreeKeys() }
                    }
                    .disabled(testingKeys)
                    if let keyTestResult {
                        Text(keyTestResult)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("Free models (optional)")
                } footer: {
                    Text("One key is enough. With several, \"Free models (automatic)\" moves on to the next provider when one reaches its daily limit. Keys are free and stay in this device's Keychain. Free tiers may use what you send to improve their models.\n\n"
                         + FreeLLM.Provider.allCases.map { "\($0.title): \($0.keyPage)" }.joined(separator: "\n"))
                }

                Section {
                    SecureField("Soniox key", text: $sonioxKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Soniox (optional)")
                } footer: {
                    Text("For higher accuracy and speaker labels: about $0.12 per hour, with no free credit for new accounts.")
                }

                Section {
                    TextField("https://…lambda-url…on.aws", text: $gatewayURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .environment(\.layoutDirection, .leftToRight)
                    SecureField("Device token", text: $gatewayToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Claude through the server (key and spending cap live there)", isOn: $claudeViaGateway)
                    Toggle("Soniox with temporary keys from the server", isOn: $sonioxViaGateway)
                    Toggle("Back up audio and text to the server", isOn: $backupEnabled)
                } header: {
                    Text("Server (optional)")
                } footer: {
                    Text("Recording, transcription and translation never need the server. Get the token from the issue_device_token.py tool.")
                }

                Section("While recording") {
                    Toggle("Keep the screen on", isOn: $keepScreenOn)
                    Toggle("Allow Bluetooth microphones (lower quality)", isOn: $allowBluetoothMic)
                }

                Section("Privacy") {
                    Text("Audio and text stay on this iPad. Nothing leaves it except: audio to Soniox if you choose it, text to Anthropic or to the free model's provider you picked when you ask for a summary, an answer or a translation refinement, and the backup to your AWS account if you turn it on.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                anthropicKey = KeychainStore.read(.anthropic) ?? ""
                sonioxKey = KeychainStore.read(.soniox) ?? ""
                gatewayToken = KeychainStore.read(.gatewayToken) ?? ""
                for key in Self.freeKeyNames { freeKeys[key] = KeychainStore.read(key) ?? "" }
                loaded = true
            }
            // Saved as typed, so a crash or a swipe never loses a key.
            .onChange(of: anthropicKey) { if loaded { KeychainStore.save(anthropicKey, for: .anthropic) } }
            .onChange(of: sonioxKey) { if loaded { KeychainStore.save(sonioxKey, for: .soniox) } }
            .onChange(of: gatewayToken) { if loaded { KeychainStore.save(gatewayToken, for: .gatewayToken) } }
            .task(id: targetLanguage) { await refreshTranslationStatus() }
        }
    }

    /// Claude and the free models, grouped, for the three model pickers.
    @ViewBuilder private var modelChoices: some View {
        Section("Claude") {
            ForEach(ClaudeModelOption.allCases) { Text($0.title).tag($0.rawValue) }
        }
        Section("Free") {
            ForEach(AIModel.freeCases) { Text($0.title).tag($0.rawValue) }
        }
    }

    /// Reads `NAME=value` lines (the free-llms .env, copied on the Mac and pasted here through
    /// Universal Clipboard) into the key fields, which save them to the Keychain.
    private func pasteEnvKeys() {
        let added = FreeLLM.importKeys(fromEnv: UIPasteboard.general.string ?? "")
        for key in Self.freeKeyNames { freeKeys[key] = KeychainStore.read(key) ?? "" }
        keyTestResult = added.isEmpty
            ? "No keys found. On the Mac, copy the whole .env file (lines like GROQ_API_KEY=…), then tap the button again."
            : "Added \(added.joined(separator: ", ")). Tap Test free keys to check them."
    }

    /// Every provider at once; one line each, in the order of the key fields.
    private func testFreeKeys() async {
        testingKeys = true
        let lines = await withTaskGroup(of: (Int, String).self) { group in
            for (index, provider) in FreeLLM.Provider.allCases.enumerated() {
                group.addTask { (index, "\(provider.title): \(await FreeLLM.test(provider))") }
            }
            var results: [(Int, String)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
        keyTestResult = lines.joined(separator: "\n")
        testingKeys = false
    }

    /// A free provider's key, saved to the Keychain as typed, like the other keys.
    private func freeKey(_ key: KeychainStore.Key) -> Binding<String> {
        Binding(
            get: { freeKeys[key] ?? "" },
            set: { value in
                freeKeys[key] = value
                if loaded { KeychainStore.save(value, for: key) }
            }
        )
    }

    private func prepareSpeech() async {
        speechStatus = "Preparing the model…"
        guard let module = await AppleSpeechEngine.makeModule(for: Locale(identifier: language), live: true) else {
            speechStatus = "This device doesn't support on-device transcription for \(Languages.name(for: language))."
            return
        }
        do {
            try await AppleSpeechEngine.installAssets(for: module.speechModule) { _ in }
            speechStatus = "\(module.name): the \(Languages.name(for: language)) model is ready offline."
        } catch {
            speechStatus = "Download failed: \(error.localizedDescription)"
        }
    }

    private func prepareTranslation() {
        let configuration = TranslationSession.Configuration(
            source: Locale.Language(identifier: language), target: Locale.Language(identifier: targetLanguage)
        )
        if translationPreparation == nil {
            translationPreparation = configuration
        } else {
            translationPreparation = configuration
            translationPreparation?.invalidate()
        }
    }

    private func refreshTranslationStatus() async {
        switch await TranslationSupport.status(source: language, target: targetLanguage) {
        case .installed: translationStatus = "Both languages are downloaded and ready offline."
        case .supported: translationStatus = "Supported but not downloaded yet: tap the download button."
        case .unsupported: translationStatus = "Apple Translation doesn't support this language pair."
        @unknown default: translationStatus = nil
        }
    }
}
