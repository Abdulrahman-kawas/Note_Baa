import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Lecture.createdAt, order: .reverse) private var lectures: [Lecture]
    @State private var selection: UUID?
    @State private var search = ""
    @State private var showNewLecture = false
    @State private var showSettings = false
    @State private var showImporter = false
    @State private var activeRecording: NewLectureRequest?
    @State private var pendingRecording: NewLectureRequest?
    @State private var importError: String?
    @State private var searchHits: Set<UUID> = []
    @State private var restoreMessage: String?

    private var filtered: [Lecture] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return lectures }
        return lectures.filter { $0.title.localizedStandardContains(query) || searchHits.contains($0.id) }
    }

    /// The store runs the text match, not a loop over every phrase in memory (0.1 loaded them all
    /// on every keystroke).
    private func runSearch(_ text: String) async {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchHits = []
            return
        }
        try? await Task.sleep(for: .milliseconds(250)) // debounce typing
        guard !Task.isCancelled else { return }
        var descriptor = FetchDescriptor<TranscriptSegment>(predicate: #Predicate { segment in
            segment.text.localizedStandardContains(query)
                || (segment.translation?.localizedStandardContains(query) ?? false)
                || (segment.refinedTranslation?.localizedStandardContains(query) ?? false)
        })
        descriptor.fetchLimit = 5_000
        let segments = (try? context.fetch(descriptor)) ?? []
        searchHits = Set(segments.compactMap { $0.lecture?.id })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(filtered) { lecture in
                    LectureRow(lecture: lecture)
                        .tag(lecture.id)
                }
                .onDelete(perform: delete)
            }
            .navigationTitle("دوّن")
            .searchable(text: $search, prompt: "ابحث في العناوين والنصوص")
            .task(id: search) { await runSearch(search) }
            .overlay {
                if lectures.isEmpty {
                    ContentUnavailableView {
                        Label("لا محاضرات بعد", systemImage: "waveform.badge.mic")
                    } description: {
                        Text("ابدأ تسجيلاً جديداً، أو استورد ملفاً صوتياً.")
                    } actions: {
                        Button("تسجيل جديد") { showNewLecture = true }
                            .buttonStyle(.borderedProminent)
                        // After a database reset: rebuild the library from each folder's lecture.json.
                        Button("استعادة المحاضرات من ملفاتها") {
                            let count = (try? LectureArchive.restoreAll(into: context)) ?? 0
                            restoreMessage = count == 0 ? "لا محاضرات محفوظة للاستعادة." : "استُعيدت \(count) محاضرة."
                        }
                        if let restoreMessage { Text(restoreMessage).font(.footnote) }
                    }
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showNewLecture = true
                    } label: {
                        Label("تسجيل جديد", systemImage: "record.circle")
                    }
                }
                ToolbarItem {
                    Button {
                        showImporter = true
                    } label: {
                        Label("استيراد ملف صوتي", systemImage: "square.and.arrow.down")
                    }
                }
                ToolbarItem {
                    Button {
                        showSettings = true
                    } label: {
                        Label("الإعدادات", systemImage: "gearshape")
                    }
                }
            }
        } detail: {
            if let selection, let lecture = lectures.first(where: { $0.id == selection }) {
                LectureDetailView(lecture: lecture)
                    .id(lecture.id)
            } else {
                ContentUnavailableView("اختر محاضرة", systemImage: "text.bubble", description: Text("النص والترجمة والملخص يظهرون هنا."))
            }
        }
        // A Shortcut or Siri asked for a new lecture.
        .onAppear {
            if LectureRouter.shared.consumeNewLectureRequest() { showNewLecture = true }
        }
        .onChange(of: LectureRouter.shared.newLectureRequested) { _, requested in
            if requested, LectureRouter.shared.consumeNewLectureRequest() { showNewLecture = true }
        }
        // The recording screen opens only after the sheet has finished closing.
        .sheet(isPresented: $showNewLecture, onDismiss: {
            if let request = pendingRecording {
                pendingRecording = nil
                activeRecording = request
            }
        }) {
            NewLectureSheet { request in
                pendingRecording = request
                showNewLecture = false
            }
        }
        .fullScreenCover(item: $activeRecording) { request in
            RecordingView(request: request) { lectureID in
                activeRecording = nil
                selection = lectureID
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio]) { result in
            importAudio(result)
        }
        .alert("تعذّر الاستيراد", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("حسناً", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let lecture = filtered[index]
            if selection == lecture.id { selection = nil }
            LectureStore.deleteFiles(for: lecture)
            context.delete(lecture)
        }
        try? context.save()
    }

    /// Copies the file into the app; the detail view then offers to transcribe it.
    private func importAudio(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let settings = AppSettings.current
        let lecture = Lecture(
            title: url.deletingPathExtension().lastPathComponent,
            sourceLanguage: settings.sourceLanguage,
            targetLanguage: settings.translationEnabled ? settings.targetLanguage : nil,
            engine: .apple
        )
        do {
            let folder = try LectureStore.createFolder(for: lecture.id)
            let name = "imported." + (url.pathExtension.isEmpty ? "m4a" : url.pathExtension.lowercased())
            let destination = folder.appending(path: name)
            try FileManager.default.copyItem(at: url, to: destination)
            lecture.audioSegments = [name]
            lecture.duration = LectureStore.duration(of: [destination])
            lecture.status = .ready
            lecture.transcriptionIncomplete = true
            context.insert(lecture)
            try context.save()
            selection = lecture.id
        } catch {
            importError = error.localizedDescription
        }
    }
}

private struct LectureRow: View {
    let lecture: Lecture

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(lecture.title)
                .font(.headline)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(lecture.createdAt, format: .dateTime.day().month(.abbreviated).hour().minute())
                Text("·")
                Text(TimeFormat.duration(lecture.duration))
                if lecture.summary != nil {
                    Image(systemName: "sparkles").accessibilityLabel("ملخص جاهز")
                }
                if lecture.status == .interrupted {
                    Label("مستعادة", systemImage: "exclamationmark.triangle")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
