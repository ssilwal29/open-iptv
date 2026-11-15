import Foundation

/// Shared between the app and the Top Shelf extension (compiled into both
/// targets). The app writes a small JSON snapshot of Continue Watching into
/// the App Group container; the extension reads it — it has no access to the
/// app's SwiftData store.
enum TopShelfShared {
    static let appGroup = "group.io.OpenIPTV"
    static let urlScheme = "openiptvapp"

    /// nil when the App Group isn't provisioned (e.g. unsigned simulator
    /// builds); both sides then simply skip Top Shelf.
    static var snapshotURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("TopShelf.json")
    }
}

struct TopShelfSnapshot: Codable, Equatable {
    struct Item: Codable, Hashable {
        enum Kind: String, Codable {
            case movie, episode
        }

        let id: String
        let kind: Kind
        let title: String
        let subtitle: String?
        let imageURL: URL?
        /// 0...1 watched.
        let progress: Double
        /// Opens the detail page.
        let displayURL: URL
        /// Resumes playback.
        let playURL: URL
    }

    var items: [Item]

    static func load() -> TopShelfSnapshot? {
        guard let url = TopShelfShared.snapshotURL,
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(TopShelfSnapshot.self, from: data)
    }

    /// Writes the snapshot; returns false when nothing changed or the App
    /// Group isn't available.
    @discardableResult
    func save() -> Bool {
        guard let url = TopShelfShared.snapshotURL else { return false }
        if TopShelfSnapshot.load() == self { return false }
        guard let data = try? JSONEncoder().encode(self) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

/// `openiptvapp://open?profile=<id>&kind=movie&id=<streamId>[&play=1]`
/// `openiptvapp://open?profile=<id>&kind=episode&series=<seriesId>&episode=<episodeId>[&play=1]`
struct TopShelfLink: Equatable {
    enum Target: Equatable {
        case movie(streamId: Int)
        case episode(seriesId: Int, episodeId: String)
    }

    let profileId: String
    let target: Target
    let play: Bool

    init(profileId: String, target: Target, play: Bool) {
        self.profileId = profileId
        self.target = target
        self.play = play
    }

    init?(url: URL) {
        guard url.scheme == TopShelfShared.urlScheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value { query[item.name] = value }
        }
        guard let profileId = query["profile"], !profileId.isEmpty else { return nil }
        switch query["kind"] {
        case "movie":
            guard let id = query["id"].flatMap(Int.init) else { return nil }
            target = .movie(streamId: id)
        case "episode":
            guard let seriesId = query["series"].flatMap(Int.init),
                  let episodeId = query["episode"], !episodeId.isEmpty
            else { return nil }
            target = .episode(seriesId: seriesId, episodeId: episodeId)
        default:
            return nil
        }
        self.profileId = profileId
        self.play = query["play"] == "1"
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = TopShelfShared.urlScheme
        components.host = "open"
        var items = [URLQueryItem(name: "profile", value: profileId)]
        switch target {
        case .movie(let streamId):
            items += [
                URLQueryItem(name: "kind", value: "movie"),
                URLQueryItem(name: "id", value: String(streamId))
            ]
        case .episode(let seriesId, let episodeId):
            items += [
                URLQueryItem(name: "kind", value: "episode"),
                URLQueryItem(name: "series", value: String(seriesId)),
                URLQueryItem(name: "episode", value: episodeId)
            ]
        }
        if play { items.append(URLQueryItem(name: "play", value: "1")) }
        components.queryItems = items
        // All components are set from valid values, so this can't fail.
        return components.url!
    }
}
