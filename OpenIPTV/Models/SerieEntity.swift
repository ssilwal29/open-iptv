import Foundation
import SwiftData

@Model
final class SerieEntity {
    var seriesId: Int
    var num: Int
    var name: String
    var cover: String
    var plot: String
    var cast: String
    var director: String
    var genre: String
    var releaseDate: String?
    var lastModified: String?
    var rating: String
    var rating5Based: Float
    var youtubeTrailer: String
    var episodeRuntime: String
    var categoryId: String
    var lastSeenAt: Date
    var detailFetchedAt: Date?

    var profile: Profile?
    var category: CategoryEntity?
    @Relationship(deleteRule: .cascade, inverse: \SeasonEntity.serie) var seasons: [SeasonEntity] = []

    var coverURL: URL? { cover.secureURL }

    init(
        seriesId: Int,
        num: Int,
        name: String,
        cover: String,
        plot: String,
        cast: String,
        director: String,
        genre: String,
        releaseDate: String?,
        lastModified: String?,
        rating: String,
        rating5Based: Float,
        youtubeTrailer: String,
        episodeRuntime: String,
        categoryId: String,
        lastSeenAt: Date = .now,
        category: CategoryEntity? = nil,
        profile: Profile? = nil
    ) {
        self.seriesId = seriesId
        self.num = num
        self.name = name
        self.cover = cover
        self.plot = plot
        self.cast = cast
        self.director = director
        self.genre = genre
        self.releaseDate = releaseDate
        self.lastModified = lastModified
        self.rating = rating
        self.rating5Based = rating5Based
        self.youtubeTrailer = youtubeTrailer
        self.episodeRuntime = episodeRuntime
        self.categoryId = categoryId
        self.lastSeenAt = lastSeenAt
        self.category = category
        self.profile = profile
    }
}

@Model
final class SeasonEntity {
    var seasonNumber: Int
    var name: String
    var overview: String
    var airDate: String
    var episodeCount: Int
    var cover: String

    var serie: SerieEntity?
    @Relationship(deleteRule: .cascade, inverse: \EpisodeEntity.season) var episodes: [EpisodeEntity] = []

    init(
        seasonNumber: Int,
        name: String,
        overview: String,
        airDate: String,
        episodeCount: Int,
        cover: String,
        serie: SerieEntity? = nil
    ) {
        self.seasonNumber = seasonNumber
        self.name = name
        self.overview = overview
        self.airDate = airDate
        self.episodeCount = episodeCount
        self.cover = cover
        self.serie = serie
    }
}

@Model
final class EpisodeEntity {
    var episodeId: String
    var episodeNum: Int
    var title: String
    var containerExtension: String
    var plot: String
    var releaseDate: String
    var movieImage: String

    var season: SeasonEntity?

    init(
        episodeId: String,
        episodeNum: Int,
        title: String,
        containerExtension: String,
        plot: String,
        releaseDate: String,
        movieImage: String,
        season: SeasonEntity? = nil
    ) {
        self.episodeId = episodeId
        self.episodeNum = episodeNum
        self.title = title
        self.containerExtension = containerExtension
        self.plot = plot
        self.releaseDate = releaseDate
        self.movieImage = movieImage
        self.season = season
    }
}
