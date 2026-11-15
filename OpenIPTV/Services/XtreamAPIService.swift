import Foundation
import OSLog

private let logger = Logger(subsystem: "com.openiptv.app", category: "XtreamAPI")

final class XtreamAPIService: IPTVRepository {
    private let credentials: XtreamCredentials
    private let decoder = JSONDecoder()
    private let session: URLSession
    private let schemeCache = SchemeCache()

    private static let maxRetries = 3
    private static let initialBackoff: UInt64 = 500_000_000 // 0.5s in ns

    init(credentials: XtreamCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    /// Server + username fully determine which catalog this service returns.
    /// Matches `Profile.repositoryIdentity` so a view can tell whether the
    /// injected repository already points at the active profile.
    var identity: String { "\(credentials.serverURL)|\(credentials.username)" }

    /// Remembers which URL scheme (https/http) succeeded for this server.
    /// Skips the failed-https round-trip on subsequent calls when the server
    /// is HTTP-only — saves several seconds of TLS retry per endpoint on a
    /// fresh sync (which hits 6 endpoints in parallel).
    private actor SchemeCache {
        private var preferred: String?
        func get() -> String? { preferred }
        func set(_ scheme: String) { preferred = scheme }
    }

    // MARK: - Static Authentication

    static func authenticate(serverURL: String, username: String, password: String) async throws -> Account {
        let (_, data, _) = try await requestWithFallback(
            serverURL: serverURL,
            username: username,
            password: password,
            params: [],
            session: .shared
        )
        let account: Account
        do {
            account = try JSONDecoder().decode(Account.self, from: data)
        } catch {
            throw AppError.decodingFailed(error)
        }
        // Panels answer bad credentials with HTTP 200 and `"auth": 0`.
        guard account.info.isAuthenticated else { throw AppError.authenticationFailed }
        return account
    }

    // MARK: - IPTVRepository

    func fetchMovieCategories() async throws -> [Category] {
        try await fetch([Category].self, action: "get_vod_categories")
    }

    func fetchMovies() async throws -> [Movie] {
        try await fetch([Movie].self, action: "get_vod_streams")
    }

    func fetchMovieDetail(id: Int) async throws -> MovieDetail {
        try await fetch(MovieDetail.self, action: "get_vod_info", extra: [URLQueryItem(name: "vod_id", value: "\(id)")])
    }

    func fetchSeriesCategories() async throws -> [Category] {
        try await fetch([Category].self, action: "get_series_categories")
    }

    func fetchSeries() async throws -> [Serie] {
        try await fetch([Serie].self, action: "get_series")
    }

    func fetchSerieDetail(id: Int) async throws -> SerieDetail {
        try await fetch(SerieDetail.self, action: "get_series_info", extra: [URLQueryItem(name: "series_id", value: "\(id)")])
    }

    func fetchLiveCategories() async throws -> [Category] {
        try await fetch([Category].self, action: "get_live_categories")
    }

    func fetchLive() async throws -> [Live] {
        try await fetch([Live].self, action: "get_live_streams")
    }

    func fetchAccount() async throws -> Account {
        try await fetch(Account.self, action: nil)
    }

    func fetchShortEPG(streamId: Int, limit: Int) async throws -> [EPGListing] {
        try await fetch(EPGResponse.self, action: "get_short_epg", extra: [
            URLQueryItem(name: "stream_id", value: "\(streamId)"),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]).listings
    }

    func fetchEPGArchive(streamId: Int) async throws -> [EPGListing] {
        try await fetch(EPGResponse.self, action: "get_simple_data_table", extra: [
            URLQueryItem(name: "stream_id", value: "\(streamId)")
        ]).listings
    }

    // MARK: - Stream URL Construction

    func movieStreamURL(streamId: Int, containerExtension: String) -> URL? {
        Self.streamURL(
            credentials: credentials,
            kind: "movie",
            streamId: streamId,
            extension: containerExtension
        )
    }

    func liveStreamURL(streamId: Int) -> URL? {
        Self.streamURL(
            credentials: credentials,
            kind: "live",
            streamId: streamId,
            extension: "m3u8"
        )
    }

    func episodeStreamURL(episodeId: String, containerExtension: String) -> URL? {
        let host = Self.normalizeHost(credentials.serverURL)
        return URL(string: "https://\(host)/series/\(credentials.username)/\(credentials.password)/\(episodeId).\(containerExtension)")
    }

    func catchupStreamURL(streamId: Int, listing: EPGListing) -> URL? {
        Self.timeshiftURL(credentials: credentials, streamId: streamId, listing: listing)
    }

    /// `/timeshift/{user}/{pass}/{minutes}/{yyyy-MM-dd:HH-mm}/{id}.m3u8`.
    /// The HLS variant is used because AVPlayer can't play the raw `.ts` one.
    static func timeshiftURL(credentials: XtreamCredentials, streamId: Int, listing: EPGListing) -> URL? {
        guard let start = listing.timeshiftStart, listing.durationMinutes > 0 else { return nil }
        let host = normalizeHost(credentials.serverURL)
        let user = pathEscaped(credentials.username)
        let pass = pathEscaped(credentials.password)
        return URL(string: "https://\(host)/timeshift/\(user)/\(pass)/\(listing.durationMinutes)/\(start)/\(streamId).m3u8")
    }

    private static func pathEscaped(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? value
    }

    // MARK: - Private

    /// `action == nil` hits the bare `player_api.php` endpoint, which returns
    /// the account payload.
    private func fetch<T: Decodable>(
        _ type: T.Type,
        action: String?,
        extra: [URLQueryItem] = []
    ) async throws -> T {
        let params = (action.map { [URLQueryItem(name: "action", value: $0)] } ?? []) + extra
        do {
            let preferred = await schemeCache.get()
            let (scheme, data, _) = try await Self.requestWithFallback(
                serverURL: credentials.serverURL,
                username: credentials.username,
                password: credentials.password,
                params: params,
                session: session,
                preferredScheme: preferred
            )
            if preferred != scheme {
                await schemeCache.set(scheme)
            }
            do {
                return try decoder.decode(type, from: data)
            } catch {
                throw AppError.decodingFailed(error)
            }
        } catch {
            throw error
        }
    }

    /// Performs a request with exponential backoff. Tries https first by default,
    /// or `preferredScheme` if provided (so cached HTTP-only servers skip the
    /// failed-TLS round-trip), and falls back to the other scheme on connection
    /// failure (common for Xtream providers with self-signed certs).
    /// Returns the scheme that succeeded so the caller can update its cache.
    private static func requestWithFallback(
        serverURL: String,
        username: String,
        password: String,
        params: [URLQueryItem],
        session: URLSession,
        preferredScheme: String? = nil
    ) async throws -> (scheme: String, data: Data, response: URLResponse) {
        let schemes: [String]
        if let preferred = preferredScheme {
            schemes = [preferred, preferred == "https" ? "http" : "https"]
        } else {
            schemes = ["https", "http"]
        }
        var lastError: Error = AppError.invalidURL

        for scheme in schemes {
            guard let url = buildURL(
                scheme: scheme,
                serverURL: serverURL,
                username: username,
                password: password,
                params: params
            ) else {
                lastError = AppError.invalidURL
                continue
            }

            do {
                let (data, response) = try await requestWithRetry(url: url, session: session)
                return (scheme, data, response)
            } catch let error as URLError where shouldFallback(error) {
                logger.notice("\(scheme, privacy: .public) failed (\(error.code.rawValue, privacy: .public)); falling back")
                lastError = error
                continue
            } catch {
                throw error
            }
        }

        if let urlError = lastError as? URLError, urlError.code == .notConnectedToInternet {
            throw AppError.networkUnavailable
        }
        throw AppError.retriesExhausted(underlying: lastError)
    }

    private static func requestWithRetry(
        url: URL,
        session: URLSession
    ) async throws -> (Data, URLResponse) {
        var attempt = 0
        var backoff = initialBackoff
        var lastError: Error = AppError.invalidURL

        while attempt < maxRetries {
            do {
                let (data, response) = try await session.data(from: url)
                try validate(response: response)
                return (data, response)
            } catch let error as AppError {
                switch error {
                case .invalidResponse(let code) where (500...599).contains(code):
                    lastError = error
                    attempt += 1
                    if attempt >= maxRetries { break }
                    try await Task.sleep(nanoseconds: backoff)
                    backoff *= 2
                default:
                    throw error
                }
            } catch let urlError as URLError where shouldRetry(urlError) {
                lastError = urlError
                attempt += 1
                if attempt >= maxRetries { break }
                try await Task.sleep(nanoseconds: backoff)
                backoff *= 2
            } catch {
                throw error
            }
        }

        throw AppError.retriesExhausted(underlying: lastError)
    }

    private static func shouldRetry(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    private static func shouldFallback(_ error: URLError) -> Bool {
        switch error.code {
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .cannotConnectToHost, .appTransportSecurityRequiresSecureConnection:
            return true
        default:
            return false
        }
    }

    private static func normalizeHost(_ serverURL: String) -> String {
        var host = serverURL
        if let range = host.range(of: "://") {
            host = String(host[range.upperBound...])
        }
        return host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func buildURL(
        scheme: String,
        serverURL: String,
        username: String,
        password: String,
        params: [URLQueryItem]
    ) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = normalizeHost(serverURL)
        components.path = "/player_api.php"
        components.queryItems = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password)
        ] + params
        return components.url
    }

    private static func streamURL(
        credentials: XtreamCredentials,
        kind: String,
        streamId: Int,
        extension ext: String
    ) -> URL? {
        let host = normalizeHost(credentials.serverURL)
        return URL(string: "https://\(host)/\(kind)/\(credentials.username)/\(credentials.password)/\(streamId).\(ext)")
    }

    private static func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AppError.invalidResponse(statusCode: 0)
        }
        guard http.statusCode == 200 else {
            throw AppError.invalidResponse(statusCode: http.statusCode)
        }
    }
}
