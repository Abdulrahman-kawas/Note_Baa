import SwiftUI

/// The full transcript; tapping a phrase plays the recording from that moment.
struct TranscriptListView: View {
    let lecture: Lecture
    let player: LecturePlayer
    let showTranslation: Bool

    @State private var segments: [TranscriptSegment] = []
    @State private var query = ""
    @State private var follow = true
    @State private var editing: TranscriptSegment?

    private var visible: [TranscriptSegment] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return segments }
        return segments.filter {
            $0.text.localizedStandardContains(text) || ($0.bestTranslation?.localizedStandardContains(text) ?? false)
        }
    }

    /// The phrase being played: the last one starting at or before the playhead (binary search).
    private var activeID: UUID? {
        guard player.currentTime > 0, !segments.isEmpty else { return nil }
        let time = player.currentTime
        var low = 0, high = segments.count - 1, found = -1
        while low <= high {
            let middle = (low + high) / 2
            if segments[middle].start <= time {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return found >= 0 ? segments[found].uid : nil
    }

    private var bookmarkedIDs: Set<UUID> {
        var ids = Set<UUID>()
        for mark in lecture.bookmarks {
            // Binary search, like activeID: segments are sorted by start.
            var low = 0, high = segments.count - 1, found = -1
            while low <= high {
                let middle = (low + high) / 2
                if segments[middle].start <= mark { found = middle; low = middle + 1 } else { high = middle - 1 }
            }
            if found >= 0 { ids.insert(segments[found].uid) }
        }
        return ids
    }

    var body: some View {
        let active = activeID
        let marked = bookmarkedIDs
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if segments.isEmpty {
                        ContentUnavailableView("لا نص بعد", systemImage: "text.bubble", description: Text("استخدم «فرّغ من الصوت» لإنشاء النص."))
                            .padding(.top, 40)
                    }
                    ForEach(visible, id: \.uid) { segment in
                        TranscriptRow(
                            segment: segment,
                            showTranslation: showTranslation,
                            isActive: segment.uid == active,
                            isBookmarked: marked.contains(segment.uid),
                            onEdit: { editing = segment }
                        ) {
                            player.seek(to: segment.start)
                            player.play()
                        }
                        .id(segment.uid)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            .searchable(text: $query, placement: .toolbar, prompt: "ابحث في النص")
            .onChange(of: active) {
                guard follow, player.isPlaying, query.isEmpty, let active else { return }
                withAnimation { proxy.scrollTo(active, anchor: .center) }
            }
            .safeAreaInset(edge: .top) {
                HStack {
                    Text("\(segments.count) جملة")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle("تتبّع التشغيل", isOn: $follow)
                        .toggleStyle(.button)
                        .font(.caption)
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
            }
        }
        .task(id: TranscriptVersion(count: lecture.segments.count, refinedAt: lecture.translationRefinedAt)) {
            segments = lecture.sortedSegments
        }
        .sheet(item: $editing) { segment in
            SegmentEditSheet(segment: segment, lecture: lecture)
        }
    }
}

private struct TranscriptVersion: Equatable {
    let count: Int
    let refinedAt: Date?
}

private struct TranscriptRow: View {
    let segment: TranscriptSegment
    let showTranslation: Bool
    let isActive: Bool
    let isBookmarked: Bool
    let onEdit: () -> Void
    let onSeek: () -> Void

    var body: some View {
        Button(action: onSeek) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(spacing: 4) {
                    Text(TimeFormat.clock(segment.start))
                        .font(.caption.monospacedDigit())
                    if isBookmarked {
                        Image(systemName: "bookmark.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
                .frame(minWidth: 52)

                VStack(alignment: .leading, spacing: 4) {
                    if let speaker = segment.speaker {
                        Text("المتحدث \(speaker)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(segment.text)
                        .textDirection(rightToLeft: segment.text.isMostlyRTL)
                    if showTranslation, let translation = segment.bestTranslation {
                        Text(translation)
                            .foregroundStyle(.blue)
                            .textDirection(rightToLeft: translation.isMostlyRTL)
                    }
                }
            }
            .padding(10)
            .background(isActive ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("تعديل النص", systemImage: "pencil", action: onEdit)
        }
    }
}

/// Fixes a sentence, and a word that the recognizer gets wrong throughout the lecture.
private struct SegmentEditSheet: View {
    let segment: TranscriptSegment
    let lecture: Lecture

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var find = ""
    @State private var replacement = ""
    @State private var result: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("الجملة") {
                    TextField("النص", text: $text, axis: .vertical)
                        .lineLimit(1...8)
                        .textDirection(rightToLeft: text.isMostlyRTL)
                }
                Section {
                    TextField("الكلمة الخاطئة", text: $find)
                    TextField("التصحيح", text: $replacement)
                    Button("استبدل في كل المحاضرة") { replaceAll() }
                        .disabled(find.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("أضف التصحيح إلى المفردات") { addToVocabulary() }
                        .disabled(replacement.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let result {
                        Text(result)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("تصحيح متكرر")
                } footer: {
                    Text("المفردات تساعد محرك التفريغ على التعرّف على الكلمة في المحاضرات القادمة.")
                }
            }
            .navigationTitle("تعديل")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("حفظ") {
                        segment.text = text
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear { text = segment.text }
    }

    private func replaceAll() {
        let count = lecture.sortedSegments.reduce(0) { total, item in
            guard item.text.localizedCaseInsensitiveContains(find) else { return total }
            item.text = item.text.replacingOccurrences(of: find, with: replacement, options: .caseInsensitive)
            return total + 1
        }
        text = segment.text
        result = "عُدّلت \(count) جملة"
    }

    private func addToVocabulary() {
        let term = replacement.trimmingCharacters(in: .whitespaces)
        let defaults = UserDefaults.standard
        let current = defaults.string(forKey: SettingsKey.vocabulary) ?? ""
        let existing = current.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard !existing.contains(term) else {
            result = "الكلمة موجودة في المفردات"
            return
        }
        defaults.set(current.isEmpty ? term : current + "\n" + term, forKey: SettingsKey.vocabulary)
        result = "أُضيفت إلى المفردات"
    }
}
