import Foundation
import OSLog

struct Serie: Codable, Hashable {
    var num: Int
    var name: String
    var seriesId: Int
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
    var categoryId: String?
    
    enum CodingKeys: String, CodingKey {
        case num
        case name
        case seriesId = "series_id"
        case cover
        case plot
        case cast
        case director
        case genre
        case releaseDate
        case lastModified = "last_modified"
        case rating
        case rating5Based = "rating_5based"
        case youtubeTrailer = "youtube_trailer"
        case episodeRuntime = "episode_run_time"
        case categoryId = "category_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        num = c.flexibleInt(.num)
        name = c.flexibleString(.name)
        seriesId = c.flexibleInt(.seriesId)
        cover = c.flexibleString(.cover)
        plot = c.flexibleString(.plot)
        cast = c.flexibleString(.cast)
        director = c.flexibleString(.director)
        genre = c.flexibleString(.genre)
        releaseDate = c.flexibleStringOptional(.releaseDate)
        lastModified = c.flexibleStringOptional(.lastModified)
        rating = c.flexibleString(.rating)
        rating5Based = c.flexibleFloat(.rating5Based)
        youtubeTrailer = c.flexibleString(.youtubeTrailer)
        episodeRuntime = c.flexibleString(.episodeRuntime)
        categoryId = c.flexibleStringOptional(.categoryId)
    }

    var coverURL: URL? {
        URL(string: cover)
    }

    var releaseDateFormatted: String {
        guard let raw = releaseDate,
              let date = Serie.releaseDateFormatter.date(from: raw) else {
            return "Unknown"
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private static let releaseDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

extension Serie: Identifiable {
    public var id: String { num.description }
}

struct SerieDetail: Codable {
    let seasons: [Season]
    let info: Info
    let episodes: [String: [Episode]]

    enum CodingKeys: String, CodingKey {
        case seasons
        case info
        case episodes
    }

    private static let logger = Logger(subsystem: "com.openiptv.app", category: "SerieDetail")

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seasons = (try? container.decode([Season].self, forKey: .seasons)) ?? []
        info = try container.decode(Info.self, forKey: .info)

        // Decode episodes tolerantly: wrap each Episode so a single quirky
        // record (e.g., episode_num as a string instead of int) doesn't drop
        // the entire dict. Without this, `try? container.decode([String:
        // [Episode]])` silently returns [:] on the first decode failure.
        var decoded: [String: [Episode]] = [:]
        if let raw = try? container.decode([String: [FailableEpisode]].self, forKey: .episodes) {
            for (seasonKey, wrapped) in raw {
                let good = wrapped.compactMap(\.episode)
                if good.count != wrapped.count {
                    Self.logger.warning("Season \(seasonKey): dropped \(wrapped.count - good.count) of \(wrapped.count) episodes due to decode errors")
                }
                decoded[seasonKey] = good
            }
        } else {
            Self.logger.warning("episodes container failed to decode entirely")
        }
        self.episodes = decoded
    }

    /// Wrapper that lets a single bad episode fail without taking down its
    /// season's array.
    private struct FailableEpisode: Decodable {
        let episode: Episode?
        init(from decoder: Decoder) throws {
            do {
                episode = try Episode(from: decoder)
            } catch {
                SerieDetail.logger.warning("Episode decode failed: \(error.localizedDescription)")
                episode = nil
            }
        }
    }

    struct Season: Codable {
        let airDate: String?
        let episodeCount: Int?
        let id: Int?
        let name: String?
        let overview: String?
        let seasonNumber: Int?
        let cover: URL?
        let coverBig: URL?

        enum CodingKeys: String, CodingKey {
            case airDate = "air_date"
            case episodeCount = "episode_count"
            case id
            case name
            case overview
            case seasonNumber = "season_number"
            case cover
            case coverBig = "cover_big"
        }

        init(
            airDate: String?,
            episodeCount: Int?,
            id: Int?,
            name: String?,
            overview: String?,
            seasonNumber: Int?,
            cover: URL?,
            coverBig: URL?
        ) {
            self.airDate = airDate
            self.episodeCount = episodeCount
            self.id = id
            self.name = name
            self.overview = overview
            self.seasonNumber = seasonNumber
            self.cover = cover
            self.coverBig = coverBig
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            airDate = try? c.decode(String.self, forKey: .airDate)
            episodeCount = Self.flexibleInt(c, .episodeCount)
            id = Self.flexibleInt(c, .id)
            name = try? c.decode(String.self, forKey: .name)
            overview = try? c.decode(String.self, forKey: .overview)
            seasonNumber = Self.flexibleInt(c, .seasonNumber)
            cover = try? c.decode(URL.self, forKey: .cover)
            coverBig = try? c.decode(URL.self, forKey: .coverBig)
        }

        private static func flexibleInt(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
            if let i = try? c.decode(Int.self, forKey: key) { return i }
            if let s = try? c.decode(String.self, forKey: key), let i = Int(s) { return i }
            return nil
        }
    }
    
    struct Info: Codable {
        let name: String
        let cover: URL?
        let plot: String?
        let cast: String?
        let director: String?
        let genre: String?
        let releaseDate: String?
        let lastModified: String?
        let rating5based: Float?
        let backdropPath: [URL]?
        let youtubeTrailer: String?
        let episodeRunTime: String?
        let categoryId: String?
        
        enum CodingKeys: String, CodingKey {
            case name
            case cover
            case plot
            case cast
            case director
            case genre
            case releaseDate = "releaseDate"
            case lastModified = "last_modified"
            case rating5based = "rating_5based"
            case backdropPath = "backdrop_path"
            case youtubeTrailer = "youtube_trailer"
            case episodeRunTime = "episode_run_time"
            case categoryId = "category_id"
        }

        // Tolerant decode: panels vary — `rating_5based` arrives as a String on
        // some servers (observed: "unexpected type for rating_5based"), and any
        // field may be missing. Coerce via the shared flexible accessors so a
        // single variant field doesn't fail the whole `get_series_info` decode
        // (which would drop the series' seasons and episodes).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = c.flexibleString(.name)
            cover = try? c.decode(URL.self, forKey: .cover)
            plot = c.flexibleStringOptional(.plot)
            cast = c.flexibleStringOptional(.cast)
            director = c.flexibleStringOptional(.director)
            genre = c.flexibleStringOptional(.genre)
            releaseDate = c.flexibleStringOptional(.releaseDate)
            lastModified = c.flexibleStringOptional(.lastModified)
            rating5based = c.flexibleFloat(.rating5based)
            backdropPath = try? c.decode([URL].self, forKey: .backdropPath)
            youtubeTrailer = c.flexibleStringOptional(.youtubeTrailer)
            episodeRunTime = c.flexibleStringOptional(.episodeRunTime)
            categoryId = c.flexibleStringOptional(.categoryId)
        }
    }
    
    struct Episode: Codable {
        let id: String?
        let episodeNum: Int?
        let title: String?
        let containerExtension: String?
        let info: EpisodeInfo
        let customSid: String?
        let added: String?
        let season: Int?
        let directSource: String?

        enum CodingKeys: String, CodingKey {
            case id
            case episodeNum = "episode_num"
            case title
            case containerExtension = "container_extension"
            case info
            case customSid = "custom_sid"
            case added
            case season
            case directSource = "direct_source"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // `id` arrives as Int from some providers, String from others.
            id = Self.flexibleString(c, .id)
            // `episode_num` and `season` are notoriously inconsistent — quoted
            // strings in many panels. Coerce both to Int.
            episodeNum = Self.flexibleInt(c, .episodeNum)
            season = Self.flexibleInt(c, .season)
            title = try? c.decode(String.self, forKey: .title)
            containerExtension = try? c.decode(String.self, forKey: .containerExtension)
            info = (try? c.decode(EpisodeInfo.self, forKey: .info))
                ?? EpisodeInfo(movieImage: nil, plot: nil, releaseDate: nil)
            customSid = try? c.decode(String.self, forKey: .customSid)
            added = try? c.decode(String.self, forKey: .added)
            directSource = try? c.decode(String.self, forKey: .directSource)
        }

        private static func flexibleInt(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
            if let i = try? c.decode(Int.self, forKey: key) { return i }
            if let s = try? c.decode(String.self, forKey: key), let i = Int(s) { return i }
            return nil
        }

        private static func flexibleString(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
            if let s = try? c.decode(String.self, forKey: key) { return s }
            if let i = try? c.decode(Int.self, forKey: key) { return String(i) }
            return nil
        }
    }
    
    struct EpisodeInfo: Codable {
        let movieImage: String?
        let plot: String?
        let releaseDate: String?

        enum CodingKeys: String, CodingKey {
            case movieImage = "movie_image"
            case plot
            case releaseDate = "releasedate"
        }
    }
}
