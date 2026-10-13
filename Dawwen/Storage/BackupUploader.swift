import CryptoKit
import Foundation
import os
import SwiftData

/// Copies closed audio parts and `lecture.json` to S3 through presigned URLs from the gateway.
/// Uploads run in a background URLSession: they finish even if the app is suspended or killed,
/// and the system relaunches the app to report them. Off unless Settings ▸ Server ▸ Backup is on.
@MainActor
final class BackupUploader {
    static let shared = BackupUploader()
    static let sessionIdentifier = "com.dawwen.backup"

    /// Set at launch so delegate callbacks can mark uploads done.
    var container: ModelContainer?
    /// From `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    var backgroundCompletion: (() -> Void)?

    private let log = Logger(subsystem: "com.dawwen", category: "backup")
    private var inFlight: Set<String> = []
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        return URLSession(configuration: configuration, delegate: BackupSessionDelegate(), delegateQueue: nil)
    }()

    /// Recreating the session with the same identifier reconnects to uploads from a previous run.
    func reconnect() async {
        for task in await session.allTasks {
            if let key = task.taskDescription { inFlight.insert(key) }
        }
    }

    /// Everything not yet backed up, for every finished lecture (launch, foreground).
    func enqueuePending() async {
        guard AppSettings.current.backupEnabled, ServerClient.current != nil, let context = container?.mainContext else { return }
        await reconnect()
        let recording = LectureStatus.recording.rawValue
        let lectures = (try? context.fetch(FetchDescriptor<Lecture>(predicate: #Predicate { $0.statusRaw != recording }))) ?? []
        for lecture in lectures {
            enqueue(lecture, includeArchive: lecture.archiveUploadedAt == nil)
        }
    }

    func enqueue(_ lecture: Lecture, includeArchive: Bool) {
        guard AppSettings.current.backupEnabled, let server = ServerClient.current else { return }
        let lectureID = lecture.id
        let folder = LectureStore.folder(for: lectureID)
        var names = lecture.audioSegments.filter {
            $0.hasSuffix(".\(AudioPartFile.archiveExtension)") && !lecture.uploadedParts.contains($0)
        }
        if lecture.status != .recording {
            // Parts that never made it to AAC go up as CAF once the lecture is over.
            names += lecture.audioSegments.filter { $0.hasSuffix(".\(AudioPartFile.openExtension)") && !lecture.uploadedParts.contains($0) }
        }
        if includeArchive, (try? LectureArchive.write(lecture)) != nil {
            names.append(LectureArchive.fileName)
        }
        for name in names {
            let key = "\(lectureID.uuidString)|\(name)"
            guard !inFlight.contains(key) else { continue }
            inFlight.insert(key)
            let file = folder.appending(path: name)
            Task {
                do {
                    let (digest, size) = try await Task.detached(priority: .utility) { try Self.fingerprint(file) }.value
                    let target = try await server.uploadTarget(lectureID: lectureID, name: name, sha256: digest, bytes: size)
                    var request = URLRequest(url: target.url)
                    request.httpMethod = "PUT"
                    for (field, value) in target.headers { request.setValue(value, forHTTPHeaderField: field) }
                    let upload = self.session.uploadTask(with: request, fromFile: file)
                    upload.taskDescription = key
                    upload.resume()
                } catch {
                    self.inFlight.remove(key) // retried at the next launch or foreground
                    self.log.error("backup \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    nonisolated static func fingerprint(_ url: URL) throws -> (String, Int) {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (digest, data.count)
    }

    /// Delegate callback, hopped to the main actor.
    func finished(key: String, statusCode: Int?, error: Error?) {
        inFlight.remove(key)
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let lectureID = UUID(uuidString: parts[0]) else { return }
        guard error == nil, let statusCode, (200..<300).contains(statusCode) else {
            log.error("upload \(key, privacy: .public) failed: \(statusCode ?? -1)")
            return
        }
        guard let context = container?.mainContext,
              let lecture = try? context.fetch(FetchDescriptor<Lecture>(predicate: #Predicate { $0.id == lectureID })).first
        else { return }
        if parts[1] == LectureArchive.fileName {
            lecture.archiveUploadedAt = .now
        } else {
            lecture.uploadedParts.insert(parts[1])
        }
        try? context.save()
    }

    func allEventsDelivered() {
        backgroundCompletion?()
        backgroundCompletion = nil
    }
}

/// URLSession delegates are called on a background queue; everything is forwarded to the main actor.
final class BackupSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let key = task.taskDescription ?? ""
        let status = (task.response as? HTTPURLResponse)?.statusCode
        Task { @MainActor in BackupUploader.shared.finished(key: key, statusCode: status, error: error) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in BackupUploader.shared.allEventsDelivered() }
    }
}
