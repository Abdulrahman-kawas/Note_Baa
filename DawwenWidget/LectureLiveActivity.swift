import ActivityKit
import SwiftUI
import WidgetKit

/// The recording on the Lock Screen and in the Dynamic Island. Needs a Widget Extension target
/// (Xcode ← File ← New ← Target ← Widget Extension, tick Live Activity) that contains this file.
struct LectureLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LectureActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: context.state.isPaused ? "pause.circle.fill" : "record.circle")
                    .foregroundStyle(.red)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.title)
                        .font(.headline)
                        .lineLimit(1)
                    if context.state.isPaused {
                        Text("متوقف مؤقتاً")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding()
            .activityBackgroundTint(.black.opacity(0.6))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "record.circle").foregroundStyle(.red)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.isPaused {
                        Text("متوقف")
                    } else {
                        Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false)
                            .monospacedDigit()
                            .frame(maxWidth: 80)
                    }
                }
            } compactLeading: {
                Image(systemName: "record.circle").foregroundStyle(.red)
            } compactTrailing: {
                if context.state.isPaused {
                    Image(systemName: "pause.fill")
                } else {
                    Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                        .frame(maxWidth: 52)
                }
            } minimal: {
                Image(systemName: "record.circle").foregroundStyle(.red)
            }
        }
    }
}
