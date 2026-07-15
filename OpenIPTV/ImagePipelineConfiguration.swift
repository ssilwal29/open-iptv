import Foundation
import Nuke

enum ImagePipelineConfiguration {
    /// Call once at app launch. Replaces Nuke's shared pipeline with one
    /// tuned for IPTV poster loads:
    /// - 100 MB in-memory LRU (recently viewed posters stay warm)
    /// - 250 MB on-disk LRU (survives relaunches, auto-evicts oldest)
    /// - Custom DataLoader with a URLSession delegate that rewrites any
    ///   `http://` redirect back to `https://` — Xtream image CDNs commonly
    ///   HTTPS → HTTP redirect, and tvOS 26 enforces ATS even for release builds.
    /// - Rate-limiter on (avoid thundering-herd when a grid of 50 tiles appears)
    static func apply() {
        let dataCache = try? DataCache(name: "com.openiptv.images")
        dataCache?.sizeLimit = 250 * 1024 * 1024

        let imageCache = ImageCache()
        imageCache.costLimit = 100 * 1024 * 1024
        imageCache.countLimit = 600

        let pipeline = ImagePipeline {
            $0.dataCache = dataCache
            $0.imageCache = imageCache
            $0.dataLoader = HTTPSEnforcingDataLoader()
            $0.isRateLimiterEnabled = true
            $0.isTaskCoalescingEnabled = true
        }

        ImagePipeline.shared = pipeline
    }
}

/// Nuke `DataLoading` wrapper around a URLSession whose delegate rewrites any
/// `http://` redirect target to `https://`. Keeps all the ATS-permitted TLS paths
/// working while preventing CDN redirects from kicking the request onto cleartext
/// HTTP, which tvOS 26 aggressively blocks.
private final class HTTPSEnforcingDataLoader: NSObject, DataLoading, URLSessionTaskDelegate {

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func loadData(
        with request: URLRequest,
        didReceiveData: @escaping (Data, URLResponse) -> Void,
        completion: @escaping (Error?) -> Void
    ) -> any Cancellable {
        // Force https at request time, then the redirect handler catches any downstream
        // http:// Location header the origin tries to send us to.
        var req = request
        if let url = req.url, url.scheme == "http" {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.scheme = "https"
            if components?.port == 80 || components?.port == 8080 { components?.port = nil }
            req.url = components?.url ?? url
        }

        let task = session.dataTask(with: req)
        let wrapper = Wrapper(task: task, didReceiveData: didReceiveData, completion: completion)
        task.taskDescription = wrapper.id
        taskMap[task.taskIdentifier] = wrapper
        task.resume()
        return wrapper
    }

    // MARK: - Task registry

    private var taskMap: [Int: Wrapper] = [:]
    private let lock = NSLock()

    private func wrapper(for task: URLSessionTask) -> Wrapper? {
        lock.lock(); defer { lock.unlock() }
        return taskMap[task.taskIdentifier]
    }

    private func remove(task: URLSessionTask) {
        lock.lock(); defer { lock.unlock() }
        taskMap.removeValue(forKey: task.taskIdentifier)
    }

    // MARK: - URLSessionTaskDelegate

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url else {
            completionHandler(request)
            return
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if components?.scheme == "http" {
            components?.scheme = "https"
            if components?.port == 80 || components?.port == 8080 { components?.port = nil }
        }
        var rewritten = request
        rewritten.url = components?.url ?? url
        completionHandler(rewritten)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) { }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let w = wrapper(for: dataTask), let response = dataTask.response else { return }
        w.didReceiveData(data, response)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let w = wrapper(for: task) else { return }
        remove(task: task)
        w.completion(error)
    }

    // MARK: - Wrapper

    private final class Wrapper: Cancellable {
        let id: String
        let task: URLSessionTask
        let didReceiveData: (Data, URLResponse) -> Void
        let completion: (Error?) -> Void

        init(task: URLSessionTask, didReceiveData: @escaping (Data, URLResponse) -> Void, completion: @escaping (Error?) -> Void) {
            self.id = UUID().uuidString
            self.task = task
            self.didReceiveData = didReceiveData
            self.completion = completion
        }

        func cancel() { task.cancel() }
    }

    // We need a DataLoading-compatible delegate. Nuke's protocol requires this.
    // Making the session's delegate be self, and forwarding data to the wrapper.
    // Note: we inherit URLSessionDataDelegate through URLSessionTaskDelegate.
}

extension HTTPSEnforcingDataLoader: URLSessionDataDelegate { }
