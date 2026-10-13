// Apple SpeechTranscriber on a file, the same model the iPad uses for English, for the WER test.
// Mac with macOS 26+:   swift apple_transcribe.swift clips/c1/audio.wav en-US > results/apple/c1.txt
import AVFoundation
import Foundation
import Speech

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: swift apple_transcribe.swift <audio file> [locale, default en-US]\n".utf8))
    exit(2)
}
let audioURL = URL(fileURLWithPath: arguments[1])
let requested = Locale(identifier: arguments.count > 2 ? arguments[2] : "en-US")

guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
    FileHandle.standardError.write(Data("SpeechTranscriber does not support \(requested.identifier)\n".utf8))
    exit(1)
}
let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
    try await request.downloadAndInstall()
}
let analyzer = SpeechAnalyzer(modules: [transcriber])
let collector = Task {
    var phrases: [String] = []
    for try await result in transcriber.results where result.isFinal {
        phrases.append(String(result.text.characters))
    }
    return phrases
}
let file = try AVAudioFile(forReading: audioURL)
if let lastSample = try await analyzer.analyzeSequence(from: file) {
    try await analyzer.finalizeAndFinish(through: lastSample)
} else {
    await analyzer.cancelAndFinishNow()
}
print(try await collector.value.joined(separator: " "))
