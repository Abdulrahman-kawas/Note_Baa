import SwiftUI

/// Shown instead of crashing when the lecture database cannot be opened. The audio and each
/// lecture's `lecture.json` are untouched; a fresh database can be rebuilt from them.
struct DatabaseRecoveryView: View {
    let message: String
    @State private var result: String?

    private static var storeURL: URL { URL.applicationSupportDirectory.appending(path: "default.store") }

    private var storeFiles: [URL] {
        ["", "-shm", "-wal"]
            .map { URL(fileURLWithPath: Self.storeURL.path + $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Couldn't open the lecture database")
                .font(.title2.bold())
            Text("The audio files and each lecture's copy (lecture.json) are intact, and nothing was deleted.")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(6)
                .padding()
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            Button("Share the database files for inspection") {
                SharePresenter.share(storeFiles)
            }
            .buttonStyle(.bordered)
            Button("Move the database aside and start fresh", role: .destructive) {
                result = moveStoreAside()
            }
            .buttonStyle(.borderedProminent)
            if let result {
                Text(result)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: 560)
    }

    /// After relaunch, Library offers "Restore lectures from their files" (LectureArchive.restoreAll).
    private func moveStoreAside() -> String {
        let folder = LectureStore.recoveryFolder.appending(path: "database-\(Int(Date().timeIntervalSince1970))")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in storeFiles {
                try FileManager.default.moveItem(at: file, to: folder.appending(path: file.lastPathComponent))
            }
            return "Moved to Recovery/\(folder.lastPathComponent). Close the app from the app switcher and reopen it, then choose “Restore lectures from their files”."
        } catch {
            return "Couldn't move it: \(error.localizedDescription)"
        }
    }
}
