import SwiftUI

struct NewLectureSheet: View {
    var onStart: (NewLectureRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.sourceLanguage) private var language = "en-US"
    @AppStorage(SettingsKey.translationEnabled) private var translationEnabled = true
    @AppStorage(SettingsKey.targetLanguage) private var targetLanguage = "ar"
    @AppStorage(SettingsKey.engine) private var engineRaw = EngineKind.auto.rawValue
    @State private var title = "Lecture " + Date.now.formatted(.dateTime.day().month(.wide))

    private var engine: EngineKind { EngineKind(rawValue: engineRaw) ?? .auto }

    var body: some View {
        NavigationStack {
            Form {
                Section("Lecture") {
                    TextField("Title", text: $title)
                    Picker("Lecture language", selection: $language) {
                        ForEach(Languages.lecture) { option in
                            Text(option.name).tag(option.id)
                        }
                    }
                }
                Section {
                    Picker("Transcription engine", selection: $engineRaw) {
                        ForEach(EngineKind.allCases) { kind in
                            Text(kind.title).tag(kind.rawValue)
                        }
                    }
                } footer: {
                    Text(engine.detail)
                }
                Section("Live translation") {
                    Toggle("Translate every sentence", isOn: $translationEnabled)
                    if translationEnabled {
                        Picker("Into", selection: $targetLanguage) {
                            ForEach(Languages.translation) { option in
                                Text(option.name).tag(option.id)
                            }
                        }
                    }
                }
                Section {
                    Label("Put the iPad close to the lecturer, and plug it in for long lectures.", systemImage: "lightbulb")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New recording")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        let trimmed = title.trimmingCharacters(in: .whitespaces)
                        onStart(NewLectureRequest(
                            title: trimmed.isEmpty ? "Lecture" : trimmed,
                            language: language,
                            targetLanguage: translationEnabled ? targetLanguage : nil,
                            engine: engine
                        ))
                    }
                    .bold()
                }
            }
        }
    }
}
