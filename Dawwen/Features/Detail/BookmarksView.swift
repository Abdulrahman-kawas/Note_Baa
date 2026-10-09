import SwiftData
import SwiftUI

struct BookmarksView: View {
    @Bindable var lecture: Lecture
    let player: LecturePlayer

    @Environment(\.modelContext) private var context

    private var marks: [Double] { lecture.bookmarks.sorted() }

    var body: some View {
        List {
            ForEach(marks, id: \.self) { mark in
                Button {
                    player.seek(to: max(0, mark - 5)) // Start a little before the tap.
                    player.play()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Image(systemName: "bookmark.fill").foregroundStyle(.orange)
                        Text(TimeFormat.clock(mark))
                            .monospacedDigit()
                        Text(snippet(at: mark))
                            .lineLimit(2)
                            .foregroundStyle(.secondary)
                            .textDirection(rightToLeft: snippet(at: mark).isMostlyRTL)
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
                ContentUnavailableView("لا علامات", systemImage: "bookmark", description: Text("اضغط «علامة» أثناء التسجيل لتمييز لحظة مهمة."))
            }
        }
    }

    private func snippet(at time: Double) -> String {
        lecture.sortedSegments.last(where: { $0.start <= time })?.text ?? ""
    }
}
