import SwiftUI

protocol IPTVRepository: AnyObject {
    /// Stable identifier for the credentials this repository talks to. Used to
    /// detect when the injected repository has caught up to a profile switch
    /// (server + username uniquely determine the content it will return).
    var identity: String { get }

    func fetchMovieCategories() async throws -> [Category]
    func fetchMovies() async throws -> [Movie]
    func fetchMovieDetail(id: Int) async throws -> MovieDetail
    func fetchSeriesCategories() async throws -> [Category]
    func fetchSeries() async throws -> [Serie]
    func fetchSerieDetail(id: Int) async throws -> SerieDetail
    func fetchLiveCategories() async throws -> [Category]
    func fetchLive() async throws -> [Live]
    func movieStreamURL(streamId: Int, containerExtension: String) -> URL?
    func liveStreamURL(streamId: Int) -> URL?
    func episodeStreamURL(episodeId: String, containerExtension: String) -> URL?
}

// MARK: - SwiftUI Environment

private struct IPTVRepositoryKey: EnvironmentKey {
    static let defaultValue: (any IPTVRepository)? = nil
}

extension EnvironmentValues {
    var iptvRepository: (any IPTVRepository)? {
        get { self[IPTVRepositoryKey.self] }
        set { self[IPTVRepositoryKey.self] = newValue }
    }
}
