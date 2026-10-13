import AVFoundation
import Foundation
import Testing
@testable import Dawwen

struct AudioPartFileTests {
    private func writeTone(seconds: Double, to url: URL) throws {
        let format = SegmentedRecorder.pipelineFormat
        let file = try AVAudioFile(forWriting: url, settings: AudioPartFile.recordingSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = sinf(Float(i) / 10) * 0.5 }
        try file.write(from: buffer)
        file.close()
    }

    @Test func partNames() {
        #expect(AudioPartFile.index(of: "part-012.caf") == 12)
        #expect(AudioPartFile.index(of: "part-012.tmp.m4a") == nil)
        #expect(AudioPartFile.isPart("part-003.m4a"))
        #expect(!AudioPartFile.isPart("lecture.json"))
    }

    /// A writer killed mid-part leaves a CAF whose data size is wrong; repair makes it readable.
    @Test func repairsCrashedCAF() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "crash-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTone(seconds: 10, to: url)
        var data = try Data(contentsOf: url)
        let marker = try #require(data.range(of: Data("data".utf8)))
        data.replaceSubrange(marker.upperBound..<(marker.upperBound + 8), with: Data(repeating: 0, count: 8))
        data.removeLast(12_345) // cut mid-frame, as a crash would
        try data.write(to: url)

        #expect(try AudioPartFile.repairCAF(at: url))
        let repaired = try AVAudioFile(forReading: url)
        #expect(repaired.length > 150_000)
        #expect(try AudioPartFile.repairCAF(at: url) == false) // idempotent
    }

    @Test func transcodesToAACAndRemovesPCM() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "part-000.caf")
        try writeTone(seconds: 30, to: source)

        let output = try #require(try AudioPartFile.transcodeToAAC(source))
        #expect(output.lastPathComponent == "part-000.m4a")
        #expect(!FileManager.default.fileExists(atPath: source.path))
        let file = try AVAudioFile(forReading: output)
        #expect(abs(Double(file.length) / file.processingFormat.sampleRate - 30) < 0.5)
        #expect(LectureStore.partFileNames(in: folder) == ["part-000.m4a"])
    }
}
