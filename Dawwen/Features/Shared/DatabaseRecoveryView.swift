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
            Text("تعذّر فتح قاعدة بيانات المحاضرات")
                .font(.title2.bold())
            Text("ملفات الصوت ونسخة كل محاضرة (lecture.json) سليمة ولم يُحذف شيء.")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(6)
                .padding()
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            Button("شارك ملفات قاعدة البيانات لفحصها") {
                SharePresenter.share(storeFiles)
            }
            .buttonStyle(.bordered)
            Button("انقل قاعدة البيانات جانباً وابدأ من جديد", role: .destructive) {
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

    /// After relaunch, Library offers "استعادة المحاضرات من ملفاتها" (LectureArchive.restoreAll).
    private func moveStoreAside() -> String {
        let folder = LectureStore.recoveryFolder.appending(path: "database-\(Int(Date().timeIntervalSince1970))")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in storeFiles {
                try FileManager.default.moveItem(at: file, to: folder.appending(path: file.lastPathComponent))
            }
            return "نُقلت إلى Recovery/\(folder.lastPathComponent). أغلق التطبيق من مبدّل التطبيقات وافتحه، ثم اختر «استعادة المحاضرات من ملفاتها»."
        } catch {
            return "تعذّر النقل: \(error.localizedDescription)"
        }
    }
}
