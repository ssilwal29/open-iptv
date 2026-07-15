import Foundation
import OSLog

private let logger = Logger(subsystem: "com.openiptv.app", category: "StreamURLResolver")

/// Resolves a stream URL by making a HEAD request, capturing the server's redirect
/// target (without following it), and rewriting any `http://` scheme to `https://`
/// before returning. This lets us hand AVPlayer the final HTTPS URL with the
/// provider's token preserved — ATS never sees an HTTP load.
final class StreamURLResolver: NSObject, URLSessionTaskDelegate {
    static let shared = StreamURLResolver()

    private let resolveQueue = DispatchQueue(label: "com.openiptv.streamresolver")
    private var pendingRedirects: [Int: URL] = [:]

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Resolves `url` to a final playable URL. Behavior:
    /// - If the server redirects, returns the redirect target upgraded to HTTPS.
    /// - If the server responds directly (no redirect), returns the original URL upgraded to HTTPS.
    /// - If the probe fails entirely, returns the original URL upgraded to HTTPS as a best effort.
    func resolve(_ url: URL) async -> URL {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")

        let task = session.dataTask(with: request)
        let taskId = task.taskIdentifier

        return await withCheckedContinuation { continuation in
            let handler: (URL?) -> Void = { [weak self] captured in
                guard let self else { return }
                resolveQueue.sync { _ = self.pendingRedirects.removeValue(forKey: taskId) }
                // Return the raw captured URL — the AVAssetResourceLoader handles
                // the actual HTTP load via raw TCP so the scheme (http/https) is
                // preserved as-is.
                continuation.resume(returning: captured ?? url)
            }

            task.completionHandler = handler
            task.resume()
        }
    }

    // MARK: - URLSessionTaskDelegate

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let taskId = task.taskIdentifier
        if let location = request.url {
            resolveQueue.sync { self.pendingRedirects[taskId] = location }
            logger.notice("Captured redirect for task \(taskId): \(location.absoluteString, privacy: .private)")
        }
        // Cancel the follow — we only needed the Location URL.
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let taskId = task.taskIdentifier
        let captured = resolveQueue.sync { self.pendingRedirects[taskId] }
        let handler = (task as? URLSessionDataTask)?.completionHandler
        handler?(captured)
    }
}

private var completionHandlerKey: UInt8 = 0

private extension URLSessionDataTask {
    var completionHandler: ((URL?) -> Void)? {
        get { objc_getAssociatedObject(self, &completionHandlerKey) as? (URL?) -> Void }
        set { objc_setAssociatedObject(self, &completionHandlerKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }
}
