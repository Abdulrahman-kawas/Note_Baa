import SwiftData
import SwiftUI
import Translation

struct RecordingView: View {
    let request: NewLectureRequest
    var onFinish: (UUID?) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var controller = RecordingController()
    @State private var confirmStop = false
    @State private var followLive = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                if let banner = controller.banner {
                    Text(banner)
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(.yellow.opacity(0.18))
                }
                Divider()
                transcript
                Divider()
                controls
            }
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if controller.phase == .finished { finishedCard }
                if case .failed(let message) = controller.phase { failedCard(message) }
            }
        }
        .translationTask(controller.translationConfiguration) { session in
            await controller.translationQueue.run(with: session)
        }
        .task {
            await controller.start(request, context: context)
        }
        .interactiveDismissDisabled(controller.isActive)
        .onDisappear { controller.dismantle() }
        .confirmationDialog("إنهاء التسجيل؟", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("إنهاء وحفظ", role: .destructive) {
                Task { await controller.stop() }
            }
            Button("متابعة التسجيل", role: .cancel) {}
        } message: {
            Text("يُحفظ الصوت والنص، ويمكنك التلخيص بعدها.")
        }
    }

    // MARK: - Parts

    private var header: some View {
        VStack(spacing: 10) {
            Text(TimeFormat.clock(controller.elapsed))
                .font(.system(size: 56, weight: .light, design: .rounded).monospacedDigit())
                .environment(\.layoutDirection, .leftToRight)
            LevelMeter(level: controller.level)
                .frame(maxWidth: 360)
            HStack(spacing: 12) {
                Label(statusText, systemImage: statusIcon)
                    .foregroundStyle(statusColor)
                if !controller.engineName.isEmpty {
                    Text("·")
                    Text(controller.engineName)
                }
                if controller.translationQueue.pendingCount > 0 {
                    Text("·")
                    Text("بانتظار الترجمة: \(controller.translationQueue.pendingCount)")
                }
                if controller.translationQueue.failedCount > 0 {
                    Text("·")
                    Text("تعذّرت ترجمة \(controller.translationQueue.failedCount)").foregroundStyle(.orange)
                }
                if controller.gapSeconds >= 5 {
                    Text("·")
                    Text("دون نص: \(TimeFormat.clock(controller.gapSeconds))").foregroundStyle(.orange)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if controller.liveSegments.isEmpty && controller.partialText.isEmpty {
                        Text(controller.phase == .recording ? "النص يظهر هنا أثناء الكلام…" : "")
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    ForEach(controller.liveSegments, id: \.uid) { segment in
                        LiveSegmentRow(segment: segment, sideBySide: sizeClass == .regular)
                            .id(segment.uid)
                    }
                    if !controller.partialText.isEmpty {
                        Text(controller.partialText)
                            .foregroundStyle(.secondary)
                            .textDirection(rightToLeft: controller.partialText.isMostlyRTL)
                    }
                    Color.clear.frame(height: 1).id("live-bottom")
                }
                .padding()
            }
            .onChange(of: controller.liveSegments.count) {
                if followLive { proxy.scrollTo("live-bottom", anchor: .bottom) }
            }
            .onChange(of: controller.partialText) {
                if followLive { proxy.scrollTo("live-bottom", anchor: .bottom) }
            }
            .safeAreaInset(edge: .top) {
                HStack {
                    Spacer()
                    Toggle("متابعة النص", isOn: $followLive)
                        .toggleStyle(.button)
                        .font(.caption)
                        .padding(8)
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 36) {
            Button {
                controller.addBookmark()
            } label: {
                Label("علامة", systemImage: "bookmark.fill")
                    .labelStyle(.verticalIcon)
            }
            .disabled(controller.phase != .recording)

            Button {
                if case .paused = controller.phase { controller.resume() } else { controller.pause() }
            } label: {
                Image(systemName: isPaused ? "play.circle.fill" : "pause.circle.fill")
                    .font(.system(size: 64))
                    .accessibilityLabel(isPaused ? "استئناف" : "إيقاف مؤقت")
            }
            .disabled(!(controller.phase == .recording || isPaused))

            Button(role: .destructive) {
                confirmStop = true
            } label: {
                Label("إنهاء", systemImage: "stop.circle.fill")
                    .labelStyle(.verticalIcon)
            }
            .disabled(!(controller.phase == .recording || isPaused))
        }
        .font(.title3)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var finishedCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("اكتمل التسجيل").font(.title2.bold())
            Text("\(TimeFormat.duration(controller.elapsed)) · \(controller.liveSegments.count) جملة")
                .foregroundStyle(.secondary)
            if controller.translationQueue.pendingCount > 0 {
                Label("تُترجم \(controller.translationQueue.pendingCount) جملة الآن؛ ما يتبقى يُترجم تلقائياً عند فتح المحاضرة.", systemImage: "character.bubble")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if controller.gapSeconds >= 5 {
                Label("\(TimeFormat.duration(controller.gapSeconds)) دون نص لحظي؛ أكملها من صفحة المحاضرة.", systemImage: "text.badge.plus")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("فتح المحاضرة") { onFinish(controller.lecture?.id) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding()
    }

    private func failedCard(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
            Button("إغلاق") { onFinish(controller.lecture?.id) }
                .buttonStyle(.borderedProminent)
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding()
    }

    // MARK: - Status

    private var isPaused: Bool {
        if case .paused = controller.phase { return true }
        return false
    }

    private var statusText: String {
        switch controller.phase {
        case .idle: "جاهز"
        case .preparing(let message): message
        case .recording: "يسجّل"
        case .paused(let message): message
        case .finishing: "إنهاء التفريغ وحفظ المحاضرة…"
        case .finished: "انتهى"
        case .failed: "خطأ"
        }
    }

    private var statusIcon: String {
        switch controller.phase {
        case .recording: "record.circle"
        case .paused: "pause.circle"
        case .finished: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        default: "hourglass"
        }
    }

    private var statusColor: Color {
        switch controller.phase {
        case .recording: .red
        case .paused: .orange
        default: .secondary
        }
    }
}

private struct LiveSegmentRow: View {
    let segment: TranscriptSegment
    let sideBySide: Bool

    var body: some View {
        let layout = sideBySide
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 24))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
        layout {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(TimeFormat.clock(segment.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Text(segment.text)
                    .textDirection(rightToLeft: segment.text.isMostlyRTL)
            }
            if let translation = segment.translation {
                Text(translation)
                    .foregroundStyle(.blue)
                    .textDirection(rightToLeft: translation.isMostlyRTL)
            } else if sideBySide {
                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
            }
        }
    }
}

private struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(level > 0.9 ? Color.orange : Color.green)
                    .frame(width: proxy.size.width * CGFloat(level))
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.1), value: level)
        .accessibilityHidden(true)
    }
}

private extension LabelStyle where Self == VerticalIconLabelStyle {
    static var verticalIcon: VerticalIconLabelStyle { VerticalIconLabelStyle() }
}

private struct VerticalIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 4) {
            configuration.icon.font(.title)
            configuration.title.font(.caption)
        }
    }
}
