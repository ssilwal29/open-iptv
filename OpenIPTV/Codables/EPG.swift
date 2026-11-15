import Foundation

/// One programme from the Xtream `get_short_epg` / `get_simple_data_table`
/// endpoints. Titles and descriptions arrive base64-encoded on most panels;
/// they are decoded here so callers only ever see display text.
struct EPGListing: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let description: String
    /// Absolute programme bounds (from the Unix `start_timestamp` /
    /// `stop_timestamp` fields — timezone-independent).
    let start: Date
    let end: Date
    /// Server-local start time exactly as the panel sent it
    /// (`yyyy-MM-dd HH:mm:ss`). Timeshift URLs must use the server's own
    /// clock, so this is kept verbatim instead of re-deriving it from `start`.
    let serverStart: String
    /// True when the panel has this programme in its catch-up archive.
    let hasArchive: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case description
        case start
        case end
        case stop
        case startTimestamp = "start_timestamp"
        case stopTimestamp = "stop_timestamp"
        case hasArchive = "has_archive"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawId = c.flexibleString(.id)
        title = EPGListing.decodeText(c.flexibleString(.title))
        description = EPGListing.decodeText(c.flexibleString(.description))
        serverStart = c.flexibleString(.start)
        let serverEnd = c.flexibleStringOptional(.end) ?? c.flexibleString(.stop)

        let startTS = c.flexibleInt(.startTimestamp)
        let stopTS = c.flexibleInt(.stopTimestamp)
        start = startTS > 0
            ? Date(timeIntervalSince1970: TimeInterval(startTS))
            : (EPGListing.serverDate(serverStart) ?? .distantPast)
        end = stopTS > 0
            ? Date(timeIntervalSince1970: TimeInterval(stopTS))
            : (EPGListing.serverDate(serverEnd) ?? .distantPast)
        hasArchive = c.flexibleInt(.hasArchive) == 1
        // Some panels omit/duplicate ids; the start timestamp disambiguates.
        id = rawId.isEmpty ? "\(startTS)-\(title)" : "\(rawId)-\(startTS)"
    }

    init(id: String, title: String, description: String, start: Date, end: Date, serverStart: String, hasArchive: Bool) {
        self.id = id
        self.title = title
        self.description = description
        self.start = start
        self.end = end
        self.serverStart = serverStart
        self.hasArchive = hasArchive
    }

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    func isAiring(at date: Date = .now) -> Bool { start <= date && date < end }

    /// 0...1 progress through the programme at `date`.
    func progress(at date: Date = .now) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(start) / duration))
    }

    /// Catch-up length in whole minutes, rounded up so the tail isn't cut.
    var durationMinutes: Int { Int((duration / 60).rounded(.up)) }

    /// `yyyy-MM-dd:HH-mm` — the start format Xtream timeshift URLs expect,
    /// built from the server-local start string. Nil if the panel sent an
    /// unexpected format.
    var timeshiftStart: String? {
        // "2024-05-01 20:00:00" → "2024-05-01:20-00"
        let parts = serverStart.split(separator: " ")
        guard parts.count == 2 else { return nil }
        let time = parts[1].split(separator: ":")
        guard parts[0].count == 10, time.count >= 2 else { return nil }
        return "\(parts[0]):\(time[0])-\(time[1])"
    }

    // MARK: - Helpers

    /// Decodes base64 text, falling back to the raw value when it isn't valid
    /// base64 UTF-8 (some panels send plain text).
    static func decodeText(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = Data(base64Encoded: trimmed),
              let decoded = String(data: data, encoding: .utf8),
              !decoded.isEmpty,
              !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" && $0 != "\t" })
        else { return trimmed }
        return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let serverFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Fallback when timestamps are missing. Interprets the server string in
    /// the device timezone — imprecise, but only used for display ordering.
    private static func serverDate(_ raw: String) -> Date? {
        serverFormatter.date(from: raw)
    }
}

struct EPGResponse: Decodable {
    let listings: [EPGListing]

    enum CodingKeys: String, CodingKey {
        case listings = "epg_listings"
    }

    init(from decoder: Decoder) throws {
        // Panels with no guide data return `[]`, `{}` or `{"epg_listings": false}`.
        if let c = try? decoder.container(keyedBy: CodingKeys.self) {
            listings = (try? c.decode([LossyListing].self, forKey: .listings))?.compactMap(\.value) ?? []
        } else {
            listings = []
        }
    }

    init(listings: [EPGListing]) {
        self.listings = listings
    }

    /// Skips a malformed programme instead of failing the whole guide.
    private struct LossyListing: Decodable {
        let value: EPGListing?
        init(from decoder: Decoder) throws {
            value = try? EPGListing(from: decoder)
        }
    }
}
