import Foundation
import SwiftData
import TVServices

/// Writes the active profile's Continue Watching items to the App Group
/// snapshot the Top Shelf extension reads, and tells tvOS to reload it.
/// Called after playback ends and when the active profile changes.
@MainActor
enum TopShelfPublisher {
    private static let maxItems = 10

    static func publish(profileId: String, in context: ModelContext) {
        guard TopShelfShared.snapshotURL != nil, !profileId.isEmpty else { return }

        var descriptor = FetchDescriptor<PlaybackProgress>(
            predicate: #Predicate { $0.profile?.id == profileId },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 40
        let rows = ((try? context.fetch(descriptor)) ?? []).filter { !$0.isFinished }

        var items: [TopShelfSnapshot.Item] = []
        var seenSeries = Set<Int>()
        for row in rows where items.count < maxItems {
            if let item = makeItem(for: row, profileId: profileId, seenSeries: &seenSeries, in: context) {
                items.append(item)
            }
        }

        if TopShelfSnapshot(items: items).save() {
            TVTopShelfContentProvider.topShelfContentDidChange()
        }
    }

    private static func makeItem(
        for row: PlaybackProgress,
        profileId: String,
        seenSeries: inout Set<Int>,
        in context: ModelContext
    ) -> TopShelfSnapshot.Item? {
        if let streamId = row.movieStreamId {
            var d = FetchDescriptor<MovieEntity>(
                predicate: #Predicate { $0.streamId == streamId && $0.profile?.id == profileId }
            )
            d.fetchLimit = 1
            guard let movie = try? context.fetch(d).first else { return nil }
            // Never surface adult titles on the Home screen when they're hidden in-app.
            if movie.isAdult && (movie.profile?.hideAdultContent ?? true) { return nil }
            let target = TopShelfLink.Target.movie(streamId: streamId)
            return TopShelfSnapshot.Item(
                id: row.id,
                kind: .movie,
                title: movie.name,
                subtitle: nil,
                imageURL: movie.streamIconURL,
                progress: row.fraction,
                displayURL: TopShelfLink(profileId: profileId, target: target, play: false).url,
                playURL: TopShelfLink(profileId: profileId, target: target, play: true).url
            )
        }

        guard let seriesId = row.seriesId, let episodeId = row.episodeId,
              !seenSeries.contains(seriesId)
        else { return nil }
        var d = FetchDescriptor<SerieEntity>(
            predicate: #Predicate { $0.seriesId == seriesId && $0.profile?.id == profileId }
        )
        d.fetchLimit = 1
        guard let serie = try? context.fetch(d).first else { return nil }
        // One tile per series: the most recently watched episode.
        seenSeries.insert(seriesId)
        let target = TopShelfLink.Target.episode(seriesId: seriesId, episodeId: episodeId)
        let label: String? = {
            guard let season = row.seasonNumber, let number = row.episodeNumber else { return nil }
            return "S\(season) E\(number)"
        }()
        return TopShelfSnapshot.Item(
            id: row.id,
            kind: .episode,
            title: serie.name,
            subtitle: label,
            imageURL: serie.coverURL,
            progress: row.fraction,
            displayURL: TopShelfLink(profileId: profileId, target: target, play: false).url,
            playURL: TopShelfLink(profileId: profileId, target: target, play: true).url
        )
    }
}
