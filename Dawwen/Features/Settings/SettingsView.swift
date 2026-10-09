import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.sourceLanguage) private var language = "en-US"
    @AppStorage(SettingsKey.engine) private var engineRaw = EngineKind.auto.rawValue
    @AppStorage(SettingsKey.translationEnabled) private var translationEnabled = true
    @AppStorage(SettingsKey.targetLanguage) private var targetLanguage = "ar"
    @AppStorage(SettingsKey.claudeModel) private var modelRaw = ClaudeModelOption.opus.rawValue
    @AppStorage(SettingsKey.summaryLanguage) private var summaryLanguage = "ar"
    @AppStorage(SettingsKey.keepScreenOn) private var keepScreenOn = true
    @AppStorage(SettingsKey.vocabulary) private var vocabulary = ""
    @State private var anthropicKey = ""
    @State private var sonioxKey = ""

    private var engine: EngineKind { EngineKind(rawValue: engineRaw) ?? .auto }
    private var model: ClaudeModelOption { ClaudeModelOption(rawValue: modelRaw) ?? .opus }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("لغة المحاضرة الافتراضية", selection: $language) {
                        ForEach(Languages.lecture) { Text($0.name).tag($0.id) }
                    }
                    Picker("محرك التفريغ", selection: $engineRaw) {
                        ForEach(EngineKind.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                } header: {
                    Text("التفريغ")
                } footer: {
                    Text(engine.detail)
                }

                Section {
                    TextEditor(text: $vocabulary)
                        .frame(minHeight: 90)
                        .environment(\.layoutDirection, vocabulary.isMostlyRTL ? .rightToLeft : .leftToRight)
                } header: {
                    Text("مصطلحات المادة")
                } footer: {
                    Text("مصطلح في كل سطر (أسماء، مفاهيم، اختصارات) لتحسين دقة كتابتها.")
                }

                Section("الترجمة") {
                    Toggle("ترجمة لحظية افتراضياً", isOn: $translationEnabled)
                    Picker("لغة الترجمة", selection: $targetLanguage) {
                        ForEach(Languages.translation) { Text($0.name).tag($0.id) }
                    }
                }

                Section {
                    Picker("النموذج", selection: $modelRaw) {
                        ForEach(ClaudeModelOption.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    LabeledContent("السعر", value: model.priceNote)
                    Picker("لغة الملخص", selection: $summaryLanguage) {
                        ForEach(Languages.translation) { Text($0.name).tag($0.id) }
                    }
                    SecureField("مفتاح Claude API", text: $anthropicKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("التلخيص والأسئلة (Claude)")
                } footer: {
                    Text("المفتاح من console.anthropic.com، ويُحفظ في Keychain هذا الجهاز فقط.")
                }

                Section {
                    SecureField("مفتاح Soniox", text: $sonioxKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Soniox (تفريغ العربية)")
                } footer: {
                    Text("من console.soniox.com. التفريغ اللحظي بـ 0.12 $ للساعة، شاملاً تمييز المتحدثين.")
                }

                Section("أثناء التسجيل") {
                    Toggle("إبقاء الشاشة مضاءة", isOn: $keepScreenOn)
                }

                Section("الخصوصية") {
                    Text("الصوت والنص محفوظان على هذا الآيباد. لا يُرسل شيء للخارج إلا الصوت عند اختيار Soniox، والنص عند طلب ملخص أو سؤال من Claude.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("الإعدادات")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("تم") { dismiss() }
                }
            }
            .onAppear {
                anthropicKey = KeychainStore.read(.anthropic) ?? ""
                sonioxKey = KeychainStore.read(.soniox) ?? ""
            }
            .onDisappear {
                KeychainStore.save(anthropicKey, for: .anthropic)
                KeychainStore.save(sonioxKey, for: .soniox)
            }
        }
    }
}
