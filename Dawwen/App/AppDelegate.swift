import UIKit
import UserNotifications

/// Only what SwiftUI cannot do: background-upload relaunches and in-app notification banners.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// The system relaunched the app to report finished backup uploads.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackupUploader.sessionIdentifier else {
            completionHandler()
            return
        }
        BackupUploader.shared.backgroundCompletion = completionHandler
        Task { await BackupUploader.shared.reconnect() }
    }

    /// Show recording alerts even while the app is open.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
