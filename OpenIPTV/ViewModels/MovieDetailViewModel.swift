import Foundation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class MovieDetailViewModel {
    var plot: String = "No description available."
    var genre: String = ""
    var releaseDate: String = ""
    var cast: String = ""
    var director: String = ""
    var duration: String = ""
    var rating: String = ""
    var backdropURL: URL?
    var isLoading = false
    var errorMessage: String?

    private static let detailCacheTTL: TimeInterval = 60 * 60 * 24 * 30

    func load(
        movie: MovieEntity,
        using repository: any IPTVRepository,
        context: ModelContext
    ) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        // The stream URL is resolved on-press (see MovieDetailView.startPlayback),
        // not eagerly here — so a detail open that never plays does no probe.

        if let cached = movie.detail, isFresh(cached) {
            apply(cached)
            return
        }

        do {
            let remote = try await repository.fetchMovieDetail(id: movie.streamId)
            let entity = MovieDetailEntity(
                streamId: movie.streamId,
                plot: remote.info.plot,
                genre: remote.info.genre,
                cast: remote.info.cast,
                director: remote.info.director,
                releaseDate: remote.info.releaseDate,
                duration: remote.info.duration,
                durationSecs: remote.info.durationSecs,
                rating: remote.info.rating,
                backdrop: remote.info.backdrop,
                youtubeTrailer: remote.info.youtubeTrailer,
                fetchedAt: .now,
                movie: movie
            )
            if let stale = movie.detail {
                context.delete(stale)
            }
            context.insert(entity)
            movie.detail = entity
            apply(entity)
            // Persist off the critical path — the UI already has the data
            // in memory via the in-context insert, the save just flushes to
            // disk and would otherwise block the detail view's first render.
            DeferredSave.schedule(context)
        } catch {
            if let cached = movie.detail {
                apply(cached)
            }
            errorMessage = error.localizedDescription
        }
    }

    private func isFresh(_ detail: MovieDetailEntity) -> Bool {
        Date().timeIntervalSince(detail.fetchedAt) < Self.detailCacheTTL
    }

    private func apply(_ detail: MovieDetailEntity) {
        plot = detail.plot.isEmpty ? "No description available." : detail.plot
        genre = detail.genre
        releaseDate = detail.releaseDate
        cast = detail.cast
        director = detail.director
        duration = detail.duration
        rating = detail.rating
        backdropURL = detail.backdrop.secureURL
    }
}
