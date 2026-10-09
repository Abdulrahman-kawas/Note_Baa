import SwiftUI

struct NewLectureSheet: View {
    var onStart: (NewLectureRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.sourceLanguage) private var language = "en-US"
    @AppStorage(SettingsKey.translationEnabled) private var translationEnabled = true
    @AppStorage(SettingsKey.targetLanguage) private var targetLanguage = "ar"
    @AppStorage(SettingsKey.engine) private var engineRaw = EngineKind.auto.rawValue
    @State private var title = "محاضرة " + Date.now.formatted(.dateTime.day().month(.wide))

    private var engine: EngineKind { EngineKind(rawValue: engineRaw) ?? .auto }

    var body: some View {
        NavigationStack {
            Form {
                Section("المحاضرة") {
                    TextField("العنوان", text: $title)
                    Picker("لغة المحاضرة", selection: $language) {
                        ForEach(Languages.lecture) { option in
                            Text(option.name).tag(option.id)
                        }
                    }
                }
                Section {
                    Picker("محرك التفريغ", selection: $engineRaw) {
                        ForEach(EngineKind.allCases) { kind in
                            Text(kind.title).tag(kind.rawValue)
                        }
                    }
                } footer: {
                    Text(engine.detail)
                }
                Section("الترجمة اللحظية") {
                    Toggle("ترجمة كل جملة", isOn: $translationEnabled)
                    if translationEnabled {
                        Picker("إلى", selection: $targetLanguage) {
                            ForEach(Languages.translation) { option in
                                Text(option.name).tag(option.id)
                            }
                        }
                    }
                }
                Section {
                    Label("ضع الآيباد قريباً من المحاضر وصِله بالشاحن للمحاضرات الطويلة.", systemImage: "lightbulb")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("تسجيل جديد")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("ابدأ") {
                        let trimmed = title.trimmingCharacters(in: .whitespaces)
                        onStart(NewLectureRequest(
                            title: trimmed.isEmpty ? "محاضرة" : trimmed,
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
