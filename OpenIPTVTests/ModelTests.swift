import Foundation
import SwiftData
import Testing
@testable import OpenIPTV

/// Model logic that needs a (throwaway, in-memory) SwiftData container.
@MainActor
@Suite("Models")
struct ModelTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try ModelContainer(
            for: Schema(versionedSchema: SchemaV1.self),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func makeProfile(expiresAt: String = "") -> Profile {
        let profile = Profile(
            username: "user", password: "", status: "Active", maxConnections: "1",
            createdAt: "", expiresAt: expiresAt, serverURL: "example.com"
        )
        context.insert(profile)
        return profile
    }

    // MARK: Expiry

    @Test func unlimitedAccountsNeverExpire() {
        for raw in ["", "null", "0"] {
            let profile = makeProfile(expiresAt: raw)
            #expect(profile.expiryDate == nil)
            #expect(!profile.isExpiringSoon)
            #expect(ProfileExpiry.summary(for: profile) == "Never expires")
        }
    }

    @Test func expirySummaryAndWarning() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let inThreeDays = makeProfile(expiresAt: String(Int(now.timeIntervalSince1970) + 3 * 86_400 + 60))
        #expect(inThreeDays.daysUntilExpiry(from: now) == 3)
        #expect(ProfileExpiry.summary(for: inThreeDays, now: now) == "Expires in 3 days")

        let farAway = makeProfile(expiresAt: String(Int(Date.now.timeIntervalSince1970) + 60 * 86_400))
        #expect(!farAway.isExpiringSoon)

        let expired = makeProfile(expiresAt: String(Int(Date.now.timeIntervalSince1970) - 86_400))
        #expect(expired.isExpiringSoon)
    }

    // MARK: Favorites

    @Test func favoritesToggleAndKeepOrder() {
        let profile = makeProfile()
        #expect(!profile.isFavoriteLive(5))
        profile.toggleFavoriteLive(5)
        profile.toggleFavoriteLive(2)
        profile.toggleFavoriteLive(9)
        #expect(profile.favoriteLiveStreamIds == [5, 2, 9])
        profile.toggleFavoriteLive(2)
        #expect(profile.favoriteLiveStreamIds == [5, 9])
        #expect(profile.isFavoriteLive(9))
    }

    // MARK: Up Next ordering

    @Test func nextEpisodeCrossesSeasons() {
        let serie = SerieEntity(
            seriesId: 1, num: 1, name: "Show", cover: "", plot: "", cast: "", director: "",
            genre: "", releaseDate: nil, lastModified: nil, rating: "", rating5Based: 0,
            youtubeTrailer: "", episodeRuntime: "", categoryId: "c"
        )
        context.insert(serie)
        // Inserted out of order on purpose.
        for (seasonNumber, episodes) in [(2, [1]), (1, [2, 1])] {
            let season = SeasonEntity(
                seasonNumber: seasonNumber, name: "", overview: "", airDate: "",
                episodeCount: episodes.count, cover: "", serie: serie
            )
            context.insert(season)
            for number in episodes {
                let episode = EpisodeEntity(
                    episodeId: "s\(seasonNumber)e\(number)", episodeNum: number, title: "",
                    containerExtension: "mp4", plot: "", releaseDate: "", movieImage: "", season: season
                )
                context.insert(episode)
            }
        }
        try? context.save()

        #expect(serie.orderedEpisodes.map(\.episodeId) == ["s1e1", "s1e2", "s2e1"])
        #expect(serie.episode(after: "s1e1")?.episodeId == "s1e2")
        #expect(serie.episode(after: "s1e2")?.episodeId == "s2e1")
        #expect(serie.episode(after: "s2e1") == nil)
        #expect(serie.episode(after: "missing") == nil)
    }

    // MARK: Resume progress

    @Test func playbackFractionAndFinished() {
        let row = PlaybackProgress(
            id: "p|movie|1", profile: nil, mediaKindRaw: "movie", movieStreamId: 1,
            position: 960, duration: 1000, updatedAt: .now
        )
        context.insert(row)
        #expect(row.fraction == 0.96)
        #expect(row.isFinished)

        let unknown = PlaybackProgress(
            id: "p|movie|2", profile: nil, mediaKindRaw: "movie", movieStreamId: 2,
            position: 30, duration: 0, updatedAt: .now
        )
        context.insert(unknown)
        #expect(unknown.fraction == 0)
        #expect(!unknown.isFinished)
    }
}
