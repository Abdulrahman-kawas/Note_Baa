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
    @AppStorage(SettingsKey.summaryLanguage) private var summaryLanguage = "ar"
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
    @State private var loaded = false
    @State private var speechStatus: String?
    @State private var translationStatus: String?
    @State private var translationPreparation: TranslationSession.Configuration?

    private var engine: EngineKind { EngineKind(rawValue: engineRaw) ?? .auto }
    private var model: ClaudeModelOption { ClaudeModelOption(rawValue: modelRaw) ?? .sonnet }

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
                    Button("نزّل نموذج التفريغ للعمل دون إنترنت") {
                        Task { await prepareSpeech() }
                    }
                    if let speechStatus {
                        Text(speechStatus).font(.footnote).foregroundStyle(.secondary)
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

                Section {
                    Toggle("ترجمة لحظية افتراضياً", isOn: $translationEnabled)
                    Picker("لغة الترجمة", selection: $targetLanguage) {
                        ForEach(Languages.translation) { Text($0.name).tag($0.id) }
                    }
                    Button("نزّل لغتي الترجمة الآن (مرة واحدة، قبل المحاضرات)") {
                        prepareTranslation()
                    }
                    if let translationStatus {
                        Text(translationStatus).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("الترجمة")
                } footer: {
                    Text("الترجمة على الجهاز مجانية ودون إنترنت، لكنها لا تعمل أثناء المحاضرة إن لم تكن اللغتان منزّلتين.")
                }
                .translationTask(translationPreparation) { session in
                    do {
                        try await session.prepareTranslation()
                        translationStatus = "اللغتان جاهزتان دون إنترنت."
                    } catch {
                        translationStatus = "تعذّر التنزيل: \(error.localizedDescription)"
                    }
                }

                Section {
                    TextEditor(text: $glossary)
                        .frame(minHeight: 90)
                        .environment(\.layoutDirection, .leftToRight)
                    Picker("نموذج التحسين", selection: $refineModelRaw) {
                        ForEach(ClaudeModelOption.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Picker("طريقة التحسين", selection: $refineEngine) {
                        Text("الآن من الآيباد").tag("now")
                        Text("لاحقاً بنصف السعر (خادم، Batch)").tag("claude-batch")
                        Text("الخادم المنزلي (نموذج محلي)").tag("home")
                    }
                } header: {
                    Text("تحسين الترجمة بعد المحاضرة")
                } footer: {
                    Text("سطر لكل مصطلح: English term = المصطلح العربي. يستخدمه التحسين بالسياق ليثبت المصطلحات في كل المحاضرات.")
                }

                Section {
                    Picker("نموذج الملخص", selection: $modelRaw) {
                        ForEach(ClaudeModelOption.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    LabeledContent("السعر", value: model.priceNote)
                    Picker("نموذج «اسأل»", selection: $askModelRaw) {
                        ForEach(ClaudeModelOption.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Picker("لغة الملخص", selection: $summaryLanguage) {
                        ForEach(Languages.translation) { Text($0.name).tag($0.id) }
                    }
                    SecureField("مفتاح Claude API", text: $anthropicKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Claude (اختياري)")
                } footer: {
                    Text("المفتاح من console.anthropic.com ويُحفظ في Keychain هذا الجهاز. لا حاجة له إن فعّلت Claude عبر الخادم.")
                }

                Section {
                    SecureField("مفتاح Soniox", text: $sonioxKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Soniox (اختياري)")
                } footer: {
                    Text("للدقة الأعلى وتمييز المتحدثين: نحو 0.12 $ للساعة، دون رصيد مجاني للحسابات الجديدة.")
                }

                Section {
                    TextField("https://…lambda-url…on.aws", text: $gatewayURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .environment(\.layoutDirection, .leftToRight)
                    SecureField("رمز الجهاز", text: $gatewayToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Claude عبر الخادم (المفتاح وسقف الإنفاق هناك)", isOn: $claudeViaGateway)
                    Toggle("Soniox بمفاتيح مؤقتة من الخادم", isOn: $sonioxViaGateway)
                    Toggle("نسخ احتياطي للصوت والنص إلى الخادم", isOn: $backupEnabled)
                } header: {
                    Text("الخادم (اختياري)")
                } footer: {
                    Text("التسجيل والتفريغ والترجمة لا تحتاج الخادم أبداً. الرمز من أداة issue_device_token.py.")
                }

                Section("أثناء التسجيل") {
                    Toggle("إبقاء الشاشة مضاءة", isOn: $keepScreenOn)
                    Toggle("السماح بمايكروفون بلوتوث (جودة أقل)", isOn: $allowBluetoothMic)
                }

                Section("الخصوصية") {
                    Text("الصوت والنص على هذا الآيباد. لا يغادره شيء إلا: الصوت إلى Soniox إن اخترته، والنص إلى Anthropic عند طلب ملخص أو سؤال أو تحسين ترجمة، والنسخة الاحتياطية إلى حسابك على AWS إن فعّلتها.")
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
                gatewayToken = KeychainStore.read(.gatewayToken) ?? ""
                loaded = true
            }
            // Saved as typed, so a crash or a swipe never loses a key.
            .onChange(of: anthropicKey) { if loaded { KeychainStore.save(anthropicKey, for: .anthropic) } }
            .onChange(of: sonioxKey) { if loaded { KeychainStore.save(sonioxKey, for: .soniox) } }
            .onChange(of: gatewayToken) { if loaded { KeychainStore.save(gatewayToken, for: .gatewayToken) } }
            .task(id: targetLanguage) { await refreshTranslationStatus() }
        }
    }

    private func prepareSpeech() async {
        speechStatus = "يجهّز النموذج…"
        guard let module = await AppleSpeechEngine.makeModule(for: Locale(identifier: language), live: true) else {
            speechStatus = "هذا الجهاز لا يدعم التفريغ على الجهاز لـ \(Languages.name(for: language))."
            return
        }
        do {
            try await AppleSpeechEngine.installAssets(for: module.speechModule) { _ in }
            speechStatus = "\(module.name): نموذج \(Languages.name(for: language)) جاهز دون إنترنت."
        } catch {
            speechStatus = "تعذّر التنزيل: \(error.localizedDescription)"
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
        case .installed: translationStatus = "اللغتان منزّلتان وجاهزتان دون إنترنت."
        case .supported: translationStatus = "مدعومة لكن غير منزّلة بعد: اضغط زر التنزيل."
        case .unsupported: translationStatus = "هذا الزوج غير مدعوم في Apple Translation."
        @unknown default: translationStatus = nil
        }
    }
}
