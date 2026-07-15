import Foundation
import SwiftData
import OSLog

private let logger = Logger(subsystem: "com.openiptv.app", category: "PlaylistSync")

@ModelActor
actor PlaylistSyncService {
    enum Trigger: Sendable {
        case cold
        case manual
        case stale
    }

    /// How much of the catalog to sync. `.liveOnly` refreshes just Live TV
    /// channels (used by the Live tab's manual "Refresh"); `.full` syncs the
    /// whole catalog (Movies + Series + Live) and is used for the initial load
    /// and full library refreshes.
    enum Scope: Sendable {
        case liveOnly
        case full
    }

    enum Result: Sendable {
        case upToDate
        case synced(SyncStats)
        case failed(String)
    }

    private static var chunkSize: Int {
        if #available(tvOS 26.0, *) {
            return 500
        } else {
            return 250
        }
    }

    func refreshIfNeeded(
        trigger: Trigger,
        scope: Scope,
        profileId: String,
        repository: any IPTVRepository,
        progress: @Sendable (SyncProgress) -> Void = { _ in }
    ) async -> Result {
        switch trigger {
        case .manual, .cold:
            return await refresh(scope: scope, profileId: profileId, repository: repository, progress: progress)
        case .stale:
            guard isStale(profileId: profileId) else { return .upToDate }
            return await refresh(scope: scope, profileId: profileId, repository: repository, progress: progress)
        }
    }

    private func isStale(profileId: String) -> Bool {
        let descriptor = FetchDescriptor<Profile>(predicate: #Predicate { $0.id == profileId })
        guard let profile = try? modelContext.fetch(descriptor).first else { return true }
        return profile.isSyncStale
    }

    private func loadProfile(_ profileId: String) -> Profile? {
        let descriptor = FetchDescriptor<Profile>(predicate: #Predicate { $0.id == profileId })
        return try? modelContext.fetch(descriptor).first
    }

    private func refresh(
        scope: Scope,
        profileId: String,
        repository: any IPTVRepository,
        progress: @Sendable (SyncProgress) -> Void
    ) async -> Result {
        var stats = SyncStats()
        progress(.fetching)

        guard let profile = loadProfile(profileId) else {
            let message = "Profile not found: \(profileId)"
            logger.error("\(message, privacy: .public)")
            progress(.failed(message))
            return .failed(message)
        }

        do {
            let syncStart = stats.startedAt

            // Sync one content type at a time, each in its own scope so its
            // (potentially huge) decoded array and raw response Data are released
            // before the next type is fetched. Holding Live + Movies + Series in
            // memory concurrently — which the previous `async let` fan-out did —
            // spiked the footprint past the tvOS memory ceiling and got the app
            // jetsam-killed on very large playlists. The cost is that the big
            // fetches no longer overlap on the wire (a slower full sync), but
            // Live still lands first so perceived startup is unchanged.
            //
            // Live is always synced — it's the free, primary tab. Free users
            // skip Movies/Series entirely.
            try await syncType(.live, repository: repository, profile: profile, stats: &stats, syncStart: syncStart, progress: progress)

            if scope == .full {
                try await syncType(.movie, repository: repository, profile: profile, stats: &stats, syncStart: syncStart, progress: progress)
                try await syncType(.serie, repository: repository, profile: profile, stats: &stats, syncStart: syncStart, progress: progress)
            }

            progress(.pruning)
            stats.pruned = try pruneOrphans(before: syncStart, profileId: profileId, scope: scope)
            profile.lastSyncedAt = syncStart
            try modelContext.save()

            stats.finishedAt = .now
            logger.info("Sync finished for \(profileId, privacy: .public): \(stats.totalMovies) movies, \(stats.totalSeries) series, \(stats.totalLives) lives, pruned \(stats.pruned)")
            progress(.done(stats))
            return .synced(stats)
        } catch {
            logger.error("Sync failed: \(error.localizedDescription, privacy: .public)")
            progress(.failed(error.localizedDescription))
            return .failed(error.localizedDescription)
        }
    }

    /// Fetches the categories + content for a single kind and persists them,
    /// all within this function's scope. Returning here releases the decoded
    /// arrays (and their transient response `Data`) before the caller moves to
    /// the next kind — the memory discipline that keeps a large full sync under
    /// the tvOS ceiling. Categories fetch concurrently with their content since
    /// the category payloads are small.
    private func syncType(
        _ kind: ContentKind,
        repository: any IPTVRepository,
        profile: Profile,
        stats: inout SyncStats,
        syncStart: Date,
        progress: @Sendable (SyncProgress) -> Void
    ) async throws {
        let profileId = profile.id
        switch kind {
        case .live:
            async let catsTask = repository.fetchLiveCategories()
            async let itemsTask = repository.fetchLive()
            let (cats, items) = try await (catsTask, itemsTask)
            try upsertCategories(cats, kind: .live, profileId: profileId, stats: &stats, syncStart: syncStart)
            try await upsertLives(items, profileId: profileId, stats: &stats, syncStart: syncStart, progress: progress)
        case .movie:
            async let catsTask = repository.fetchMovieCategories()
            async let itemsTask = repository.fetchMovies()
            let (cats, items) = try await (catsTask, itemsTask)
            try upsertCategories(cats, kind: .movie, profileId: profileId, stats: &stats, syncStart: syncStart)
            try await upsertMovies(items, profileId: profileId, stats: &stats, syncStart: syncStart, progress: progress)
        case .serie:
            async let catsTask = repository.fetchSeriesCategories()
            async let itemsTask = repository.fetchSeries()
            let (cats, items) = try await (catsTask, itemsTask)
            try upsertCategories(cats, kind: .serie, profileId: profileId, stats: &stats, syncStart: syncStart)
            try await upsertSeries(items, profileId: profileId, stats: &stats, syncStart: syncStart, progress: progress)
        }
    }

    /// Fetches the `Profile` in the given context. Bulk upserts run in their own
    /// short-lived contexts (see below), so each must resolve the profile by id
    /// there rather than share the actor's context object.
    private func fetchProfile(_ context: ModelContext, id: String) -> Profile? {
        (try? context.fetch(FetchDescriptor<Profile>(predicate: #Predicate { $0.id == id })))?.first
    }

    // MARK: - Upserts

    private func upsertCategories(
        _ categories: [Category],
        kind: ContentKind,
        profileId: String,
        stats: inout SyncStats,
        syncStart: Date
    ) throws {
        // Categories are a small set (genres/groups — hundreds, not tens of
        // thousands), so a single dedicated context for all of them is fine.
        let context = ModelContext(modelContainer)
        guard let profile = fetchProfile(context, id: profileId) else { return }
        for (index, cat) in categories.enumerated() {
            let composite = CategoryEntity.compositeId(kind: kind, categoryId: cat.categoryId)
            let descriptor = FetchDescriptor<CategoryEntity>(
                predicate: #Predicate { $0.compositeId == composite && $0.profile?.id == profileId }
            )
            if let existing = try context.fetch(descriptor).first {
                existing.name = cat.categoryName
                existing.sortOrder = index
                existing.lastSeenAt = syncStart
                stats.categoriesUpdated += 1
            } else {
                let entity = CategoryEntity(
                    categoryId: cat.categoryId,
                    name: cat.categoryName,
                    kind: kind,
                    sortOrder: index,
                    lastSeenAt: syncStart,
                    profile: profile
                )
                context.insert(entity)
                stats.categoriesInserted += 1
            }
        }
        try context.save()
    }

    private func upsertMovies(
        _ movies: [Movie],
        profileId: String,
        stats: inout SyncStats,
        syncStart: Date,
        progress: @Sendable (SyncProgress) -> Void
    ) async throws {
        let total = movies.count
        for chunk in movies.chunked(into: Self.chunkSize) {
            let result = try upsertMovieBatch(chunk, profileId: profileId, syncStart: syncStart)
            stats.moviesInserted += result.inserted
            stats.moviesUpdated += result.updated
            progress(.writing(kind: .movie, completed: stats.totalMovies, total: total))
            await Task.yield()
        }
    }

    /// Upserts one chunk in its own short-lived `ModelContext` (deallocated on
    /// return, so peak memory is bounded to ~500 rows) and deliberately does NOT
    /// touch the `category` relationship — only the `categoryId` scalar is stored.
    ///
    /// This is the crux of the large-catalog OOM fix. Assigning `movie.category`
    /// maintains the `CategoryEntity.movies` to-many inverse, which forces
    /// SwiftData to fault the entire (and growing) category array on every
    /// insert. With a per-batch context that array was re-faulted each batch —
    /// O(n²), 2 GB on a 151k-movie catalog; with a per-category context a single
    /// oversized category blew one context. Not maintaining the inverse at all
    /// sidesteps both: browse reads content via `@Query` filtered by `categoryId`
    /// (never the relationship), so the link is unnecessary at sync time.
    private func upsertMovieBatch(
        _ chunk: [Movie],
        profileId: String,
        syncStart: Date
    ) throws -> (inserted: Int, updated: Int) {
        let context = ModelContext(modelContainer)
        guard let profile = fetchProfile(context, id: profileId) else { return (0, 0) }

        let ids = chunk.map(\.streamId)
        var byStreamId: [Int: MovieEntity] = [:]
        for entity in try context.fetch(FetchDescriptor<MovieEntity>(
            predicate: #Predicate { ids.contains($0.streamId) && $0.profile?.id == profileId }
        )) {
            byStreamId[entity.streamId] = entity
        }

        var inserted = 0, updated = 0
        for movie in chunk {
            if let existing = byStreamId[movie.streamId] {
                existing.num = movie.num
                existing.name = movie.name
                existing.streamType = movie.streamType
                existing.streamIcon = movie.streamIcon
                existing.rating5Based = movie.rating5Based
                existing.added = movie.added
                existing.isAdult = movie.isAdult
                existing.categoryId = movie.categoryId
                existing.containerExtension = movie.containerExtension
                existing.customSid = movie.customSid
                existing.directSource = movie.directSource
                existing.lastSeenAt = syncStart
                updated += 1
            } else {
                let entity = MovieEntity(
                    streamId: movie.streamId,
                    num: movie.num,
                    name: movie.name,
                    streamType: movie.streamType,
                    streamIcon: movie.streamIcon,
                    rating5Based: movie.rating5Based,
                    added: movie.added,
                    isAdult: movie.isAdult,
                    categoryId: movie.categoryId,
                    containerExtension: movie.containerExtension,
                    customSid: movie.customSid,
                    directSource: movie.directSource,
                    lastSeenAt: syncStart,
                    category: nil,
                    profile: profile
                )
                context.insert(entity)
                byStreamId[movie.streamId] = entity  // catch in-chunk duplicate ids
                inserted += 1
            }
        }
        try context.save()
        return (inserted, updated)
    }

    private func upsertSeries(
        _ series: [Serie],
        profileId: String,
        stats: inout SyncStats,
        syncStart: Date,
        progress: @Sendable (SyncProgress) -> Void
    ) async throws {
        let total = series.count
        for chunk in series.chunked(into: Self.chunkSize) {
            let result = try upsertSeriesBatch(chunk, profileId: profileId, syncStart: syncStart)
            stats.seriesInserted += result.inserted
            stats.seriesUpdated += result.updated
            progress(.writing(kind: .serie, completed: stats.totalSeries, total: total))
            await Task.yield()
        }
    }

    /// One chunk of series in its own short-lived context, without touching the
    /// `category` relationship — see `upsertMovieBatch`.
    private func upsertSeriesBatch(
        _ chunk: [Serie],
        profileId: String,
        syncStart: Date
    ) throws -> (inserted: Int, updated: Int) {
        let context = ModelContext(modelContainer)
        guard let profile = fetchProfile(context, id: profileId) else { return (0, 0) }

        let ids = chunk.map(\.seriesId)
        var bySeriesId: [Int: SerieEntity] = [:]
        for entity in try context.fetch(FetchDescriptor<SerieEntity>(
            predicate: #Predicate { ids.contains($0.seriesId) && $0.profile?.id == profileId }
        )) {
            bySeriesId[entity.seriesId] = entity
        }

        var inserted = 0, updated = 0
        for serie in chunk {
            let categoryId = serie.categoryId ?? ""
            if let existing = bySeriesId[serie.seriesId] {
                existing.num = serie.num
                existing.name = serie.name
                existing.cover = serie.cover
                existing.plot = serie.plot
                existing.cast = serie.cast
                existing.director = serie.director
                existing.genre = serie.genre
                existing.releaseDate = serie.releaseDate
                existing.lastModified = serie.lastModified
                existing.rating = serie.rating
                existing.rating5Based = serie.rating5Based
                existing.youtubeTrailer = serie.youtubeTrailer
                existing.episodeRuntime = serie.episodeRuntime
                existing.categoryId = categoryId
                existing.lastSeenAt = syncStart
                updated += 1
            } else {
                let entity = SerieEntity(
                    seriesId: serie.seriesId,
                    num: serie.num,
                    name: serie.name,
                    cover: serie.cover,
                    plot: serie.plot,
                    cast: serie.cast,
                    director: serie.director,
                    genre: serie.genre,
                    releaseDate: serie.releaseDate,
                    lastModified: serie.lastModified,
                    rating: serie.rating,
                    rating5Based: serie.rating5Based,
                    youtubeTrailer: serie.youtubeTrailer,
                    episodeRuntime: serie.episodeRuntime,
                    categoryId: categoryId,
                    lastSeenAt: syncStart,
                    category: nil,
                    profile: profile
                )
                context.insert(entity)
                bySeriesId[serie.seriesId] = entity  // catch in-chunk duplicate ids
                inserted += 1
            }
        }
        try context.save()
        return (inserted, updated)
    }

    private func upsertLives(
        _ lives: [Live],
        profileId: String,
        stats: inout SyncStats,
        syncStart: Date,
        progress: @Sendable (SyncProgress) -> Void
    ) async throws {
        let total = lives.count
        for chunk in lives.chunked(into: Self.chunkSize) {
            let result = try upsertLiveBatch(chunk, profileId: profileId, syncStart: syncStart)
            stats.livesInserted += result.inserted
            stats.livesUpdated += result.updated
            progress(.writing(kind: .live, completed: stats.totalLives, total: total))
            await Task.yield()
        }
    }

    /// One chunk of live channels in its own short-lived context, without
    /// touching the `category` relationship — see `upsertMovieBatch`.
    private func upsertLiveBatch(
        _ chunk: [Live],
        profileId: String,
        syncStart: Date
    ) throws -> (inserted: Int, updated: Int) {
        let context = ModelContext(modelContainer)
        guard let profile = fetchProfile(context, id: profileId) else { return (0, 0) }

        let ids = chunk.map(\.streamId)
        var byStreamId: [Int: LiveEntity] = [:]
        for entity in try context.fetch(FetchDescriptor<LiveEntity>(
            predicate: #Predicate { ids.contains($0.streamId) && $0.profile?.id == profileId }
        )) {
            byStreamId[entity.streamId] = entity
        }

        var inserted = 0, updated = 0
        for live in chunk {
            let categoryId = live.categoryId ?? ""
            if let existing = byStreamId[live.streamId] {
                existing.num = live.num
                existing.name = live.name
                existing.streamType = live.streamType
                existing.streamIcon = live.streamIcon
                existing.epgChannelId = live.epgChannelId
                existing.added = live.added
                existing.adult = live.adult
                existing.categoryId = categoryId
                existing.customSid = live.customSid
                existing.tvArchive = live.tvArchive
                existing.directSource = live.directSource
                existing.lastSeenAt = syncStart
                updated += 1
            } else {
                let entity = LiveEntity(
                    streamId: live.streamId,
                    num: live.num,
                    name: live.name,
                    streamType: live.streamType,
                    streamIcon: live.streamIcon,
                    epgChannelId: live.epgChannelId,
                    added: live.added,
                    adult: live.adult,
                    categoryId: categoryId,
                    customSid: live.customSid,
                    tvArchive: live.tvArchive,
                    directSource: live.directSource,
                    lastSeenAt: syncStart,
                    category: nil,
                    profile: profile
                )
                context.insert(entity)
                byStreamId[live.streamId] = entity  // catch in-chunk duplicate ids
                inserted += 1
            }
        }
        try context.save()
        return (inserted, updated)
    }

    // MARK: - Prune orphans

    /// Deletes rows belonging to `profileId` whose `lastSeenAt` is older than
    /// `cutoff`. Other profiles' rows are never touched.
    ///
    /// A `.liveOnly` sync only fetched Live, so it must prune only Live rows +
    /// Live categories — pruning Movies/Series/their categories here would
    /// delete a (previously-premium, now-downgraded) user's catalog just
    /// because it wasn't re-fetched this pass.
    private func pruneOrphans(before cutoff: Date, profileId: String, scope: Scope) throws -> Int {
        var removed = 0

        let liveDescriptor = FetchDescriptor<LiveEntity>(
            predicate: #Predicate {
                $0.lastSeenAt < cutoff && $0.profile?.id == profileId
            }
        )
        let orphanLives = try modelContext.fetch(liveDescriptor)
        removed += orphanLives.count
        for l in orphanLives { modelContext.delete(l) }

        if scope == .full {
            let movieDescriptor = FetchDescriptor<MovieEntity>(
                predicate: #Predicate {
                    $0.lastSeenAt < cutoff && $0.profile?.id == profileId
                }
            )
            let orphanMovies = try modelContext.fetch(movieDescriptor)
            removed += orphanMovies.count
            for m in orphanMovies { modelContext.delete(m) }

            let serieDescriptor = FetchDescriptor<SerieEntity>(
                predicate: #Predicate {
                    $0.lastSeenAt < cutoff && $0.profile?.id == profileId
                }
            )
            let orphanSeries = try modelContext.fetch(serieDescriptor)
            removed += orphanSeries.count
            for s in orphanSeries { modelContext.delete(s) }

            // Prune every stale category (all kinds).
            let catDescriptor = FetchDescriptor<CategoryEntity>(
                predicate: #Predicate {
                    $0.lastSeenAt < cutoff && $0.profile?.id == profileId
                }
            )
            let orphanCats = try modelContext.fetch(catDescriptor)
            removed += orphanCats.count
            for c in orphanCats { modelContext.delete(c) }
        } else {
            // Live-only: prune stale Live categories, but leave Movie/Serie
            // categories (they weren't re-seen this pass).
            let liveKind = ContentKind.live.rawValue
            let catDescriptor = FetchDescriptor<CategoryEntity>(
                predicate: #Predicate {
                    $0.lastSeenAt < cutoff && $0.profile?.id == profileId && $0.kindRaw == liveKind
                }
            )
            let orphanCats = try modelContext.fetch(catDescriptor)
            removed += orphanCats.count
            for c in orphanCats { modelContext.delete(c) }
        }

        try modelContext.save()
        return removed
    }
}

// MARK: - Chunking helper

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
