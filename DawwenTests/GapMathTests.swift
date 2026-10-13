import Testing
@testable import Dawwen

struct GapMathTests {
    @Test func mergesOverlappingAndNearbyGaps() {
        let merged = GapMath.merged([
            TranscriptGap(start: 10, end: 20, reason: .network),
            TranscriptGap(start: 0, end: 5, reason: .engineStarting),
            TranscriptGap(start: 20.5, end: 30, reason: .network),   // within 1 s: joins
            TranscriptGap(start: 40, end: 41, reason: .heat)
        ])
        #expect(merged.map(\.start) == [0, 10, 40])
        #expect(merged.map(\.end) == [5, 30, 41])
    }

    @Test func infersHeadHolesAndTail() {
        let gaps = GapMath.inferred(from: [(start: 30, end: 40), (start: 45, end: 50), (start: 100, end: 110)], duration: 200)
        #expect(gaps.map(\.start) == [0, 50, 110])
        #expect(gaps.map(\.end) == [30, 100, 200])
        #expect(GapMath.inferred(from: [], duration: 60).count == 1)
    }

    @Test func splitsLongGapsIntoWindows() {
        let windows = GapMath.windows(of: TranscriptGap(start: 0, end: 1500, reason: .recordOnly), maxLength: 600)
        #expect(windows.map(\.start) == [0, 600, 1200])
        #expect(windows.last?.end == 1500)
    }
}
