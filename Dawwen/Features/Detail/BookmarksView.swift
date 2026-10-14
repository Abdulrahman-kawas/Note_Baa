import SwiftData
import SwiftUI

struct BookmarksView: View {
    @Bindable var lecture: Lecture
    let player: LecturePlayer

    @Environment(\.modelContext) private var context

    private var marks: [Double] { lecture.bookmarks.sorted() }

    var body: some View {
        let sorted = lecture.sortedSegments // once per render, not twice per row
        List {
            ForEach(marks, id: \.self) { mark in
                let snippet = sorted.last(where: { $0.start <= mark })?.text ?? ""
                Button {
                    player.seek(to: max(0, mark - 5)) // Start a little before the tap.
                    player.play()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Image(systemName: "bookmark.fill").foregroundStyle(.orange)
                        Text(TimeFormat.clock(mark))
                            .monospacedDigit()
                        Text(snippet)
                            .lineLimit(2)
                            .foregroundStyle(.secondary)
                            .textDirection(rightToLeft: snippet.isMostlyRTL)
                    }
                }
            }
            .onDelete { offsets in
                let removed = Set(offsets.map { marks[$0] })
                lecture.bookmarks.removeAll { removed.contains($0) }
                try? context.save()
            }
        }
        .overlay {
            if marks.isEmpty {
                ContentUnavailableView("No bookmarks", systemImage: "bookmark", description: Text("Tap Bookmark while recording to mark an important moment."))
            }
        }
    }
}
