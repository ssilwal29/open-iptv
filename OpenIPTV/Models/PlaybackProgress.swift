import Foundation
import SwiftData

/// Per-profile playback resume state for a movie or a series episode.
///
/// This is USER state, not synced catalog content: the sync engine's
/// `pruneOrphans` must never delete it, and it deliberately survives re-syncs.
/// Written by the video player (seek-on-resume + periodic save) and surfaced by
/// the Continue Watching rails.
@Model
final class PlaybackProgress {
    /// `"<profileId>|movie|<streamId>"` or `"<profileId>|episode|<episodeId>"`.
    /// Profile-scoped, so `.unique` is safe here (unlike the per-server stream
    /// IDs, whose uniqueness was dropped for multi-profile).
    @Attribute(.unique) var id: String
    var profile: Profile?
    /// `"movie"` | `"episode"`.
    var mediaKindRaw: String

    // Movie identity.
    var movieStreamId: Int?

    // Episode identity (+ denormalized season/number for the rail caption).
    var seriesId: Int?
    var episodeId: String?
    var seasonNumber: Int?
    var episodeNumber: Int?

    var position: Double     // seconds watched
    var duration: Double     // total seconds (0 when unknown)
    var updatedAt: Date

    init(
        id: String,
        profile: Profile?,
        mediaKindRaw: String,
        movieStreamId: Int? = nil,
        seriesId: Int? = nil,
        episodeId: String? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        position: Double,
        duration: Double,
        updatedAt: Date
    ) {
        self.id = id
        self.profile = profile
        self.mediaKindRaw = mediaKindRaw
        self.movieStreamId = movieStreamId
        self.seriesId = seriesId
        self.episodeId = episodeId
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.position = position
        self.duration = duration
        self.updatedAt = updatedAt
    }

    /// Fraction watched in `0...1`; `0` when the duration is unknown.
    var fraction: Double { duration > 0 ? min(max(position / duration, 0), 1) : 0 }
    /// Treated as watched once ≥ 95% — the store deletes these so they drop off
    /// the Continue Watching rail and re-watch starts fresh.
    var isFinished: Bool { duration > 0 && fraction >= 0.95 }
    /// Seconds left to watch.
    var remaining: Double { max(duration - position, 0) }

    /// Human "time left" label for the Continue Watching caption.
    var remainingText: String {
        guard duration > 0 else { return "" }
        let total = Int(remaining.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m left" }
        if minutes > 0 { return "\(minutes) min left" }
        return "Less than a minute left"
    }
}

// MARK: - Play key

/// Identifies a resumable item and carries the denormalized fields needed to
/// create its `PlaybackProgress` row. Built at the play call site.
struct PlaybackKey: Hashable {
    enum Kind: String { case movie, episode }

    let profileId: String
    let kind: Kind
    /// Movie `streamId` (stringified) or the episode id.
    let mediaId: String
    var movieStreamId: Int? = nil
    var seriesId: Int? = nil
    var seasonNumber: Int? = nil
    var episodeNumber: Int? = nil

    var id: String { "\(profileId)|\(kind.rawValue)|\(mediaId)" }

    static func movie(profileId: String, streamId: Int) -> PlaybackKey {
        PlaybackKey(profileId: profileId, kind: .movie, mediaId: String(streamId), movieStreamId: streamId)
    }

    static func episode(profileId: String, seriesId: Int, episodeId: String, season: Int, number: Int) -> PlaybackKey {
        PlaybackKey(
            profileId: profileId, kind: .episode, mediaId: episodeId,
            seriesId: seriesId, seasonNumber: season, episodeNumber: number
        )
    }
}

// MARK: - Store

/// Read/write helpers for `PlaybackProgress`. Must be called on the main
/// context's actor (the app's `ModelContext` is main-thread) — the video player
/// resolves resume on start and records on a main-queue periodic tick + dismiss.
enum PlaybackProgressStore {
    /// Below this many seconds we neither resume nor persist — avoids cluttering
    /// Continue Watching with accidental opens and pointless near-zero seeks.
    static let minTrackedSeconds: Double = 15
    /// Watched fraction at/above which the item is considered finished.
    static let finishedFraction: Double = 0.95

    /// Saved resume position for `key`, or nil if none / finished / too early.
    static func resumePosition(for key: PlaybackKey, in context: ModelContext) -> Double? {
        guard let row = fetch(key.id, in: context) else { return nil }
        guard !row.isFinished, row.position >= minTrackedSeconds else { return nil }
        return row.position
    }

    /// Upserts progress. Deletes the row once finished (so it leaves the rail and
    /// re-watch starts fresh); skips writes below `minTrackedSeconds`.
    static func record(_ key: PlaybackKey, position: Double, duration: Double, in context: ModelContext) {
        guard position.isFinite, position >= 0 else { return }
        let existing = fetch(key.id, in: context)

        if duration > 0, position / duration >= finishedFraction {
            if let existing {
                context.delete(existing)
                try? context.save()
            }
            return
        }

        guard position >= minTrackedSeconds else { return }

        if let existing {
            existing.position = position
            existing.duration = duration
            existing.updatedAt = Date()
        } else {
            context.insert(PlaybackProgress(
                id: key.id,
                profile: profile(key.profileId, in: context),
                mediaKindRaw: key.kind.rawValue,
                movieStreamId: key.movieStreamId,
                seriesId: key.seriesId,
                episodeId: key.kind == .episode ? key.mediaId : nil,
                seasonNumber: key.seasonNumber,
                episodeNumber: key.episodeNumber,
                position: position,
                duration: duration,
                updatedAt: Date()
            ))
        }
        try? context.save()
    }

    /// Deletes a single resume row by id (movie or episode).
    static func delete(id: String, in context: ModelContext) {
        guard let row = fetch(id, in: context) else { return }
        context.delete(row)
        try? context.save()
    }

    /// Deletes every episode resume row for a series+profile — clears it from
    /// Continue Watching and every episode progress bar in one shot.
    static func deleteSeriesEpisodes(seriesId: Int, profileId: String, in context: ModelContext) {
        let episodeKind = PlaybackKey.Kind.episode.rawValue
        let rows = (try? context.fetch(FetchDescriptor<PlaybackProgress>(
            predicate: #Predicate {
                $0.mediaKindRaw == episodeKind && $0.seriesId == seriesId && $0.profile?.id == profileId
            }
        ))) ?? []
        for row in rows { context.delete(row) }
        try? context.save()
    }

    private static func fetch(_ id: String, in context: ModelContext) -> PlaybackProgress? {
        let descriptor = FetchDescriptor<PlaybackProgress>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    private static func profile(_ id: String, in context: ModelContext) -> Profile? {
        let descriptor = FetchDescriptor<Profile>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }
}
