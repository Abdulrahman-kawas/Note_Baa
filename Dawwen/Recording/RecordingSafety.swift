import Foundation
import UIKit
import UserNotifications

/// Local notifications for the failures a student must not miss while the screen is locked.
enum RecordingAlerts {
    static func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    static func post(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "dawwen.recording.\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

/// Free space checks: before recording and every minute during it.
enum StorageGuard {
    struct Status {
        let freeBytes: Int64
        /// Below this, recording would soon fail: refuse to start, stop gracefully mid-lecture.
        var isCritical: Bool { freeBytes < 300_000_000 }
        /// A 4-hour lecture needs ~70 MB of AAC plus ~10 MB for the open PCM part; warn early.
        var isLow: Bool { freeBytes < 1_000_000_000 }
        var description: String { ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file) }
    }

    static func status() -> Status? {
        let values = try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage else { return nil }
        return Status(freeBytes: free)
    }
}

/// Keeps the app running briefly after the student leaves it, so a streaming request can finish.
@MainActor
final class BackgroundAssertion {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
