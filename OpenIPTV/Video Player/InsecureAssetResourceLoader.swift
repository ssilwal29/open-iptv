import Foundation
import AVFoundation
import Network
import OSLog
import UniformTypeIdentifiers

private let logger = Logger(subsystem: "com.openiptv.app", category: "AssetLoader")

/// Custom URL scheme used to force AVPlayer to call our resource loader delegate.
/// AVPlayer only hands off requests for URLs it doesn't natively know how to load.
let openiptvURLScheme = "openiptv"

extension URL {
    /// Rewrites `http://...` (or any scheme) to `openiptv://...` so AVFoundation
    /// forwards to our delegate. The original host/port/path/query are preserved.
    var asAVPlayerCustomScheme: URL? {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = openiptvURLScheme
        return components.url
    }
}

/// AVAssetResourceLoaderDelegate that services AVFoundation's range requests via
/// raw TCP using Network.framework. Bypasses URLSession (and therefore ATS and
/// TLS trust evaluation) — necessary for Xtream CDNs that serve content over
/// plain HTTP or present self-signed certs.
final class InsecureAssetResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    private let queue = DispatchQueue(label: "com.openiptv.assetloader")
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: NWConnection] = [:]              // keyed by connection id
    private var requestToConnection: [ObjectIdentifier: NWConnection] = [:]      // keyed by loadingRequest id

    private func storeConnection(_ connection: NWConnection, connectionKey: ObjectIdentifier, requestKey: ObjectIdentifier) {
        lock.lock(); defer { lock.unlock() }
        connections[connectionKey] = connection
        requestToConnection[requestKey] = connection
    }

    private func takeConnection(_ key: ObjectIdentifier) -> NWConnection? {
        lock.lock(); defer { lock.unlock() }
        // Also clear any mapping from a loadingRequest that points at this connection
        if let conn = connections.removeValue(forKey: key) {
            for (reqKey, mappedConn) in requestToConnection where ObjectIdentifier(mappedConn) == ObjectIdentifier(conn) {
                requestToConnection.removeValue(forKey: reqKey)
            }
            return conn
        }
        return nil
    }

    private func takeConnectionForRequest(_ requestKey: ObjectIdentifier) -> NWConnection? {
        lock.lock(); defer { lock.unlock() }
        guard let conn = requestToConnection.removeValue(forKey: requestKey) else { return nil }
        connections.removeValue(forKey: ObjectIdentifier(conn))
        return conn
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let customURL = loadingRequest.request.url,
              var components = URLComponents(url: customURL, resolvingAgainstBaseURL: false),
              let host = components.host else {
            return false
        }
        logger.notice("Request: ci=\(loadingRequest.contentInformationRequest != nil) data=\(loadingRequest.dataRequest != nil) offset=\(loadingRequest.dataRequest?.requestedOffset ?? -1) len=\(loadingRequest.dataRequest?.requestedLength ?? -1) allToEnd=\(loadingRequest.dataRequest?.requestsAllDataToEndOfResource ?? false)")
        // Reconstruct the real HTTP URL from our custom-scheme URL.
        components.scheme = "http"
        let port = UInt16(components.port ?? 80)
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        let requestPath = path + query

        let dataRequest = loadingRequest.dataRequest
        let rangeStart = dataRequest?.requestedOffset ?? 0
        let rangeLength = dataRequest?.requestedLength ?? 0
        let wantsAll = dataRequest?.requestsAllDataToEndOfResource ?? false
        let rangeHeader: String = {
            guard rangeStart > 0 || (dataRequest?.requestedLength ?? 0) > 0 else { return "" }
            if wantsAll {
                return "Range: bytes=\(rangeStart)-\r\n"
            }
            let end = rangeStart + Int64(rangeLength) - 1
            return "Range: bytes=\(rangeStart)-\(end)\r\n"
        }()

        let httpRequest = """
        GET \(requestPath) HTTP/1.1\r\n\
        Host: \(host)\r\n\
        User-Agent: OpenIPTV/1.0\r\n\
        Accept: */*\r\n\
        \(rangeHeader)\
        Connection: close\r\n\
        \r\n
        """

        let displayEnd = wantsAll ? -1 : (rangeStart + Int64(rangeLength) - 1)
        logger.notice("TCP \(host, privacy: .private):\(port) range=\(rangeStart)-\(displayEnd)")

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 80
        )
        let connection = NWConnection(to: endpoint, using: .tcp)
        let connectionKey = ObjectIdentifier(connection)
        storeConnection(connection, connectionKey: connectionKey, requestKey: ObjectIdentifier(loadingRequest))

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.sendRequest(
                    httpRequest,
                    on: connection,
                    loadingRequest: loadingRequest,
                    connectionKey: connectionKey,
                    requestedOffset: rangeStart
                )
            case .failed(let error):
                logger.error("NWConnection failed: \(error.localizedDescription, privacy: .public)")
                loadingRequest.finishLoading(with: error)
                self?.cleanup(connectionKey)
            case .cancelled:
                self?.cleanup(connectionKey)
            default:
                break
            }
        }
        connection.start(queue: queue)
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        logger.notice("AVPlayer cancelled one loading request (only its own connection is torn down)")
        if let conn = takeConnectionForRequest(ObjectIdentifier(loadingRequest)) {
            conn.cancel()
        }
    }

    // MARK: - HTTP over TCP

    private func sendRequest(
        _ request: String,
        on connection: NWConnection,
        loadingRequest: AVAssetResourceLoadingRequest,
        connectionKey: ObjectIdentifier,
        requestedOffset: Int64
    ) {
        guard let data = request.data(using: .utf8) else {
            loadingRequest.finishLoading(with: URLError(.badURL))
            cleanup(connectionKey)
            return
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                loadingRequest.finishLoading(with: error)
                self?.cleanup(connectionKey)
                return
            }
            self?.receiveHeaders(
                on: connection,
                loadingRequest: loadingRequest,
                connectionKey: connectionKey,
                requestedOffset: requestedOffset
            )
        })
    }

    private func receiveHeaders(
        on connection: NWConnection,
        loadingRequest: AVAssetResourceLoadingRequest,
        connectionKey: ObjectIdentifier,
        requestedOffset: Int64,
        buffer: Data = Data()
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                loadingRequest.finishLoading(with: error)
                self.cleanup(connectionKey)
                return
            }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            if let headerEnd = accumulated.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                let headerData = accumulated.subdata(in: 0..<headerEnd.lowerBound)
                let bodyData = accumulated.subdata(in: headerEnd.upperBound..<accumulated.count)
                self.handleHeaders(
                    headerData: headerData,
                    firstBodyChunk: bodyData,
                    connection: connection,
                    loadingRequest: loadingRequest,
                    connectionKey: connectionKey,
                    requestedOffset: requestedOffset,
                    isComplete: isComplete
                )
            } else if isComplete {
                loadingRequest.finishLoading(with: URLError(.badServerResponse))
                self.cleanup(connectionKey)
            } else {
                self.receiveHeaders(
                    on: connection,
                    loadingRequest: loadingRequest,
                    connectionKey: connectionKey,
                    requestedOffset: requestedOffset,
                    buffer: accumulated
                )
            }
        }
    }

    private func handleHeaders(
        headerData: Data,
        firstBodyChunk: Data,
        connection: NWConnection,
        loadingRequest: AVAssetResourceLoadingRequest,
        connectionKey: ObjectIdentifier,
        requestedOffset: Int64,
        isComplete: Bool
    ) {
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            loadingRequest.finishLoading(with: URLError(.badServerResponse))
            cleanup(connectionKey)
            return
        }
        let lines = headerString.components(separatedBy: "\r\n")
        guard let statusLine = lines.first, statusLine.hasPrefix("HTTP/") else {
            loadingRequest.finishLoading(with: URLError(.badServerResponse))
            cleanup(connectionKey)
            return
        }

        let headers = parseHeaders(lines.dropFirst())
        let statusCode = Int(statusLine.components(separatedBy: " ").dropFirst().first ?? "") ?? 0

        // Handle redirect by re-issuing request via resource loader
        if (300...399).contains(statusCode), let location = headers["location"] {
            logger.notice("Server redirect to \(location, privacy: .private)")
            cleanup(connectionKey)
            handleRedirect(to: location, original: loadingRequest)
            return
        }

        if !(200...299).contains(statusCode) {
            loadingRequest.finishLoading(with: URLError(.badServerResponse))
            cleanup(connectionKey)
            return
        }

        // Populate content info on the first range reply
        if let info = loadingRequest.contentInformationRequest {
            if let contentRange = headers["content-range"],
               let total = contentRange.components(separatedBy: "/").last,
               let length = Int64(total.trimmingCharacters(in: .whitespaces)) {
                info.contentLength = length
                logger.notice("ContentInfo: length=\(length) (from content-range)")
            } else if let contentLength = headers["content-length"],
                      let length = Int64(contentLength) {
                info.contentLength = length
                logger.notice("ContentInfo: length=\(length) (from content-length)")
            } else {
                logger.notice("ContentInfo: NO length info!")
            }
            let mime = headers["content-type"] ?? "video/mp4"
            let baseMime = mime.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? mime
            let uti = utiForMime(baseMime)
            info.contentType = uti
            info.isByteRangeAccessSupported = true
            logger.notice("ContentInfo: mime=\(mime, privacy: .public) uti=\(uti, privacy: .public) status=\(statusCode)")
        }

        // Detect servers that ignore Range headers — they return status 200 with body
        // starting at byte 0 even when we asked for a higher offset. Parse Content-Range
        // if present; otherwise infer from the status code.
        var serverStartOffset: Int64 = 0
        if let contentRange = headers["content-range"] {
            // Format: "bytes X-Y/total"
            if let bytesPart = contentRange.range(of: "bytes ") {
                let rest = contentRange[bytesPart.upperBound...]
                if let dash = rest.firstIndex(of: "-") {
                    serverStartOffset = Int64(rest[..<dash].trimmingCharacters(in: .whitespaces)) ?? 0
                }
            }
        } else if statusCode == 200 {
            // No Content-Range and status 200 → server ignored Range, body starts at 0.
            serverStartOffset = 0
        } else {
            // Fallback: assume server honored our request.
            serverStartOffset = requestedOffset
        }

        var bytesToSkip = max(0, requestedOffset - serverStartOffset)
        if bytesToSkip > 0 {
            logger.notice("Server returned from offset \(serverStartOffset) but AVPlayer asked for \(requestedOffset); skipping \(bytesToSkip) bytes")
        }

        let (deliver, remainingSkip) = advance(data: firstBodyChunk, skip: bytesToSkip)
        bytesToSkip = remainingSkip

        if !deliver.isEmpty {
            DispatchQueue.main.async {
                loadingRequest.dataRequest?.respond(with: deliver)
            }
            let hex = deliver.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
            logger.notice("Respond initial chunk: \(deliver.count) bytes; first 16 bytes: \(hex, privacy: .public)")
            let mime = headers["content-type"] ?? ""
            if mime.contains("mpegurl"), let text = String(data: deliver, encoding: .utf8) {
                logger.notice("HLS playlist content:\n\(text, privacy: .public)")
            }
        }

        if isComplete {
            DispatchQueue.main.async {
                loadingRequest.finishLoading()
            }
            logger.notice("Finished loading request (complete in first chunk)")
            cleanup(connectionKey)
        } else {
            receiveBody(on: connection, loadingRequest: loadingRequest, connectionKey: connectionKey, bytesToSkip: bytesToSkip)
        }
    }

    /// Drops up to `skip` bytes from the head of `data`. Returns the bytes to deliver
    /// and the remaining skip count (> 0 means the next chunk also needs skipping).
    private func advance(data: Data, skip: Int64) -> (Data, Int64) {
        if skip <= 0 { return (data, 0) }
        if Int64(data.count) <= skip {
            return (Data(), skip - Int64(data.count))
        }
        return (data.subdata(in: Int(skip)..<data.count), 0)
    }

    private func receiveBody(
        on connection: NWConnection,
        loadingRequest: AVAssetResourceLoadingRequest,
        connectionKey: ObjectIdentifier,
        bytesToSkip: Int64 = 0
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                logger.error("receiveBody error: \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async { loadingRequest.finishLoading(with: error) }
                self.cleanup(connectionKey)
                return
            }
            var nextSkip = bytesToSkip
            if let data, !data.isEmpty {
                let (deliver, remainingSkip) = self.advance(data: data, skip: nextSkip)
                nextSkip = remainingSkip
                if !deliver.isEmpty {
                    DispatchQueue.main.async {
                        loadingRequest.dataRequest?.respond(with: deliver)
                    }
                }
                logger.notice("receiveBody chunk: \(data.count) bytes (delivered \(deliver.count), skip remaining \(nextSkip)), complete=\(isComplete)")
            } else {
                logger.notice("receiveBody empty read, complete=\(isComplete)")
            }
            if isComplete {
                DispatchQueue.main.async { loadingRequest.finishLoading() }
                logger.notice("Finished loading request (stream closed)")
                self.cleanup(connectionKey)
            } else {
                self.receiveBody(on: connection, loadingRequest: loadingRequest, connectionKey: connectionKey, bytesToSkip: nextSkip)
            }
        }
    }

    private func handleRedirect(to location: String, original: AVAssetResourceLoadingRequest) {
        guard let newURL = URL(string: location),
              let customURL = newURL.asAVPlayerCustomScheme else {
            original.finishLoading(with: URLError(.badURL))
            return
        }
        let newRequest = URLRequest(url: customURL)
        original.redirect = newRequest
        let response = HTTPURLResponse(
            url: customURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": customURL.absoluteString]
        )
        original.response = response
        original.finishLoading()
    }

    /// Maps a MIME type to the proper UTI string. Explicit mappings for HLS playlists
    /// and MPEG transport streams — UTType's dynamic lookup returns `dyn.xxx` for
    /// these which AVPlayer silently rejects.
    private func utiForMime(_ mime: String) -> String {
        switch mime {
        case "application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/x-mpegurl":
            return "com.apple.mpegurl"
        case "video/mp2t", "video/mpeg2-ts":
            return "public.mpeg-2-transport-stream"
        case "video/mp4", "video/mpeg4":
            return UTType.mpeg4Movie.identifier
        case "video/quicktime":
            return UTType.movie.identifier
        default:
            return UTType(mimeType: mime)?.identifier ?? UTType.mpeg4Movie.identifier
        }
    }

    private func parseHeaders(_ lines: some Sequence<String>) -> [String: String] {
        var out: [String: String] = [:]
        for line in lines {
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let key = line[..<colonIdx].lowercased().trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
            out[key] = value
        }
        return out
    }

    private func cleanup(_ key: ObjectIdentifier) {
        if let conn = takeConnection(key) {
            conn.cancel()
        }
    }
}
