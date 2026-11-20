import Foundation
#if os(iOS)
import UIKit
#endif

/// Sends a job's request through a background URL session. The system carries the transfer out of process: it goes
/// on while the app is suspended or closed, and the app is woken (iOS) or handed the reply at next launch (macOS)
/// when it completes. Each task carries its job's id in `taskDescription`; the reply is handed to `JobQueue`.
final class BackgroundTransport: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = BackgroundTransport()
    static let identifier = "org.schrodinger.app.jobs"

    private let lock = NSLock()
    /// Reply bodies by task, between "finished downloading" and "completed".
    private var bodies: [Int: Data] = [:]

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        c.sessionSendsLaunchEvents = true
        c.isDiscretionary = false
        // A reply comes all at once after minutes of work. A background task that times out is sent again by the
        // system, which would start the work over, so the wait for data is long.
        c.timeoutIntervalForRequest = 900
        c.timeoutIntervalForResource = 3600
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    /// Makes the session, so replies that arrived while the app was not running are delivered.
    func wake() { _ = session }

    func send(jobID: UUID, request: URLRequest, body: Data) {
        var r = request
        r.httpBody = body
        let task = session.downloadTask(with: r)
        task.taskDescription = jobID.uuidString
        task.resume()
    }

    /// Jobs with a request still in flight.
    func activeJobIDs() async -> Set<UUID> {
        let tasks = await session.allTasks
        return Set(tasks.compactMap { $0.taskDescription.flatMap(UUID.init(uuidString:)) })
    }

    func cancel(jobID: UUID) async {
        let tasks = await session.allTasks
        for t in tasks where t.taskDescription == jobID.uuidString { t.cancel() }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file is removed when this returns: read it now.
        let data = (try? Data(contentsOf: location)) ?? Data()
        lock.lock(); bodies[downloadTask.taskIdentifier] = data; lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        lock.lock(); let data = bodies.removeValue(forKey: task.taskIdentifier); lock.unlock()
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let cancelled = (error as NSError?)?.code == NSURLErrorCancelled
        let message = error?.localizedDescription
        Task { @MainActor in
            if cancelled { return }
            JobQueue.shared.received(jobID: id, status: status, data: data, error: message)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in BackgroundEvents.finish() }
    }
}

/// iOS wakes the app for a finished background transfer and hands it a block to call once the reply is dealt with.
@MainActor
enum BackgroundEvents {
    static var completion: (() -> Void)? = nil
    static func finish() { completion?(); completion = nil }
}

#if os(iOS)
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        BackgroundEvents.completion = completionHandler
        JobQueue.shared.resume()
    }
}
#endif
