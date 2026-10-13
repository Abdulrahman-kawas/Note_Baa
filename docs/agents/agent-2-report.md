# تقرير الإيجنت الثاني — مهندس البنية التحتية والخادم

> **الموقف:** خادم ذاتي الاستضافة (AWS + Docker، وخادم منزلي في Docker) يشغّل نماذج مفتوحة ومجانية، مع مزامنة ونسخ احتياطي ووسيط آمن للمفاتيح وطابور مهام.
> **مع الإنصاف:** حيث يكون الجهاز أفضل فعلاً (الكتابة اللحظية، العمل دون إنترنت، الخصوصية، الكلفة) أقول ذلك صراحة.
>
> نطاق المراجعة: كل ملفات Swift تحت `Dawwen/` (3,922 سطراً، 32 ملفاً)، و`README.md`، و`Config/Info.plist`، و`Dawwen.xcodeproj/project.pbxproj`. الفرع: `claude/exciting-curie-7sr685`. تاريخ التقرير: 2026-10-13.

---

## 1. ملخص تنفيذي

1. **الكود جيد البناء ومعقول الحجم**، وفيه قرارات ناضجة: تسجيل على أجزاء مدة كل منها 5 دقائق، واستمرار التسجيل إذا فشل التفريغ، واستعادة المحاضرة بعد الانهيار، وملف حراري، وprompt caching. لكنه **لم يجهز بعد لاستعمال يومي كثيف**. فيه أخطاء تضيّع الصوت أو تؤخّر بدء التسجيل (البنود #1 و#2 و#3)، ولا نسخة احتياطية له خارج الآيباد، ولا ترحيل لمخطط البيانات، ولا اختبارات، ولا توقيع (`DEVELOPMENT_TEAM = ""`).
2. **العربية نقطة الضعف الأساسية في المسار "المجاني على الجهاز":**
   - `SpeechTranscriber` لا يدعم العربية (الكود نفسه يوثّق ذلك في `AppleSpeechEngine.swift:57-59`)، فيبقى `DictationTranscriber` الأضعف في المحاضرات البعيدة عن الميكروفون.
   - Apple Intelligence لا يدعم العربية (`OnDeviceSummarizer.swift:8`)، ولم أجد ما يثبت أنه أضافها حتى iOS 26.1 ([9to5mac](https://9to5mac.com/2025/11/11/ios-26-1-brings-apple-intelligence-to-these-eight-new-languages/)).
   - النتيجة: **كل ملخص لمحاضرة عربية يمر اليوم بـ Claude المدفوع إجبارياً**، والتفريغ الجيد بالعربية يمر بـ Soniox المدفوع.
3. **أين يضيف الخادم قيمة لا يقدّمها الجهاز:**
   - **(أ) تفريغ ثانٍ عالي الجودة بعد المحاضرة** بنموذج عربي مفتوح. أقوى نموذج مفتوح حالياً هو `Cohere Transcribe Arabic 07-2026` (2B، Apache-2.0)، ومتوسط WER له 25.87 مقابل 36.86 لـ Whisper large-v3 على لوحة صدارة التفريغ العربي، وهي أرقام ينشرها المطوّر نفسه ([Cohere](https://cohere.com/blog/transcribe-arabic)، [Cohere docs](https://docs.cohere.com/docs/transcribe-arabic)).
   - **(ب) تلخيص وترجمة وأسئلة بنماذج مفتوحة** (Qwen3، MADLAD-400) دون كلفة لكل طلب.
   - **(ج) نسخ احتياطي ومزامنة**، فالمحاضرات كلها اليوم على جهاز واحد.
   - **(د) وسيط مفاتيح**: مفتاح Claude يبقى على الخادم، والخادم يصدر مفاتيح Soniox مؤقتة.
   - **(هـ) مهام طويلة تكمل حين يكون التطبيق في الخلفية**، مع إشعار عند انتهائها.
4. **التصميم المقترح:**
   - **طبقة تحكم صغيرة دائمة التشغيل على AWS** (Lightsail بـ 12 $، أو t4g.small) فيها: Caddy وFastAPI وPostgres وRedis.
   - **S3** للصوت.
   - **عامل GPU يُشغَّل عند الحاجة فقط** (EC2 `g6.xlarge` Spot بنحو 0.35–0.55 $/ساعة) ويُطفئ نفسه حين يفرغ.
   - الخادم المنزلي، إن وُجد، **يسحب المهام بنفسه عبر Tailscale** دون فتح أي منفذ.
   - الكلفة الواقعية لـ 88 ساعة صوت شهرياً: **نحو 22–35 $ شهرياً** للبنية. أما GPU دائم التشغيل (384–588 $ شهرياً) فمرفوض لمستخدم واحد.
5. **تنازلات صريحة:**
   - الكتابة اللحظية تبقى على الجهاز (Apple) أو في Soniox، لأن زمن الاستجابة مهم والقاعة قد تكون بلا إنترنت.
   - الترجمة اللحظية بـ Apple Translation جيدة ومجانية.
   - **التسجيل يجب ألا يعتمد على الخادم أبداً.** الخادم تحسين يأتي بعد المحاضرة، ويمكن إيقافه.
   - في الأشهر الأولى يكفي Soniox (~10.5 $ شهرياً لـ 88 ساعة) قبل بناء مسار GPU.

---

## 2. فهم الوضع الحالي للكود

### 2.1 الطبقات كما وُجدت

| الطبقة | الملفات | ما تفعله فعلاً |
|---|---|---|
| الدخول | `App/DawwenApp.swift:8-17` | يفتح `ModelContainer` لـ `Lecture` و`TranscriptSegment`، و**ينهار بـ `fatalError` إن فشل** (السطر 13)، ثم يستعيد المحاضرات المنقطعة. يفرض اتجاه RTL على كل الواجهة (السطر 22). |
| الإعدادات | `App/AppSettings.swift` | تُقرأ من `UserDefaults` عند بدء كل محاضرة. النموذج الافتراضي **Opus** (السطر 32). أسعار Claude مكتوبة يدوياً في الكود (121-128)، وتحققت أنها صحيحة: Opus 5.5 بـ 4/20 $، وSonnet 5.5 بـ 2/10 $، وHaiku 5.5 بـ 0.10/0.50 $ حتى 100K token، ثم 0.50/2.50 $ فوق ذلك. |
| النماذج | `Models/Lecture.swift`، `Models/TranscriptSegment.swift` | SwiftData. `@Attribute(.unique) var id` (السطر 12). الصوت مخزّن كأسماء ملفات `audioSegments` (السطر 24)، والعلامات `[Double]`، ويوجد `transcriptionIncomplete` لكنه **منطقي فقط ولا يحدد المقاطع الناقصة**. |
| التسجيل | `Audio/SegmentedRecorder.swift` | يركّب `AVAudioEngine` tap ويحوّل الصوت إلى 16 kHz mono Float32، ثم يكتب AAC بمعدل 32 kbps في ملفات `part-NNN.m4a` كل 300 ث (46، 170-189). نحو 14.4 MB للساعة. يمرر كل buffer للمفرّغ (142) ويعيد تركيب الـ tap عند تغيّر المسار (107-114). |
| جلسة الصوت | `Audio/AudioSessionController.swift` | الفئة `.record` لتسجيل الميكروفون المدمج (14)، مع مراقبة المقاطعات. |
| المنسّق | `Recording/RecordingController.swift` | التسلسل: إذن الميكروفون ← اختيار المحرك ← إنشاء `Lecture` ← **تشغيل المفرّغ (86) ثم المسجّل (90)** ← مراقبة الحرارة والبطارية والمقاطعات. يحفظ في SwiftData بعد كل جملة نهائية (237) ويضعها في طابور الترجمة (238). |
| التفريغ اللحظي | `Transcription/AppleSpeechEngine.swift`، `SonioxEngine.swift`، `TranscriptionEngine.swift` | يجرّب Apple `SpeechTranscriber` أولاً، ثم `DictationTranscriber` مع `.farField` للعربية (60-83). Soniox يعمل عبر WebSocket بـ `stt-rt-v5` مع diarization وkeepalive وإعادة اتصال أُسّية، ويحتفظ بـ 120 ث من الصوت أثناء الانقطاع (17-18، 157-172، 203-227). المحرك التلقائي يختار Soniox للعربية إن وُجد المفتاح (`TranscriptionEngine.swift:77-80`). |
| التفريغ من الملف | `Transcription/FileTranscriber.swift` | يمر على الأجزاء جزءاً جزءاً بمحلّل Apple، ويُضاف فرق التوقيت لكل جزء. |
| الترجمة | `Translation/TranslationQueue.swift` | طابور تسلسلي يغذّي `TranslationSession` من `.translationTask`. يتحقق كل 300ms (31)، **ويتجاهل الأخطاء بصمت** (44-46). |
| التلخيص والأسئلة | `Summarization/ClaudeClient.swift`، `LecturePrompt.swift`، `OnDeviceSummarizer.swift` | SSE خام عبر `URLSession.shared.bytes` (42)، و`thinking: adaptive`، و`effort: high`، و`cache_control` على النص، و`fallbacks: "default"` مع beta `server-side-fallback-2026-07-01` (109-113). كلها مطابقة للتوثيق الحالي. أما الملخص على الجهاز فيقسم النص لأن نافذة السياق 4K، ثم يدمج الأجزاء. |
| الواجهات | `Features/**` | `NavigationSplitView`. صفحة المحاضرة فيها أربعة تبويبات: النص والملخص والأسئلة والعلامات، مع شريط تشغيل وتصدير. |
| التخزين | `Storage/LectureStore.swift`، `KeychainStore.swift` | الصوت في `Documents/Lectures/<uuid>/`. الاستعادة تحذف الجزء المفتوح غير المقروء (48-69). المفاتيح في Keychain بخيار `AfterFirstUnlockThisDeviceOnly` (39). |
| المشروع | `project.pbxproj` | `objectVersion 77` بمجموعات مرتبطة بالمجلدات مباشرة. `IPHONEOS_DEPLOYMENT_TARGET 26.0`، و`SWIFT_VERSION 5.0`، و**`DEVELOPMENT_TEAM = ""`** (264، 300). لا هدف اختبارات ولا entitlements ولا حزم خارجية. |
| Info.plist | `Config/Info.plist` | `UIBackgroundModes=audio`، و`UIFileSharingEnabled`، و`LSSupportsOpeningDocumentsInPlace`. لا BGTask ولا push. |

### 2.2 مسار البيانات الحالي

```
Mic → AVAudioEngine tap → SegmentedRecorder ─┬─► part-NNN.m4a (Documents/Lectures/<id>/)
                                             └─► LiveTranscriber (Apple | Soniox WS)
                                                    └─► .final → SwiftData TranscriptSegment
                                                                  └─► TranslationQueue → Apple Translation
Detail view → ClaudeClient (SSE, مفتاح من Keychain) → lecture.summary
           → FileTranscriber (Apple, على الجهاز) → يستبدل كل المقاطع
```

**لا شيء يغادر الجهاز إلا:** الصوت إلى Soniox، والنص إلى Anthropic. **لا مزامنة ولا نسخ احتياطي** غير نسخ iCloud للجهاز كله.

---

## 3. النواقص والمشاكل

| # | الخطورة | الملف | المشكلة | لماذا تهم | الإصلاح المقترح |
|---|---|---|---|---|---|
| 1 | **حرج** | `project.pbxproj:264,300` + README | `DEVELOPMENT_TEAM` فارغ، وبحساب Apple ID مجاني ينتهي التوقيع كل 7 أيام. | التطبيق لن يُبنى على الجهاز قبل اختيار فريق، والاستعمال اليومي يتوقف أسبوعياً. Push وSign in with Apple يحتاجان عضوية مدفوعة. | الاشتراك في Apple Developer Program (99 $/سنة)، وضبط الفريق، والتوزيع عبر TestFlight. |
| 2 | **حرج** | `RecordingController.swift:86-90` | التفريغ يبدأ **قبل** التسجيل. مع Apple قد ينتظر `installAssets` تنزيل النموذج (`AppleSpeechEngine.swift:96`) دقائق والصوت لا يُسجَّل. | بداية المحاضرة تضيع. وأي تعليق في `transcriber.start()` يمنع التسجيل كلياً، وهذا يناقض مبدأ الملف نفسه (السطر 10). | تشغيل `SegmentedRecorder` أولاً. يُربط المفرّغ بعدها بمرجع قابل للتبديل محمي بقفل، ويُعلَّم ما فات كمقطع ناقص. |
| 3 | **عالٍ** | `RecordingController.swift:257-260` | عند انتهاء المقاطعة دون `shouldResume` يبقى التسجيل متوقفاً بصمت، والشاشة غالباً مقفلة. | محاضرة كاملة قد لا تُسجَّل بعد مكالمة أو تنبيه Siri. | محاولة الاستئناف تلقائياً، ثم إشعار محلي واهتزاز إن فشلت، وتسجيل الفجوة. |
| 4 | **عالٍ** | `DawwenApp.swift:10-14` + `Models/*` | لا `VersionedSchema` ولا `SchemaMigrationPlan`، والفشل يعني `fatalError`. | أي تعديل للنموذج لاحقاً (مزامنة، نطاقات ناقصة) قد يجعل التطبيق ينهار عند الإقلاع ولا تُفتح البيانات. | تعريف `SchemaV1` الآن قبل أي إضافة، واستبدال `fatalError` بشاشة استرداد تنقل قاعدة البيانات جانباً. |
| 5 | **عالٍ** | كل المشروع | لا نسخة خارج الجهاز. `Documents` تدخل في نسخ iCloud للجهاز فقط، والاستعادة كلية. | ضياع الآيباد أو تلفه يعني ضياع فصل دراسي كامل. | رفع الأجزاء تدريجياً إلى S3 أو الخادم بـ background `URLSession` (القسم 6). |
| 6 | **عالٍ** | `LectureDetailView.swift:220-248`، `FileTranscriber.swift` | «فرّغ من الصوت» **يستبدل النص كله** (232)، ومنه نص Soniox الأدق مع المتحدثين والترجمات، بنص Apple Dictation الأضعف. ويعمل على الجهاز في المقدمة. | تراجع في الجودة للعربية. ومعالجة 4 ساعات على الجهاز تستغرق عشرات الدقائق، وتُعلَّق إذا خرج المستخدم من التطبيق، ولا مراقبة حرارية فيها. | تتبّع `untranscribedRanges` وتفريغ الفجوات فقط. استخدام `BGContinuedProcessingTask` على الجهاز ([Apple](https://developer.apple.com/tutorials/data/documentation/backgroundtasks/bgcontinuedprocessingtask.md))، أو إرسال المهمة للخادم كنسخة HQ منفصلة لا تحذف الأصل. |
| 7 | **عالٍ** | `ClaudeClient.swift:42,90` | بث طويل (`max_tokens` 64K، مهلة 900 ث) على `URLSession.shared` دون إعادة محاولة لأخطاء 429 و529 والشبكة. | iOS يعلّق التطبيق في الخلفية فينقطع البث ويضيع الملخص (لا يُحفظ جزئياً، `SummaryView.swift:48`). | على الجهاز: إعادة محاولة بتأخير أسّي. وفي الخادم: مهمة تلخيص في الطابور، مع Batch API بخصم 50% إن لم يكن مستعجلاً، وإشعار APNs. |
| 8 | **متوسط** | `SonioxEngine.swift:163-168` | عند تجاوز 120 ث من الانقطاع يُحذف المخزون **دون** رفع `transcriptionIncomplete` أو تسجيل الفجوة. | نص ناقص لا يعرف به المستخدم. | إرسال `.status`/`.gap(start,end)` إلى المنسّق ليسجّل النطاق. |
| 9 | **متوسط** | `TranslationQueue.swift:44-46` | الخطأ يُرمى بعد كتابته في `lastError`، و`lastError` لا يُعرض في أي مكان (تأكدت بالبحث). | جمل بلا ترجمة دون سبب ظاهر. | إعادة المحاولة مرة، ثم إظهار عدد الإخفاقات في الواجهة. |
| 10 | **متوسط** | `RecordingView.swift:39-41,171` | عند إغلاق شاشة التسجيل تضيع ترجمات الطابور المعلّقة، رغم أن البطاقة تقول «تُستكمل ترجمة…». | ترجمة ناقصة دون إشارة لذلك. | نقل الطابور إلى صفحة التفاصيل أو إلى كائن عام، أو إعادة تشغيل «ترجمة غير المترجم» تلقائياً. |
| 11 | **متوسط** | `RecordingController.swift:136-139` | أول استعمال لزوج لغات يطلب تنزيل حزمة الترجمة **أثناء** التسجيل. | نافذة تقاطع الطالب في القاعة. | تجهيز الحزمة مسبقاً في `NewLectureSheet` بـ `LanguageAvailability`/`prepareTranslation()`. |
| 12 | **متوسط** | `SegmentedRecorder.swift:170-189` + `LectureStore.swift:57-61` | m4a المفتوح لا يُقرأ بعد الانهيار (moov غير مكتوب) فيُحذف، أي تضيع حتى 5 دقائق. | خسارة ملموسة في المحاضرات الحرجة. | أجزاء أقصر (60–120 ث)، أو حاوية CAF. والأجزاء الأصغر أفضل أيضاً كوحدات رفع ومعالجة على الخادم. |
| 13 | **متوسط** | `LibraryView.swift:17-24` | البحث يمر على **كل** مقاطع **كل** المحاضرات في الذاكرة مع كل حرف. | بعد فصل دراسي (100 محاضرة × ~3,000 جملة) يصبح البحث بطيئاً ويستهلك الذاكرة. | فهرس FTS (SQLite FTS5 محلياً، أو Postgres/Meilisearch على الخادم) مع تطبيع عربي للتشكيل والألف والياء والتاء المربوطة. |
| 14 | **متوسط** | `AppSettings.swift:32` | Opus هو النموذج الافتراضي. | نحو 0.6–0.8 $ لكل محاضرة من 4 ساعات، أي 13–18 $ شهرياً للتلخيص وحده (الحساب في القسم 5). | Sonnet افتراضياً، وBatch عبر الخادم، وOpus عند الطلب فقط. |
| 15 | **متوسط** | `SummaryView.swift:67` | الملخص على الجهاز يكتب بلغة **المحاضرة**، لا بلغة الملخص المختارة في الإعدادات. | سلوك مخالف لما يتوقعه المستخدم. | تمرير `settings.summaryLanguage` والتحقق من دعمه. |
| 16 | **متوسط** | `Lecture.swift:12` | `@Attribute(.unique)` لا يتوافق مع مزامنة CloudKit في SwiftData. | يمنع المزامنة المجانية عبر iCloud إن اختيرت. | إزالة القيد والاعتماد على UUID مع منطق upsert. |
| 17 | **متوسط** | `pbxproj:288` | `SWIFT_VERSION 5.0` مع `@unchecked Sendable` كثيرة، ولا هدف اختبارات ولا CI. | أخطاء تزامن صامتة في مسار الصوت. | هدف اختبارات (محلل Soniox، SRT، `LecturePrompt`، الاستعادة)، ثم Swift 6 تدريجياً، وCI على macOS runner. |
| 18 | **متوسط** | `KeychainStore.swift`، `SettingsView.swift:100-103` | المفاتيح الدائمة على الجهاز، وتُحفظ عند `onDisappear` فقط. | مشاركة التطبيق مع الزملاء تعني مشاركة المفاتيح أو أن يدفع كل منهم بنفسه. والإغلاق القسري يضيّع ما أُدخل. | وسيط في الخادم (القسم 6)، وحفظ فوري عند الإدخال. |
| 19 | **منخفض** | `Info.plist` | `UIFileSharingEnabled` يكشف مجلد `Lectures` في تطبيق الملفات. | حذف المستخدم لجزء أو تسميته يفسد الربط مع `audioSegments`. | إخفاء المجلد بنقله إلى Application Support، أو التحقق عند الفتح. |
| 20 | **منخفض** | `LecturePlayer.swift` | لا `MPNowPlayingInfoCenter` ولا أوامر شاشة القفل. | المراجعة بالسماعات أصعب. | إضافتها. |
| 21 | **منخفض** | `LectureExporter.swift:87` | تصدير الصوت يعيد الترميز بـ `AppleM4A`. | بطيء لأربع ساعات. | `AVAssetExportPresetPassthrough`، وتنظيف ملفات temp. |
| 22 | **منخفض** | `BookmarksView.swift:23,26,44` | `sortedSegments` يُرتَّب مرتين لكل علامة. | بطء طفيف. | حساب مسبق مرة واحدة. |
| 23 | **منخفض** | `AskView.swift` | المحادثة لا تُحفظ وتضيع عند الانتقال. | فقدان أسئلة مفيدة للمراجعة. | حفظ `QAEntry` في SwiftData أو على الخادم. |
| 24 | **منخفض** | `TranslationQueue.swift:29-33` | تحقق كل 300ms طوال فتح الصفحة. | استهلاك طفيف للبطارية. | `AsyncStream`/continuation بدل التحقق الدوري. |

---

## 4. ما يلزم ليشتغل فعلياً

### 4.1 جانب التطبيق (حد أدنى للتشغيل اليومي)
- [ ] عضوية Apple Developer، وضبط `DEVELOPMENT_TEAM`، وبناء على الآيباد، ثم TestFlight.
- [ ] إصلاح #2 (المسجّل أولاً) و#3 (الاستئناف بعد المقاطعة) و#4 (SchemaV1).
- [ ] اختبار ميداني: محاضرة 4 ساعات والشاشة مقفلة، مع مكالمة، وفصل الشاحن ووصله، وميكروفون USB، وانقطاع Wi-Fi لـ 3 دقائق في وضع Soniox. **معيار القبول:** لا فجوة في الصوت إلا أثناء المكالمة.
- [ ] قياس دقة العربية على ثلاث عينات من 10 دقائق مصحّحة يدوياً: Apple Dictation مقابل Soniox. هذا يحسم الحاجة لمسار HQ في الخادم.
- [ ] تجهيز حزم الترجمة مسبقاً (#11)، وإظهار أخطاء الترجمة (#9).
- [ ] اختيار Sonnet افتراضياً، وإعادة المحاولة في `ClaudeClient`.
- [ ] تتبّع نطاقات الصوت غير المفرّغة (#6، #8).

### 4.2 جانب التطبيق (للتكامل مع الخادم)
- [ ] `ServerClient`: عنوان الخادم، وSign in with Apple أو رمز جهاز، وJWT في Keychain.
- [ ] `UploadQueue`: ‏`URLSessionConfiguration.background` لرفع الأجزاء المغلقة فور إغلاقها. ملفات الرفع تكمل حتى إن عُلّق التطبيق، وهذه ميزة لا يتيحها البث.
- [ ] حقول جديدة في SchemaV2: `remoteID`، و`syncState`، و`uploadedParts`، و`transcriptVersion/source`، و`untranscribedRanges`.
- [ ] شاشة «حالة المعالجة على الخادم» بمهام SSE/polling، وإشعارات APNs (entitlement)، و`BGAppRefreshTask` لسحب النتائج.
- [ ] مفتاح واحد في الإعدادات «استخدام الخادم» (إيقاف = التطبيق كما هو اليوم).

### 4.3 جانب الخادم
- [ ] حساب AWS مع MFA على root، ومستخدم IAM Identity Center، و**AWS Budgets** بتنبيه عند 20/40/60 $.
- [ ] طلب رفع حصة **Running On-Demand G and VT instances** (وحصة Spot) في المنطقة المختارة. الحصة الافتراضية للحسابات الجديدة غالباً صفر، والمراجعة قد تستغرق أياماً ([re:Post](https://repost.aws/questions/QUSPetOgBLTQuxHpy_ffhiAg/instance-launch-failed)).
- [ ] نطاق DNS (Route 53 أو Cloudflare)، وTLS تلقائي عبر Caddy.
- [ ] Docker + Compose على الخادم، وصورة `worker-gpu` بـ CUDA مع NVIDIA Container Toolkit.
- [ ] S3 bucket خاص، مع Versioning وSSE وBlock Public Access وlifecycle.
- [ ] الأسرار في SSM Parameter Store: مفتاح Anthropic، ومفتاح Soniox الرئيسي، ومفتاح JWT.
- [ ] نسخ Postgres ليلياً إلى S3، واختبار استعادة شهرياً.
- [ ] مراقبة: Uptime Kuma أو healthchecks.io، وتنبيهات فشل المهام.

---

## 5. الميزات والخدمات المجانية المقترحة

افتراض الحمل لكل الحسابات: **4 ساعات محاضرات يومياً × 22 يوماً = 88 ساعة صوت شهرياً**.

| الميزة | الأداة/النموذج المجاني | أين يعمل | جودة العربية | الكلفة/العتاد | التوصية |
|---|---|---|---|---|---|
| تفريغ لحظي | Apple `DictationTranscriber` (موجود) | الجهاز | متوسطة، والصوت البعيد يضعفها | مجاني، ويسخّن الجهاز | يبقى خياراً احتياطياً دون إنترنت |
| تفريغ لحظي (مدفوع رخيص) | Soniox `stt-rt-v5` (موجود) | سحابة Soniox | عالية | 0.12 $/س ≈ **10.5 $ شهرياً** ([Soniox](https://soniox.com/compare/stt/pricing)) | **يبقى الافتراضي للعربية.** الخادم يصدر له مفاتيح مؤقتة |
| تفريغ HQ بعد المحاضرة (عربي) | **Cohere Transcribe Arabic 07-2026** (2B، Apache-2.0، لهجات وخلط عربي/إنجليزي) | خادم GPU | **الأفضل بين المفتوحة:** WER 25.87 حسب المطوّر | GPU بذاكرة 16–24GB. **لا يعطي توقيتات**، فيلزم VAD (Silero) أو محاذاة CTC | **مرشح أول.** يُقاس على محاضراتك قبل اعتماده |
| تفريغ HQ (بديل) | Whisper large-v3 / large-v3-turbo عبر faster-whisper / WhisperX (MIT) | خادم GPU، وCPU ممكن ببطء | WER ~36.9، أضعف | turbo على L4 نحو 31× أسرع من الزمن الحقيقي ([RunPod](https://www.runpod.io/articles/guides/best-gpu-for-whisper)) | للإنجليزية واللغات الأخرى، ولتوقيتات الكلمات |
| تفريغ HQ (بديل 2) | Meta omniASR-LLM-7B (Apache-2.0) ([HF](https://huggingface.co/facebook/omniASR-LLM-7B)) | خادم GPU | الثاني سابقاً على لوحة الصدارة العربية | أثقل (7B) | للمقارنة فقط |
| تمييز المتحدثين | pyannote `speaker-diarization-community-1` (أوزان CC-BY-4.0، كود MIT) | خادم GPU/CPU | لا يعتمد على اللغة | خفيف | أولوية منخفضة: المحاضرة متحدث واحد مع أسئلة. Soniox يقدّمه أصلاً |
| ترجمة لحظية | Apple Translation (موجود) | الجهاز | جيدة للجمل | مجاني ودون إنترنت | **يبقى.** الجهاز هنا أفضل |
| ترجمة بعد المحاضرة بسياق | **Qwen3-8B/14B** (Apache-2.0) عبر vLLM/Ollama بنافذة 5–10 جمل | خادم GPU | جيدة، والسياق يحسّن المصطلحات | 8–16GB VRAM | **موصى به** لترجمة نهائية متسقة |
| ترجمة آلية خفيفة | **MADLAD-400-3B-MT** (Apache-2.0) | خادم GPU/CPU (CTranslate2) | مقبولة | 3B | بديل تجاري آمن |
| ترجمة آلية | NLLB-200 | خادم | جيدة | **CC-BY-NC-4.0، غير تجاري** ([HF card](https://huggingface.co/facebook/nllb-200-distilled-600M/blob/main/README.md)) | للاستعمال الشخصي فقط. **تُستبعد إن بيع التطبيق** |
| تلخيص ودليل دراسة | Qwen3-14B/32B (Apache-2.0) | خادم GPU | جيدة. الأقوى بين المفتوحة في معيار 3LM العربي ([arXiv](https://arxiv.org/pdf/2507.15850)) | 14B AWQ على 16–24GB | ملخص مجاني للعربية لأن Apple Intelligence لا يدعمها. Claude يبقى للنسخة الممتازة |
| تلخيص (ممتاز) | Claude Sonnet 5.5 / Opus 5.5 عبر وسيط الخادم + **Batch API (خصم 50%)** | Anthropic | ممتازة | لمحاضرة 4 ساعات (~80K token دخل): Opus ≈ 0.6–0.8 $، وSonnet ≈ 0.3 $، وBatch ≈ النصف | Sonnet مع Batch افتراضياً عبر الخادم |
| أسئلة عبر كل المحاضرات (RAG) | bge-m3 embeddings (MIT) + pgvector + Qwen3 أو Claude | خادم | جيدة | CPU يكفي للفهرسة | **ميزة جديدة قوية:** «اسأل الفصل الدراسي كله» |
| بحث نصي | Postgres FTS أو Meilisearch (MIT) مع تطبيع عربي | خادم (+ FTS5 محلياً) | جيدة بعد التطبيع | CPU | يحل #13 |
| OCR للسبورة والشرائح | PaddleOCR PP-OCRv5 (Apache-2.0)، وTesseract `ara` احتياطياً، وApple Vision على الجهاز (تُفحص العربية وقت التشغيل) | خادم أو الجهاز | PaddleOCR أفضل للعربية | CPU/GPU | ميزة جديدة: «صوّر السبورة» بطابع زمني يربطها بالنص |
| بطاقات مراجعة | LLM + `genanki` لتصدير Anki | خادم | — | — | ميزة جديدة رخيصة |
| إشعارات | APNs مباشرة | Apple | — | مجاني (يحتاج العضوية) | ضروري للمهام الطويلة |
| ملاحظة | Amazon Transcribe/Translate | AWS | جيدة | Transcribe أغلى من Soniox بكثير، وTranslate بالحرف | **لا أوصي بهما** |

**مقارنة الكلفة الشهرية للتلخيص (22 محاضرة × 4 س):** Opus عادي نحو 13–18 $، وSonnet نحو 7 $، وSonnet مع Batch نحو 3.5 $، وQwen3 على GPU Spot نحو 1–2 $ من ساعات GPU تُدفع ضمن الجدول الزمني نفسه للتفريغ.

---

## 6. تصميم السيرفر: AWS + Docker + خادم منزلي

### 6.1 المبادئ
1. **الجهاز مصدر الحقيقة أثناء التسجيل.** الخادم لا يدخل في مسار التسجيل أبداً.
2. **الخادم يأتي بعد المحاضرة:** نسخ احتياطي، ونسخة HQ، وذكاء ثقيل، وبحث، ومزامنة.
3. **طبقة تحكم صغيرة دائمة + حوسبة GPU تتوقف حين لا عمل.** لا GPU دائم التشغيل لمستخدم واحد.
4. **جزء الصوت من 5 دقائق هو وحدة الرفع والمعالجة وإعادة المحاولة.** هذا يتلاءم مع انقطاعات Spot وحد Cloudflare البالغ 100MB، فالجزء الواحد نحو 1.2MB.
5. **السحب لا الدفع:** العامل المنزلي يسحب المهام من AWS باتصال صادر، فلا منافذ مفتوحة في البيت.

### 6.2 البنية

```
┌──────────────────────────── iPad «دوّن» ────────────────────────────┐
│ SegmentedRecorder → part-NNN.m4a   (مصدر الحقيقة، يعمل دون إنترنت)  │
│ Live: Apple Dictation | Soniox(مفتاح مؤقت من الخادم)  + Apple Translation│
│ SwiftData + SyncEngine (background URLSession uploads, change feed) │
└───────────────┬─────────────────────────────────────────────────────┘
                │ HTTPS/TLS1.3 + JWT (Sign in with Apple)
                ▼
┌──────────── AWS · طبقة تحكم دائمة (Lightsail 2–4GB / t4g.small) ────────────┐
│ caddy(TLS) → api (FastAPI)  ─┬─ postgres (+pgvector, FTS)                 │
│                              ├─ redis (queue: arq/RQ)                     │
│                              ├─ worker-cpu (sync, exports, Claude Batch,  │
│                              │              Soniox temp keys, APNs)       │
│                              └─ launcher (يشغّل GPU Spot إن وُجدت مهام)   │
└──────┬──────────────────────────────┬───────────────────────────┬─────────┘
       │ presigned PUT/GET            │ RunInstances(spot)        │ HTTPS خارجي
       ▼                              ▼                           ▼
┌── S3 (خاص، Versioning، SSE) ─┐ ┌─ EC2 g6.xlarge Spot (L4 24GB) ─┐  Anthropic API
│ audio/, exports/, backups/   │ │ worker-gpu: VAD→ASR→align→diar │  Soniox API
│ lifecycle → Glacier IR 90d   │ │ →MT→LLM summary → يطفئ نفسه    │  APNs
└──────────────────────────────┘ └────────────────────────────────┘
       ▲  يسحب المهام (اتصال صادر عبر Tailscale)
┌──────┴──── خادم منزلي (Docker) ────────────────────────┐
│ worker-gpu (نفس الصورة) + ollama/vLLM + paddleocr      │
│ restic → نسخة ثالثة؛ لا منافذ مفتوحة                   │
└────────────────────────────────────────────────────────┘
```

**خط المعالجة لكل محاضرة** (كل خطوة idempotent، والمفتاح `lecture_id + part_index + stage`):
`all parts uploaded` → `vad+asr_hq (لكل جزء، بالتوازي)` → `merge+align` → `diarize (اختياري)` → `translate_ctx` → `summarize (local | claude-batch)` → `index (FTS+embeddings)` → `push`.

### 6.3 الخدمات

| الخدمة | الصورة/التقنية | أين | ملاحظات |
|---|---|---|---|
| `caddy` | caddy:2 | AWS | TLS تلقائي من Let's Encrypt، وrate limit، وحد لحجم الطلب |
| `api` | Python 3.12 + FastAPI + SQLAlchemy | AWS | REST + SSE، والتحقق من JWT، وIdempotency-Key |
| `postgres` | postgres:16 + pgvector | AWS | بيانات وصفية ونصوص وFTS وembeddings |
| `redis` | redis:7 | AWS | طابور (arq/RQ) وأقفال |
| `worker-cpu` | نفس كود api | AWS | المزامنة والتصدير وClaude Batch ومفاتيح Soniox المؤقتة وAPNs وembeddings |
| `launcher` | سكربت boto3 | AWS | إن وُجدت مهام GPU ولا نبضة عامل: يطلب Spot من Launch Template. يتسامح مع انقطاع Spot لأن وحدة العمل جزء واحد |
| `worker-gpu` | CUDA 12 + faster-whisper/transformers/vLLM + silero-vad + pyannote | EC2 Spot أو البيت | نفس الصورة في المكانين. `InstanceInitiatedShutdownBehavior=terminate` وإطفاء بعد 10 دقائق خمول |
| `llm` | vLLM (Qwen3-14B-AWQ) أو Ollama | GPU | ترجمة بسياق وتلخيص جزئي |
| `ocr` | PaddleOCR | GPU/CPU | لاحقاً |
| `uptime` | Uptime Kuma | AWS | + healthchecks.io للمهام الليلية |
| `backup` | `pg_dump` + `aws s3 cp` / restic | AWS + البيت | 3-2-1 |

### 6.4 عقد الـ API بين التطبيق والخادم (مختصر)

```yaml
# كل الطلبات: Authorization: Bearer <JWT>  ·  Idempotency-Key لكل POST/PUT
POST /v1/auth/apple            {identityToken}            → {access, refresh, user}
POST /v1/auth/refresh          {refresh}                  → {access}

PUT  /v1/lectures/{uuid}       {title, sourceLanguage, targetLanguage, createdAt, engine}
                                                          → 200 (upsert؛ الـ UUID يولّده الجهاز)
POST /v1/lectures/{uuid}/parts/{n}/upload-url {sha256, bytes, durationSec}
                                                          → {url (S3 presigned PUT), expiresAt}
POST /v1/lectures/{uuid}/parts/{n}/complete  {sha256}     → {stored:true}
POST /v1/lectures/{uuid}/finalize {partCount, durationSec, bookmarks[], untranscribedRanges[]}
                                                          → {jobs:[...]}   # يطلق الخط تلقائياً حسب الإعدادات

PUT  /v1/lectures/{uuid}/transcripts/live   {segments:[{uid,start,end,text,translation?,speaker?}]}
GET  /v1/lectures/{uuid}/transcripts/{version}           # version = live | hq | hq-translated
POST /v1/lectures/{uuid}/jobs  {type: asr_hq|diarize|translate|summarize|ocr|flashcards, params}
GET  /v1/jobs/{id}             → {state: queued|running|done|failed, progress, error?}
GET  /v1/jobs/{id}/events      (SSE)

POST /v1/llm/stream            {lectureId, kind: summary|ask, model, question?}  (SSE بنفس صيغة Anthropic)
                               # الخادم يبني الـ prompt ويحمل المفتاح ويطبّق حد إنفاق يومي
POST /v1/soniox/temp-key       → {apiKey, expiresAt}     # usage_type=transcribe_websocket، صلاحية قصيرة
GET  /v1/search?q=&scope=all|lecture:{uuid}&semantic=true
GET  /v1/sync?since={cursor}   → {changes:[...], cursor}
POST /v1/devices/apns          {token}
```

**ملاحظة Soniox:** المفتاح المؤقت يُطلب من الخادم ويصلح لجلسة WebSocket واحدة ([Soniox docs](https://soniox.com/docs/guides/direct-stream)). التعديل في `SonioxEngine.swift:93` بسيط: يُستبدل المفتاح الدائم بالمؤقت، ويُطلب مفتاح جديد عند كل إعادة اتصال (السطر 225). وللتسجيل دون إنترنت للخادم يبقى المفتاح الدائم احتياطياً.

### 6.5 مخطط docker-compose (تصوّري)

```yaml
# compose.yaml  — profiles: control (AWS) · gpu (Spot/البيت) · home
services:
  caddy:    { image: caddy:2, profiles: [control], ports: ["443:443","80:80"],
              volumes: [./Caddyfile:/etc/caddy/Caddyfile, caddy_data:/data] }
  api:      { build: ./server, profiles: [control], env_file: .env,
              depends_on: [postgres, redis], command: uvicorn app.main:app --host 0.0.0.0 }
  worker-cpu: { build: ./server, profiles: [control], command: arq app.worker.CPU }
  launcher: { build: ./server, profiles: [control], command: python -m app.launcher }
  postgres: { image: pgvector/pgvector:pg16, profiles: [control], volumes: [pg:/var/lib/postgresql/data] }
  redis:    { image: redis:7-alpine, profiles: [control], command: redis-server --appendonly yes }
  uptime:   { image: louislam/uptime-kuma:1, profiles: [control] }

  worker-gpu:
    build: ./gpu
    profiles: [gpu]
    command: arq app.worker.GPU          # يتصل بـ REDIS_URL عبر Tailscale/WireGuard (صادر فقط)
    environment: [REDIS_URL, S3_BUCKET, ASR_MODEL=CohereLabs/cohere-transcribe-arabic-07-2026]
    volumes: [models:/models]            # كاش النماذج (EBS snapshot على AWS، NVMe في البيت)
    deploy: { resources: { reservations: { devices: [{ capabilities: [gpu] }] } } }
  llm:
    image: vllm/vllm-openai:<pinned>
    profiles: [gpu]
    command: --model Qwen/Qwen3-14B-AWQ --max-model-len 32768
    deploy: { resources: { reservations: { devices: [{ capabilities: [gpu] }] } } }
  tailscale: { image: tailscale/tailscale, profiles: [home], network_mode: host }
volumes: { pg: {}, caddy_data: {}, models: {} }
```

> **تنبيه Mac:** Docker على macOS **لا يصل إلى GPU الـ Mac** (Metal). إذا كان الخادم المنزلي Mac بشريحة Apple، فإن `ollama` و`whisper.cpp`/`mlx-whisper` تعمل **أصلياً خارج Docker**، وتبقى api/db/redis في Docker.

### 6.6 خيارات AWS ومقارنة الكلفة الشهرية (88 ساعة صوت)

أسعار us-east-1 من مجمّعات أسعار بتحديث 2026، وتجب مراجعتها في صفحة AWS قبل الالتزام:
- g6.xlarge: ‏0.805 $/س عند الطلب، وSpot ~0.35–0.55 $ ([DoiT](https://www.doit.com/compute/spot/us-east-1/g6.xlarge)، [Holori](https://calculator.holori.com/aws/ec2/g6.xlarge/us-east-1)).
- g4dn.xlarge: ‏0.526 $/س. وg5.xlarge: ‏1.006 $/س ([DoiT](https://www.doit.com/compute/spot/us-east-1/g4dn.xlarge)).
- Lightsail: ‏5 / 12 / 24 $ ([cloudburn](https://cloudburn.io/blog/amazon-lightsail-pricing)).

**تقدير ساعات GPU:** محاضرة 4 ساعات تحتاج نحو 10–15 دقيقة ASR على L4، و5 دقائق محاذاة وتمييز متحدثين، و5–10 دقائق ترجمة بسياق وتلخيص محلي (vLLM مع batching)، و5 دقائق تشغيل وتحميل نماذج. المجموع ≈ **0.6–0.75 س يومياً ≈ 15 س شهرياً**.

| الخيار | المكوّنات | الكلفة الشهرية التقريبية | المزايا | العيوب | الحكم |
|---|---|---|---|---|---|
| **A. وسيط + نسخ احتياطي** | Lightsail 2GB (12 $، يشمل IPv4 و3TB نقل) + S3 (~1.3GB/شهر نمو ≈ <0.5 $) | **~13 $** + استهلاك Soniox وClaude | بسيط، ويحل #5 و#7 و#18 | لا يقدّم نماذج مفتوحة | **المرحلة 2** |
| **B. A + GPU Spot عند الطلب** | A + g6.xlarge Spot ~15 س × 0.35–0.55 $ + EBS gp3 60GB (~5 $) + لقطة النماذج | **~25–30 $** | تفريغ HQ عربي وتلخيص مجاني، ويتوقف حين لا عمل | الحصة الافتراضية صفر، وقد لا تتوفر سعة Spot، فيُعاد للطلب العادي | **الموصى به (المرحلة 3)** |
| C. A + GPU عند الطلب (On-Demand) | 15 س × 0.805 $ | **~30–35 $** | توفر أعلى | أغلى قليلاً | احتياطي تلقائي لـ B |
| D. GPU دائم التشغيل | g4dn.xlarge ‏~384 $ / g6.xlarge ‏~588 $ | **384–588 $** | زمن استجابة فوري | هدر بنحو 97% من الوقت | **مرفوض** لمستخدم واحد |
| E. SageMaker Async Inference | ml.g4dn/ml.g5 مع التوقف عند الخمول | أعلى من B بـ 20–40% + تعقيد | إدارة مُتكفَّل بها | قيود صور وكلفة SageMaker | ليس الآن |
| F. Lambda / Fargate للتفريغ | CPU فقط (لا GPU)، وحد 15 دقيقة | Lambda بذاكرة 10GB × ~300 ث لكل جزء ≈ 0.05 $ للجزء، أي ~2.4 $ لمحاضرة 4 ساعات (≈ 50 $ شهرياً) | لا خوادم | أبطأ وأغلى من Spot | لمهام خفيفة فقط (تصدير، مصغّرات) |
| G. ECS على EC2 | عنقود ECS + ASG GPU | مثل B + وقت إداري | قابل للتوسع | زائد عن الحاجة لمستخدم واحد | عند تعدد المستخدمين |

**الطبقة المجانية 2026:** الحسابات الجديدة منذ 15 يوليو 2025 تحصل على 100 $ أرصدة، و100 $ إضافية بإكمال مهام. الخطة المجانية تنتهي بعد 6 أشهر أو عند نفاد الرصيد، أيهما أسبق. **لم تعد هناك 750 ساعة مجانية من t3.micro منفصلة** للحسابات الجديدة ([AWS](https://aws.amazon.com/about-aws/whats-new/2025/07/aws-free-tier-credits-month-free-plan/)، [infratally](https://infratally.com/articles/aws-free-tier-2026/)). عملياً، 200 $ تغطي الخيار B لنحو 6 أشهر كاملة إن رُقّيت الخطة إلى مدفوعة قبل انتهاء المدة.

**تكاليف خفية:**
- IPv4 العام على EC2 ‏(0.005 $/س ≈ 3.65 $ شهرياً). Lightsail يشمله.
- خروج البيانات بعد أول 100GB/شهر.
- لقطات EBS.
- NAT Gateway: **تجنّبه** (32 $+ شهرياً). ضع العامل في subnet عامة مع security group لا تسمح بأي اتصال وارد.

**المنطقة:** للمعالجة الدفعية لا يهم زمن الاستجابة، و**us-east-1** الأرخص والأوفر سعة GPU. إن كانت هناك متطلبات إقامة بيانات في الخليج فـ me-central-1 أو me-south-1، مع التحقق من توفر G6 وأسعاره هناك.

### 6.7 الخادم المنزلي: العتاد ومتى يتفوّق على AWS

| الفئة | المواصفات | الكلفة التقريبية (أكتوبر 2026) | ما يشغّله |
|---|---|---|---|
| 0: موجود عندك | Mac بشريحة Apple يلزمك أصلاً لـ Xcode (32GB+ يُفضّل) | 0 $ إضافي | whisper.cpp/mlx-whisper وOllama أصلياً، والباقي في Docker. أبطأ من L4 لكنه يكفي للمعالجة الليلية |
| 1: الموصى به | Ryzen 7 / i5، و64GB RAM، و**GPU بذاكرة 16GB** (RTX 4060 Ti 16GB أو 5060 Ti 16GB، والأخيرة ~789 $ جديدة)، وNVMe 1TB + HDD 4TB، وUPS، وUbuntu 24.04 + NVIDIA Container Toolkit | ~1,300–1,700 $ | Cohere 2B / Whisper وQwen3-14B-AWQ وPaddleOCR وpyannote |
| 2: LLM أكبر | **RTX 3090 مستعملة 24GB** (~1,000–1,300 $ في 2026 بعد ارتفاع أسعارها، [gpupoet](https://gpupoet.com/gpu/learn/price/july-2026/nvidia-geforce-rtx-3090)، [openclawdc](https://openclawdc.com/blog/is-a-used-rtx-3090-worth-it-local-llm/)) | ~1,800–2,200 $ | Qwen3-32B-AWQ للتلخيص بجودة أعلى |

**الكهرباء:** خمول ~60W ≈ 43 kWh شهرياً، وحمل ~350W × ساعة يومياً ≈ 10 kWh. المجموع ≈ **55 kWh/شهر**، وكلفته تعتمد على تعرفة بلدك.

**متى يتفوّق البيت على AWS (بإنصاف):**
- ✅ إن **كان العتاد موجوداً** (Mac أو PC ألعاب): كلفة حدّية شبه صفرية.
- ✅ إن **كثر استعمال LLM** (أسئلة طوال اليوم عبر الفصل الدراسي، ترجمة كل شيء بنماذج 14–32B)، أو **تعدد المستخدمين** (زملاء الدفعة).
- ✅ للخصوصية: البيانات لا تغادر بيتك.
- ❌ لمستخدم واحد بلا عتاد، شراء جهاز بـ 1,500 $ مقابل ~15 $ شهرياً من Spot GPU يسترد ثمنه في **أكثر من 8 سنوات**. **AWS أوفر هنا.**
- ❌ كهرباء وإنترنت غير مستقرين: لذلك طبقة التحكم على AWS، والبيت مجرد عامل إضافي. إن انقطع البيت تنتظر المهام أو يتولاها Spot تلقائياً.

**الشبكة المنزلية (بلا منافذ مفتوحة):**
- **الموصى به:** **Tailscale** (الخطة المجانية حتى 6 مستخدمين بعد تحديث أبريل 2026، [ssdnodes](https://www.ssdnodes.com/learn/is-tailscale-free-plan-limits)). العامل المنزلي وخادم AWS في نفس tailnet، والعامل **يسحب** من Redis على عنوان Tailscale. لا يحتاج الآيباد Tailscale لأنه يتكلم مع AWS فقط.
- **إن كان البيت هو الخادم الوحيد:** **Cloudflare Tunnel** (مجاني، بلا منافذ واردة) مع Cloudflare Access service token. انتبه إلى أن حد الطلب **100MB** في الخطة المجانية، وهذا لا يضر لأن الجزء ~1.2MB. وانتبه أيضاً إلى أن Cloudflare ينهي TLS عنده، فيرى المحتوى.
- **WireGuard يدوي:** ممكن، لكنه يحتاج منفذ UDP مفتوحاً أو وسيطاً. Tailscale يغني عنه.

### 6.8 الأمان
- **المصادقة:** Sign in with Apple ← JWT قصير (15 دقيقة) + refresh في Keychain. لمستخدم واحد: قائمة سماح بـ `sub` واحد. اختيارياً App Attest لربط الطلبات بالتطبيق الأصلي.
- **الوسيط:** المفاتيح الدائمة (Anthropic وSoniox) في SSM Parameter Store فقط، و**حد إنفاق يومي** لكل مستخدم مسجّل في جدول `usage_ledger`، وقائمة سماح للنماذج.
- **الشبكة:** Security Group يسمح بـ 443 فقط (و80 لـ ACME). **لا SSH مفتوح**: SSM Session Manager أو Tailscale SSH. العامل GPU بلا أي منفذ وارد.
- **S3:** Block Public Access، وSSE-S3 (أو SSE-KMS)، وVersioning، وpresigned URLs بصلاحية 15 دقيقة، وIAM role على الـ instance لا مفاتيح ثابتة.
- **TLS:** Caddy مع Let's Encrypt تلقائياً، وHSTS.
- **التطبيق:** ATS افتراضي، وCertificate pinning اختياري.
- **الخصوصية:** تسجيل المحاضرات قد يحتاج إذن المحاضر أو الجامعة. التخزين مشفّر، وزر «احذف من الخادم» يحذف الأجزاء والنسخ القديمة (versions).
- **التبعيات:** تثبيت الإصدارات، وDependabot، و`trivy` على الصور.

### 6.9 النسخ الاحتياطي والمراقبة
- **3-2-1:** (1) الآيباد، (2) S3 مع Versioning وlifecycle إلى Glacier Instant Retrieval بعد 90 يوماً، (3) نسخة restic في البيت (أو Backblaze B2).
- **Postgres:** `pg_dump` ليلي إلى S3 (احتفاظ 30 يوماً)، و**اختبار استعادة شهري مؤتمت**.
- **لقطات:** Lightsail snapshot أسبوعياً.
- **المراقبة:** Uptime Kuma (فحص `/healthz`)، وhealthchecks.io للمهام الليلية، وCloudWatch alarm على الفوترة، وAWS Budgets، وتنبيه عند فشل مهمة 3 مرات (APNs إلى جهازك أو بريد عبر SES).

---

## 7. خريطة الطريق

| المرحلة | المهام | تعتمد على | الجهد | معيار القبول |
|---|---|---|---|---|
| **0: يشتغل فعلاً** | العضوية والتوقيع وTestFlight؛ إصلاح #2 و#3 و#4 (SchemaV1)؛ إظهار أخطاء الترجمة؛ تجهيز حزم الترجمة مسبقاً؛ Sonnet افتراضياً؛ اختبار ميداني 4 ساعات | — | 2–4 أيام | تسجيل 4 ساعات والشاشة مقفلة مع مكالمة وتبديل ميكروفون: **صفر فجوة** خارج المكالمة؛ التسجيل يبدأ خلال أقل من ثانيتين |
| **1: تصليب التطبيق** | `untranscribedRanges`، وتفريغ الفجوات فقط مع `BGContinuedProcessingTask`، وإعادة المحاولة في Claude، وأجزاء 120 ث، وNowPlaying، وفهرس FTS5 محلي، وهدف اختبارات + CI | 0 | 1–2 أسبوع | تغطية اختبار للمحللات والتصدير ≥70%؛ البحث في 100 محاضرة أقل من 200ms |
| **2: خادم MVP (AWS)** | Lightsail + compose (caddy/api/postgres/redis/worker-cpu) + S3؛ Sign in with Apple؛ رفع الأجزاء بـ background URLSession؛ وسيط Claude (SSE) + مفاتيح Soniox مؤقتة؛ Budgets والنسخ الاحتياطي | 0 (+4 للترحيل) | 1.5–2 أسبوع | الأجزاء تصل S3 خلال 10 دقائق من إغلاقها حتى والتطبيق في الخلفية؛ **لا مفتاح دائم على الجهاز**؛ استعادة قاعدة البيانات تعمل |
| **3: مسار GPU (HQ)** | صورة `worker-gpu` (VAD + Cohere Arabic / Whisper + محاذاة)، وlauncher لـ Spot مع احتياطي On-Demand، ونسخة `hq` من النص، وواجهة مقارنة واختيار | 2، حصة GPU | 2 أسبوع | محاضرة عربية 4 ساعات: نص HQ خلال 45 دقيقة؛ **WER أفضل بـ ≥20% نسبياً** من البث اللحظي على 3 عينات؛ كلفة GPU أقل من 0.40 $ للمحاضرة |
| **4: ترجمة وتلخيص مفتوحان** | Qwen3 عبر vLLM للترجمة بسياق والتلخيص بالتقسيم والدمج، وClaude Batch للنسخة الممتازة، وإشعارات APNs | 3 | 1–1.5 أسبوع | ملخص عربي مجاني بنفس هيكل `LecturePrompt.summaryRequest`؛ تقييم بشري ≥3.5/5 على 5 محاضرات |
| **5: الخادم المنزلي** | Tailscale، ونفس `worker-gpu` بـ profile `home`، وأولوية للبيت مع Spot احتياطياً، وrestic | 3 | 3–5 أيام | فصل الشبكة عن البيت أثناء مهمة: Spot يكملها تلقائياً؛ لا منافذ مفتوحة (فحص nmap خارجي) |
| **6: ميزات الفصل الدراسي** | RAG عبر كل المحاضرات (bge-m3 + pgvector)، وOCR للسبورة بطابع زمني، وبطاقات Anki، وعارض ويب للقراءة | 4 | 2–3 أسابيع | سؤال عن موضوع موزّع على 3 محاضرات يجيب بطوابع زمنية صحيحة من المحاضرات الثلاث |

---

## 8. عملية التنفيذ خطوة بخطوة

1. **التطبيق، اليوم الأول:** الاشتراك في Developer Program ← Xcode ← Signing ← Team ← بناء على الآيباد. فرع جديد للإصلاحات.
2. **إصلاح ترتيب البدء (#2):** `startRecorder` أولاً، و`bufferHandler` يقرأ المفرّغ من صندوق محمي بقفل يُملأ لاحقاً، وما قبل الربط يُسجَّل `untranscribedRange`.
3. **المقاطعات (#3):** في `interruptionEnded` يُحاوَل `resume()` دائماً بعد 0.5 ث، وعند الفشل إشعار محلي بـ `UNUserNotificationCenter`.
4. **SchemaV1 (#4):** `enum SchemaV1: VersionedSchema` يغلّف النماذج الحالية كما هي، و`MigrationPlan` فارغ، وشاشة استرداد بدل `fatalError`.
5. **اختبار ميداني** وفق 4.1، وقياس WER لـ Apple وSoniox على 3 عينات (أداة `jiwer` على حاسوبك).
6. **AWS:** حساب، ثم MFA، ثم Budgets (20/40/60 $)، ثم طلب حصة G/VT (4–8 vCPU) في us-east-1 **مبكراً لأن المراجعة قد تطول**.
7. **Lightsail 2GB (Ubuntu 24.04):** تثبيت Docker، وربط DNS، و`compose --profile control up -d`، وCaddy يصدر الشهادة.
8. **S3:** bucket بإعدادات 6.8، ودور IAM بأقل صلاحيات (`s3:PutObject/GetObject` على البادئة فقط)، وlifecycle.
9. **API:** `/auth/apple` و`/lectures` و`upload-url` و`complete` و`finalize` و`/soniox/temp-key` و`/llm/stream`، ثم اختبارات تكامل بـ pytest وhttpx.
10. **التطبيق:** `ServerClient` + `UploadQueue` (background session بمعرّف ثابت، وإعادة ربط عند الإقلاع)، وSchemaV2 مع ترحيل خفيف، ومفتاح «استخدام الخادم».
11. **GPU:** AMI أساسية (Deep Learning Base GPU AMI أو Ubuntu + driver)، و`docker pull` للصورة، وتنزيل النماذج إلى EBS ثم snapshot، وLaunch Template (Spot، إنهاء عند الإطفاء، user-data يشغّل `worker-gpu`).
12. **launcher:** كل 30 ث: إن كان `queue:gpu > 0` ولا نبضة عامل خلال 60 ث ← `RunInstances` (Spot، وعند فشل السعة ← On-Demand). والعامل يطفئ نفسه بعد 10 دقائق خمول.
13. **خط HQ:** Silero VAD يقسّم الصوت إلى مقاطع ≤30 ث (منها التوقيتات) ← Cohere Transcribe Arabic (أو Whisper) ← دمج ← نسخة `hq` ← إشعار.
14. **المقارنة:** واجهة «النص اللحظي / النص المحسّن» واختيار الافتراضي. لا حذف للأصل.
15. **الترجمة والتلخيص (المرحلة 4):** vLLM Qwen3-14B-AWQ، ونافذة سياق 5 جمل، وتلخيص بالتقسيم والدمج بنفس قالب الأقسام، وخيار «Claude Batch».
16. **البيت (المرحلة 5):** Ubuntu + NVIDIA Toolkit + Tailscale، و`compose --profile gpu --profile home up -d`، واختبار الانقطاع.
17. **التشغيل المستمر:** Uptime Kuma، واختبار استعادة شهري، ومراجعة الفاتورة أسبوعياً في أول شهرين.

---

## 9. نقاط الخلاف المتوقعة مع الإيجنت الأول

| حجته المتوقعة | ردّي | ما أتنازل عنه |
|---|---|---|
| «الجهاز مجاني والخادم يكلّف» | المسار «المجاني» على الجهاز **غير موجود للعربية**: SpeechTranscriber لا يدعمها، وApple Intelligence لا يدعمها. فالمستخدم يدفع اليوم لـ Soniox (~10.5 $) ولـ Claude Opus (~13–18 $) شهرياً. الخيار B (~25–30 $) **يستبدل جزءاً كبيراً من ذلك** بنماذج مفتوحة، ويضيف نسخاً احتياطياً وبحثاً ونسخة HQ. | في الأشهر 0–2 يكفي Soniox مع Claude Sonnet دون GPU. الخيار A وحده (~13 $). |
| «الخصوصية: كل شيء على الجهاز» | الوضع الحالي يرسل الصوت إلى Soniox والنص إلى Anthropic. خادمك المشفّر (أو بيتك) **أكثر خصوصية** من طرفين ثالثين. | التسجيل والكتابة اللحظية والترجمة اللحظية تبقى على الجهاز، والخادم اختياري. |
| «التعقيد والصيانة» | التعقيد محصور في خدمة واحدة بـ compose، والتطبيق يعمل كما هو حين يتوقف الخادم. والفائدة: لا ضياع لفصل دراسي إذا ضاع الآيباد (#5). | لا بث صوت لحظي لخادمي في الإصدار الأول. WhisperLive وما شابهه أقل موثوقية على Wi-Fi الجامعة. |
| «iOS 26 يتيح `BGContinuedProcessingTask` للتفريغ الطويل على الجهاز» | صحيح، وأوصي به للفجوات الصغيرة. لكن 4 ساعات على الجهاز تعني حرارة وبطارية، وقد يوقفها النظام تحت ضغط الموارد ([Apple forums](https://developer.apple.com/forums/thread/818873)). والنموذج على الجهاز نفسه (Dictation) أضعف للعربية من Cohere أو Whisper على GPU. | للمحاضرات الإنجليزية مع SpeechTranscriber يكفي الجهاز غالباً. |
| «CloudKit/SwiftData sync مجاني» | جيد للمزامنة، لكنه **لا يشغّل نماذج**، ويستهلك حصة iCloud للمستخدم، ويتطلب إزالة `.unique` (#16) وجعل العلاقات اختيارية. نحتاج الخادم للحوسبة على أي حال، فواجهة خلفية واحدة أبسط من اثنتين. | لو رُفض الخادم كلياً، فـ CloudKit أفضل من لا شيء للنسخ الاحتياطي. |
| «Apple Translation كافية» | للترجمة **اللحظية** نعم. أما الترجمة النهائية بسياق ومصطلحات المادة فـ LLM بنافذة سياق أفضل، ويمكن حقن «مصطلحات المادة» من `SettingsKey.vocabulary`. | تبقى Apple Translation الافتراضية أثناء التسجيل. |
| «زمن الاستجابة» | المعالجة على الخادم دفعية بعد المحاضرة ولا تمس تجربة القاعة. والأسئلة عبر الوسيط تضيف ~50–100ms فقط. | الكتابة اللحظية لا تمر بخادمي. |
| «الكلفة غير المتوقعة على AWS» | Budgets + Spot + إطفاء ذاتي + لا NAT + لا GPU دائم، والسقف محسوب في 6.6. | إن لم تُمنح حصة GPU سريعاً: البيت (Mac) أو تأجيل المرحلة 3. |

**أقوى نقاطي:** (1) العربية تحتاج نماذج لا تعمل على الآيباد اليوم. (2) لا نسخة احتياطية حالياً لبيانات لا تُعوَّض. (3) المهام الطويلة (ملخص 4 ساعات، إعادة تفريغ) تنكسر في الخلفية على iOS، والخادم مع الإشعار يحلها جذرياً. (4) الوسيط يخرج المفاتيح من الجهاز ويسمح بمشاركة التطبيق مع الزملاء.

---

## الجولة الثانية: الرد على الإيجنت الأول

(سيُضاف بعد قراءة تقرير الإيجنت الأول)

---

### المصادر (مختصرة)
- AWS Free Tier 2026: [aws.amazon.com](https://aws.amazon.com/about-aws/whats-new/2025/07/aws-free-tier-credits-month-free-plan/)، [infratally](https://infratally.com/articles/aws-free-tier-2026/)
- أسعار GPU: [DoiT g6.xlarge](https://www.doit.com/compute/spot/us-east-1/g6.xlarge)، [Holori](https://calculator.holori.com/aws/ec2/g6.xlarge/us-east-1)، [DoiT g4dn](https://www.doit.com/compute/spot/us-east-1/g4dn.xlarge)، [DoiT g5](https://www.doit.com/compute/spot/us-east-1/g5.xlarge)
- حصص GPU: [AWS re:Post](https://repost.aws/questions/QUSPetOgBLTQuxHpy_ffhiAg/instance-launch-failed)
- Lightsail: [cloudburn](https://cloudburn.io/blog/amazon-lightsail-pricing)
- Cohere Transcribe Arabic: [Cohere blog](https://cohere.com/blog/transcribe-arabic)، [docs](https://docs.cohere.com/docs/transcribe-arabic)، [the-decoder](https://the-decoder.com/cohere-transcribe-arabic-is-an-open-source-model-built-for-arabics-toughest-transcription-problems/)
- Omnilingual ASR: [HF](https://huggingface.co/facebook/omniASR-LLM-7B)؛ Whisper Arabic WER: [arXiv 2510.23319](https://arxiv.org/pdf/2510.23319)
- NLLB رخصة CC-BY-NC: [HF card](https://huggingface.co/facebook/nllb-200-distilled-600M/blob/main/README.md)؛ MADLAD Apache-2.0: [promptlayer](https://www.promptlayer.com/models/madlad400-3b-mt)
- LLM عربية: [3LM arXiv 2507.15850](https://arxiv.org/pdf/2507.15850)، [promptquorum](https://www.promptquorum.com/de/local-llms/best-arabic-local-llms-2026)
- pyannote community-1: [pyannote.ai](https://www.pyannote.ai/md/models)
- Soniox: [التسعير](https://soniox.com/compare/stt/pricing)، [المفاتيح المؤقتة](https://soniox.com/docs/guides/direct-stream)
- Apple Intelligence languages: [9to5mac](https://9to5mac.com/2025/11/11/ios-26-1-brings-apple-intelligence-to-these-eight-new-languages/)؛ BGContinuedProcessingTask: [Apple](https://developer.apple.com/tutorials/data/documentation/backgroundtasks/bgcontinuedprocessingtask.md)
- Tailscale: [ssdnodes](https://www.ssdnodes.com/learn/is-tailscale-free-plan-limits)؛ حد Cloudflare 100MB: [fast.io](https://fast.io/resources/cloudflare-upload-limit/)
- سرعة Whisper على GPU: [RunPod](https://www.runpod.io/articles/guides/best-gpu-for-whisper)
- أسعار GPU منزلية: [gpupoet](https://gpupoet.com/gpu/learn/price/july-2026/nvidia-geforce-rtx-3090)، [openclawdc](https://openclawdc.com/blog/is-a-used-rtx-3090-worth-it-local-llm/)
- أسعار Claude (Opus 5.5 ‏4/20 $، Sonnet 5.5 ‏2/10 $، Haiku 5.5 ‏0.10/0.50 $ حتى 100K، Batch بخصم 50%): مرجع Claude API المضمّن (محدّث 2026-10-06)
