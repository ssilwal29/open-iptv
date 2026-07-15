import Foundation
import OSLog
import SwiftData
import SwiftUI

@MainActor
@Observable
final class SerieDetailViewModel {
    var isLoading = false
    var errorMessage: String?

    private static let detailCacheTTL: TimeInterval = 60 * 60 * 24 * 30
    private static let logger = Logger(subsystem: "com.openiptv.app", category: "SerieDetailViewModel")

    func load(
        serie: SerieEntity,
        using repository: any IPTVRepository,
        context: ModelContext
    ) async {
        guard !isLoading else { return }

        // Cache hit only when we have BOTH seasons and at least one episode.
        // A prior failed-decode run can leave behind empty SeasonEntity rows
        // — without the episode check we'd permanently skip the refetch.
        let hasAnyEpisode = serie.seasons.contains { !$0.episodes.isEmpty }
        if let fetched = serie.detailFetchedAt,
           Date().timeIntervalSince(fetched) < Self.detailCacheTTL,
           !serie.seasons.isEmpty,
           hasAnyEpisode {
            Self.logger.notice("Cache hit for series \(serie.seriesId) — \(serie.seasons.count) seasons cached")
            return
        }

        Self.logger.notice("Fetching series \(serie.seriesId) — cached: seasons=\(serie.seasons.count) hasAnyEpisode=\(hasAnyEpisode)")
        isLoading = true
        defer { isLoading = false }

        do {
            let remote = try await repository.fetchSerieDetail(id: serie.seriesId)
            let episodesBySeason = remote.episodes.reduce(into: [Int: [SerieDetail.Episode]]()) { acc, pair in
                if let seasonNum = Int(pair.key) {
                    acc[seasonNum] = pair.value
                }
            }

            let totalEpisodes = episodesBySeason.values.reduce(0) { $0 + $1.count }
            Self.logger.notice("Fetched series \(serie.seriesId): \(remote.seasons.count) declared seasons, \(episodesBySeason.count) episode-keyed seasons, \(totalEpisodes) total episodes")

            // Many Xtream providers omit/empty the `seasons` array while still
            // returning a populated `episodes` dict. Fall back to synthesizing
            // seasons from the episode dict keys so we don't drop everything.
            let resolvedSeasons: [SerieDetail.Season] = !remote.seasons.isEmpty
                ? remote.seasons
                : episodesBySeason.keys.sorted().map { num in
                    SerieDetail.Season(
                        airDate: nil,
                        episodeCount: episodesBySeason[num]?.count,
                        id: nil,
                        name: nil,
                        overview: nil,
                        seasonNumber: num,
                        cover: nil,
                        coverBig: nil
                    )
                }

            for oldSeason in serie.seasons {
                context.delete(oldSeason)
            }

            for remoteSeason in resolvedSeasons {
                let season = SeasonEntity(
                    seasonNumber: remoteSeason.seasonNumber ?? 0,
                    name: remoteSeason.name ?? "",
                    overview: remoteSeason.overview ?? "",
                    airDate: remoteSeason.airDate ?? "",
                    episodeCount: remoteSeason.episodeCount ?? 0,
                    cover: remoteSeason.cover?.absoluteString ?? "",
                    serie: serie
                )
                context.insert(season)
                serie.seasons.append(season)

                if let remoteEpisodes = episodesBySeason[season.seasonNumber] {
                    for remoteEpisode in remoteEpisodes {
                        let episode = EpisodeEntity(
                            episodeId: remoteEpisode.id ?? "",
                            episodeNum: remoteEpisode.episodeNum ?? 0,
                            title: remoteEpisode.title ?? "",
                            containerExtension: remoteEpisode.containerExtension ?? "mp4",
                            plot: remoteEpisode.info.plot ?? "",
                            releaseDate: remoteEpisode.info.releaseDate ?? "",
                            movieImage: remoteEpisode.info.movieImage ?? "",
                            season: season
                        )
                        context.insert(episode)
                        season.episodes.append(episode)
                    }
                }
            }
            serie.detailFetchedAt = .now
            // Persist off the critical path — same reasoning as
            // MovieDetailViewModel: the UI already sees the new tree via
            // SwiftData's in-context inserts; this save just flushes to disk
            // and would otherwise block the detail view's first render with
            // a multi-hundred-row journal on a freshly-loaded serie.
            DeferredSave.schedule(context)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

}
