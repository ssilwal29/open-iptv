import Foundation

// MARK: - Lenient decoding (Xtream type variance)

/// Xtream panels are wildly inconsistent: the same field arrives as `Int` on one
/// server and `String` on another (and is sometimes null or omitted). These
/// coercing accessors keep one variant field from failing the whole playlist
/// decode. `try?` swallows both wrong-type and missing-key, falling back to the
/// default.
extension KeyedDecodingContainer {
    func flexibleInt(_ key: Key, default def: Int = 0) -> Int {
        if let v = try? decode(Int.self, forKey: key) { return v }
        if let s = try? decode(String.self, forKey: key), let v = Int(s) { return v }
        if let d = try? decode(Double.self, forKey: key) { return Int(d) }
        return def
    }
    func flexibleString(_ key: Key, default def: String = "") -> String {
        if let v = try? decode(String.self, forKey: key) { return v }
        if let i = try? decode(Int.self, forKey: key) { return String(i) }
        if let d = try? decode(Double.self, forKey: key) { return String(d) }
        if let b = try? decode(Bool.self, forKey: key) { return b ? "1" : "0" }
        return def
    }
    func flexibleStringOptional(_ key: Key) -> String? {
        if let v = try? decode(String.self, forKey: key) { return v }
        if let i = try? decode(Int.self, forKey: key) { return String(i) }
        return nil
    }
    func flexibleFloat(_ key: Key, default def: Float = 0) -> Float {
        if let v = try? decode(Float.self, forKey: key) { return v }
        if let d = try? decode(Double.self, forKey: key) { return Float(d) }
        if let s = try? decode(String.self, forKey: key), let v = Float(s) { return v }
        return def
    }
}

struct Movie: Codable {
    var num: Int
    var name: String
    var streamType: String
    var streamId: Int
    var streamIcon: String
    var rating5Based: Float
    var added: String
    var adult: String
    var categoryId: String
    var containerExtension: String
    var customSid: String?
    var directSource: String
    
    enum CodingKeys: String, CodingKey {
        case num
        case name
        case streamType = "stream_type"
        case streamId = "stream_id"
        case streamIcon = "stream_icon"
        case rating5Based = "rating_5based"
        case added
        case adult = "is_adult"
        case categoryId = "category_id"
        case containerExtension = "container_extension"
        case customSid = "custom_sid"
        case directSource = "direct_source"
    }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        num = c.flexibleInt(.num)
        name = c.flexibleString(.name)
        streamType = c.flexibleString(.streamType)
        streamId = c.flexibleInt(.streamId)
        streamIcon = c.flexibleString(.streamIcon)
        rating5Based = c.flexibleFloat(.rating5Based)
        added = c.flexibleString(.added)
        adult = c.flexibleString(.adult)
        categoryId = c.flexibleString(.categoryId)
        containerExtension = c.flexibleString(.containerExtension)
        customSid = c.flexibleStringOptional(.customSid)
        directSource = c.flexibleString(.directSource)
    }

    var isAdult: Bool {
        Int(adult) == 1
    }
    
    var streamIconURL: URL? {
        URL(string: streamIcon)
    }

    var addedDateFormatted: String {
        let timestamp = TimeInterval(added) ?? 0
        return parseDateFormat(timestamp: timestamp)
    }
}

extension Movie: Identifiable, Hashable {
    public var id: String { num.description }
}

extension Movie {
    
    static var previewData: [Movie] {
        guard let url = Bundle.main.url(forResource: "movie", withExtension: "json") else {
            fatalError("movie.json not found in bundle")
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([Movie].self, from: data)
        } catch {
            fatalError("Failed to decode movie.json: \(error)")
        }
    }
    
}

struct MovieDetail: Codable {
    var info: Info
    // Unused by the app (the movie's own row already carries
    // stream_id/container_extension) and frequently malformed — some panels omit
    // it, others send `custom_sid: null` which fails `MovieData`'s decode. Decode
    // with `try?` so ANY problem inside it just yields nil, never failing the
    // whole detail fetch.
    var movieData: MovieData?

    enum CodingKeys: String, CodingKey {
        case info
        case movieData = "movie_data"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        info = try c.decode(Info.self, forKey: .info)
        movieData = try? c.decode(MovieData.self, forKey: .movieData)
    }
}

struct Info: Codable {
    let movieImage: String
    let tmdbID: String
    let backdrop: String
    let youtubeTrailer: String
    let genre: String
    let plot: String
    let cast: String
    let rating: String
    let director: String
    let releaseDate: String
    let backdropPath: [String]
    let durationSecs: Int
    let duration: String
    let video: Video?
    let audio: Audio?
    let bitrate: Int

    enum CodingKeys: String, CodingKey {
        case movieImage = "movie_image"
        case tmdbID = "tmdb_id"
        case backdrop
        case youtubeTrailer = "youtube_trailer"
        case genre
        case plot
        case cast
        case rating
        case director
        case releaseDate = "releasedate"
        case backdropPath = "backdrop_path"
        case durationSecs = "duration_secs"
        case duration
        case video
        case audio
        case bitrate
    }

    // Tolerant decode: Xtream `get_vod_info` payloads vary hugely between panels
    // — many omit `backdrop`, `tmdb_id`, or the ffprobe `video`/`audio` blocks
    // entirely, and some deliver numbers as strings. Requiring every field failed
    // the whole detail fetch (observed: "missing field 'backdrop'"), so the
    // detail page never loaded. Each field now falls back to a default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        movieImage = c.flexibleString(.movieImage)
        tmdbID = c.flexibleString(.tmdbID)
        backdrop = c.flexibleString(.backdrop)
        youtubeTrailer = c.flexibleString(.youtubeTrailer)
        genre = c.flexibleString(.genre)
        plot = c.flexibleString(.plot)
        cast = c.flexibleString(.cast)
        rating = c.flexibleString(.rating)
        director = c.flexibleString(.director)
        releaseDate = c.flexibleString(.releaseDate)
        backdropPath = (try? c.decode([String].self, forKey: .backdropPath)) ?? []
        durationSecs = c.flexibleInt(.durationSecs)
        duration = c.flexibleString(.duration)
        video = try? c.decodeIfPresent(Video.self, forKey: .video)
        audio = try? c.decodeIfPresent(Audio.self, forKey: .audio)
        bitrate = c.flexibleInt(.bitrate)
    }

    var youtubeTrailerURL: URL? {
        guard !youtubeTrailer.isEmpty else { return nil }
        return URL(string: "https://youtube.com/watch?v=\(youtubeTrailer)")
    }
}

struct Video: Codable {
    let index: Int
    let codecName: String
    let codecLongName: String
    let profile: String
    let codecType: String
    let codecTimeBase: String
    let codecTagString: String
    let codecTag: String
    let width: Int
    let height: Int
    let codedWidth: Int
    let codedHeight: Int
    let hasBFrames: Int
    let sampleAspectRatio: String
    let displayAspectRatio: String
    let pixFmt: String
    let level: Int
    let chromaLocation: String
    let refs: Int
    let isAvc: String
    let nalLengthSize: String
    let rFrameRate: String
    let avgFrameRate: String
    let timeBase: String
    let startPts: Int
    let startTime: String
    let durationTs: Int
    let duration: String
    let bitRate: String
    let bitsPerRawSample: String
    let nbFrames: String
    let disposition: Disposition
    let tags: VideoTags

    enum CodingKeys: String, CodingKey {
        case index
        case codecName = "codec_name"
        case codecLongName = "codec_long_name"
        case profile
        case codecType = "codec_type"
        case codecTimeBase = "codec_time_base"
        case codecTagString = "codec_tag_string"
        case codecTag = "codec_tag"
        case width
        case height
        case codedWidth = "coded_width"
        case codedHeight = "coded_height"
        case hasBFrames = "has_b_frames"
        case sampleAspectRatio = "sample_aspect_ratio"
        case displayAspectRatio = "display_aspect_ratio"
        case pixFmt = "pix_fmt"
        case level
        case chromaLocation = "chroma_location"
        case refs
        case isAvc = "is_avc"
        case nalLengthSize = "nal_length_size"
        case rFrameRate = "r_frame_rate"
        case avgFrameRate = "avg_frame_rate"
        case timeBase = "time_base"
        case startPts = "start_pts"
        case startTime = "start_time"
        case durationTs = "duration_ts"
        case duration
        case bitRate = "bit_rate"
        case bitsPerRawSample = "bits_per_raw_sample"
        case nbFrames = "nb_frames"
        case disposition
        case tags
    }
}

struct Disposition: Codable {
    let `default`: Int
    let dub: Int
    let original: Int
    let comment: Int
    let lyrics: Int
    let karaoke: Int
    let forced: Int
    let hearingImpaired: Int
    let visualImpaired: Int
    let cleanEffects: Int
    let attachedPic: Int
    let timedThumbnails: Int

    enum CodingKeys: String, CodingKey {
        case `default`
        case dub
        case original
        case comment
        case lyrics
        case karaoke
        case forced
        case hearingImpaired = "hearing_impaired"
        case visualImpaired = "visual_impaired"
        case cleanEffects = "clean_effects"
        case attachedPic = "attached_pic"
        case timedThumbnails = "timed_thumbnails"
    }
}

struct VideoTags: Codable {
    let language: String
    let handlerName: String

    enum CodingKeys: String, CodingKey {
        case language
        case handlerName = "handler_name"
    }
}

struct Audio: Codable {
    let index: Int
    let codecName: String
    let codecLongName: String
    let profile: String
    let codecType: String
    let codecTimeBase: String
    let codecTagString: String
    let codecTag: String
    let sampleFmt: String
    let sampleRate: String
    let channels: Int
    let channelLayout: String
    let bitsPerSample: Int
    let rFrameRate: String
    let avgFrameRate: String
    let timeBase: String
    let startPts: Int
    let startTime: String
    let durationTs: Int
    let duration: String
    let bitRate: String
    let maxBitRate: String
    let nbFrames: String
    let disposition: Disposition
    let tags: AudioTags

    enum CodingKeys: String, CodingKey {
        case index
        case codecName = "codec_name"
        case codecLongName = "codec_long_name"
        case profile
        case codecType = "codec_type"
        case codecTimeBase = "codec_time_base"
        case codecTagString = "codec_tag_string"
        case codecTag = "codec_tag"
        case sampleFmt = "sample_fmt"
        case sampleRate = "sample_rate"
        case channels
        case channelLayout = "channel_layout"
        case bitsPerSample = "bits_per_sample"
        case rFrameRate = "r_frame_rate"
        case avgFrameRate = "avg_frame_rate"
        case timeBase = "time_base"
        case startPts = "start_pts"
        case startTime = "start_time"
        case durationTs = "duration_ts"
        case duration
        case bitRate = "bit_rate"
        case maxBitRate = "max_bit_rate"
        case nbFrames = "nb_frames"
        case disposition
        case tags
    }
}

struct AudioTags: Codable {
    let language: String
    let handlerName: String

    enum CodingKeys: String, CodingKey {
        case language
        case handlerName = "handler_name"
    }
}

struct MovieData: Codable {
    let streamID: Int
    let name: String
    let added: String
    let categoryID: String
    let containerExtension: String
    let customSid: String
    let directSource: String

    enum CodingKeys: String, CodingKey {
        case streamID = "stream_id"
        case name
        case added
        case categoryID = "category_id"
        case containerExtension = "container_extension"
        case customSid = "custom_sid"
        case directSource = "direct_source"
    }
}
