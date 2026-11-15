import Foundation
import SwiftData

extension SerieEntity {
    /// Every loaded episode in viewing order: seasons ascending, then episode
    /// number ascending.
    var orderedEpisodes: [EpisodeEntity] {
        seasons
            .sorted { $0.seasonNumber < $1.seasonNumber }
            .flatMap { season in season.episodes.sorted { $0.episodeNum < $1.episodeNum } }
    }

    /// The episode that follows `episodeId`, crossing into the next season
    /// when needed. Nil for the last loaded episode.
    func episode(after episodeId: String) -> EpisodeEntity? {
        let ordered = orderedEpisodes
        guard let index = ordered.firstIndex(where: { $0.episodeId == episodeId }),
              ordered.indices.contains(index + 1)
        else { return nil }
        return ordered[index + 1]
    }
}

/// Builds episode playback requests (resume key, Info-panel metadata and the
/// Up Next chain) so the series page and the Continue Watching rail behave the
/// same.
@MainActor
enum EpisodePlayback {
    static func streamURL(for episode: EpisodeEntity, repository: any IPTVRepository) -> URL? {
        guard !episode.episodeId.isEmpty else { return nil }
        let ext = episode.containerExtension.isEmpty ? "mp4" : episode.containerExtension
        return repository.episodeStreamURL(episodeId: episode.episodeId, containerExtension: ext)
    }

    /// Resolves the episode's stream (redirect probe) and builds the request.
    static func resolve(
        episode: EpisodeEntity,
        serie: SerieEntity,
        profileId: String,
        repository: any IPTVRepository,
        fromBeginning: Bool = false
    ) async -> ResolvedPlayback? {
        guard let raw = streamURL(for: episode, repository: repository) else { return nil }
        let resolved = await StreamURLResolver.shared.resolve(raw)
        return make(
            url: resolved,
            episode: episode,
            serie: serie,
            profileId: profileId,
            repository: repository,
            fromBeginning: fromBeginning
        )
    }

    static func make(
        url: URL,
        episode: EpisodeEntity,
        serie: SerieEntity,
        profileId: String,
        repository: any IPTVRepository,
        fromBeginning: Bool
    ) -> ResolvedPlayback {
        let season = episode.season?.seasonNumber ?? 0
        var playback = ResolvedPlayback(
            url: url,
            title: title(for: episode, in: serie),
            progressKey: .episode(
                profileId: profileId,
                seriesId: serie.seriesId,
                episodeId: episode.episodeId,
                season: season,
                number: episode.episodeNum
            ),
            startFromBeginning: fromBeginning,
            metadata: PlaybackMetadata(
                title: title(for: episode, in: serie),
                subtitle: label(for: episode, in: serie),
                description: episode.plot.isEmpty ? serie.plot : episode.plot,
                artworkURL: episode.movieImage.secureURL ?? serie.coverURL
            )
        )
        if let next = serie.episode(after: episode.episodeId) {
            playback.upNext = UpNext(
                title: title(for: next, in: serie),
                subtitle: label(for: next, in: serie),
                artworkURL: next.movieImage.secureURL ?? serie.coverURL,
                resolve: {
                    await resolve(
                        episode: next,
                        serie: serie,
                        profileId: profileId,
                        repository: repository
                    )
                }
            )
        }
        return playback
    }

    static func title(for episode: EpisodeEntity, in serie: SerieEntity) -> String {
        episode.title.isEmpty ? serie.name : episode.title
    }

    /// "Series Name · S2 E5"
    static func label(for episode: EpisodeEntity, in serie: SerieEntity) -> String {
        let season = episode.season?.seasonNumber ?? 0
        return "\(serie.name) · S\(season) E\(episode.episodeNum)"
    }
}
