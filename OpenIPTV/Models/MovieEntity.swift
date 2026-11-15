import Foundation
import SwiftData

@Model
final class MovieEntity {
    var streamId: Int
    var num: Int
    var name: String
    var streamType: String
    var streamIcon: String
    var rating5Based: Float
    var added: String
    var isAdult: Bool
    var categoryId: String
    var containerExtension: String
    var customSid: String?
    var directSource: String
    var lastSeenAt: Date

    var profile: Profile?
    var category: CategoryEntity?
    @Relationship(deleteRule: .cascade, inverse: \MovieDetailEntity.movie) var detail: MovieDetailEntity?

    var streamIconURL: URL? { streamIcon.secureURL }

    init(
        streamId: Int,
        num: Int,
        name: String,
        streamType: String,
        streamIcon: String,
        rating5Based: Float,
        added: String,
        isAdult: Bool,
        categoryId: String,
        containerExtension: String,
        customSid: String?,
        directSource: String,
        lastSeenAt: Date = .now,
        category: CategoryEntity? = nil,
        profile: Profile? = nil
    ) {
        self.streamId = streamId
        self.num = num
        self.name = name
        self.streamType = streamType
        self.streamIcon = streamIcon
        self.rating5Based = rating5Based
        self.added = added
        self.isAdult = isAdult
        self.categoryId = categoryId
        self.containerExtension = containerExtension
        self.customSid = customSid
        self.directSource = directSource
        self.lastSeenAt = lastSeenAt
        self.category = category
        self.profile = profile
    }
}

@Model
final class MovieDetailEntity {
    @Attribute(.unique) var streamId: Int
    var plot: String
    var genre: String
    var cast: String
    var director: String
    var releaseDate: String
    var duration: String
    var durationSecs: Int
    var rating: String
    var backdrop: String
    var youtubeTrailer: String
    var fetchedAt: Date

    var movie: MovieEntity?

    init(
        streamId: Int,
        plot: String,
        genre: String,
        cast: String,
        director: String,
        releaseDate: String,
        duration: String,
        durationSecs: Int,
        rating: String,
        backdrop: String,
        youtubeTrailer: String,
        fetchedAt: Date = .now,
        movie: MovieEntity? = nil
    ) {
        self.streamId = streamId
        self.plot = plot
        self.genre = genre
        self.cast = cast
        self.director = director
        self.releaseDate = releaseDate
        self.duration = duration
        self.durationSecs = durationSecs
        self.rating = rating
        self.backdrop = backdrop
        self.youtubeTrailer = youtubeTrailer
        self.fetchedAt = fetchedAt
        self.movie = movie
    }
}

extension MovieEntity {
    /// Movies in one category for one profile, optionally excluding adult
    /// titles. Evaluated in SQLite so browse views never load another
    /// profile's rows (category ids are only unique per provider).
    static func categoryPredicate(categoryId: String, profileId: String, hideAdult: Bool) -> Predicate<MovieEntity> {
        let includeAdult = !hideAdult
        return #Predicate<MovieEntity> { movie in
            movie.categoryId == categoryId
                && movie.profile?.id == profileId
                && (includeAdult || !movie.isAdult)
        }
    }
}
