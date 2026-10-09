import SwiftUI

struct PlayerBar: View {
    let player: LecturePlayer
    @State private var scrubbing: Double?

    private let rates: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(get: { scrubbing ?? player.currentTime }, set: { scrubbing = $0 }),
                in: 0...max(player.duration, 1)
            ) { editing in
                if !editing, let target = scrubbing {
                    player.seek(to: target)
                    scrubbing = nil
                }
            }
            HStack(spacing: 18) {
                Text(TimeFormat.clock(scrubbing ?? player.currentTime))
                    .monospacedDigit()
                    .font(.caption)
                Spacer()
                Button { player.skip(by: -15) } label: {
                    Image(systemName: "gobackward.15").accessibilityLabel("رجوع 15 ثانية")
                }
                Button { player.togglePlayback() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 40))
                        .accessibilityLabel(player.isPlaying ? "إيقاف مؤقت" : "تشغيل")
                }
                Button { player.skip(by: 15) } label: {
                    Image(systemName: "goforward.15").accessibilityLabel("تقديم 15 ثانية")
                }
                Spacer()
                Menu {
                    ForEach(rates, id: \.self) { rate in
                        Button(Self.label(for: rate)) { player.rate = rate }
                    }
                } label: {
                    Text(Self.label(for: player.rate))
                        .font(.callout.monospacedDigit())
                }
                Text(TimeFormat.clock(player.duration))
                    .monospacedDigit()
                    .font(.caption)
            }
            .font(.title3)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
        // Media controls keep the direction of time, even in the Arabic interface.
        .environment(\.layoutDirection, .leftToRight)
        .disabled(!player.isReady)
    }

    private static func label(for rate: Float) -> String {
        rate == 1 ? "1×" : String(format: "%g×", rate)
    }
}
