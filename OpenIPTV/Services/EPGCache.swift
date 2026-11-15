import Foundation
import OSLog

private let logger = Logger(subsystem: "com.openiptv.app", category: "EPG")

/// In-memory guide cache shared by the Live TV list, preview pane and search.
///
/// Guide data is short-lived (a programme ends within the hour) and large if
/// fetched for a whole provider, so it is fetched per channel, on demand, and
/// never persisted. Requests for the same channel are coalesced, and at most
/// `maxConcurrent` requests run at once so scrolling a 1,000-row channel list
/// doesn't flood the panel.
actor EPGCache {
    static let shared = EPGCache()

    private struct Entry {
        let fetchedAt: Date
        let listings: [EPGListing]
    }

    private enum Kind: String { case short, archive }

    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<[EPGListing], Never>] = [:]

    private let ttl: TimeInterval = 15 * 60
    private let maxEntries = 600
    private let maxConcurrent = 4
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Now + upcoming programmes for a channel. Empty when the panel has no
    /// guide data for it (or the request failed — the row just shows no guide).
    func upcoming(streamId: Int, repository: any IPTVRepository) async -> [EPGListing] {
        let all = await load(.short, streamId: streamId, repository: repository) {
            try await repository.fetchShortEPG(streamId: streamId, limit: 6)
        }
        let now = Date()
        return all.filter { $0.end > now }.sorted { $0.start < $1.start }
    }

    /// Programmes that have finished and are in the panel's catch-up archive,
    /// newest first.
    func archive(streamId: Int, repository: any IPTVRepository) async -> [EPGListing] {
        let all = await load(.archive, streamId: streamId, repository: repository) {
            try await repository.fetchEPGArchive(streamId: streamId)
        }
        let now = Date()
        return all
            .filter { $0.hasArchive && $0.end <= now }
            .sorted { $0.start > $1.start }
    }

    func removeAll() {
        entries.removeAll()
    }

    // MARK: - Private

    private func load(
        _ kind: Kind,
        streamId: Int,
        repository: any IPTVRepository,
        fetch: @escaping () async throws -> [EPGListing]
    ) async -> [EPGListing] {
        let key = "\(kind.rawValue)|\(repository.identity)|\(streamId)"
        let now = Date()
        if let entry = entries[key], now.timeIntervalSince(entry.fetchedAt) < ttl {
            // A short guide whose last programme already ended is stale even
            // inside the TTL.
            let exhausted = kind == .short && !entry.listings.isEmpty
                && !entry.listings.contains { $0.end > now }
            if !exhausted { return entry.listings }
        }
        if let task = inFlight[key] {
            return await task.value
        }

        // Unstructured on purpose: if the row that asked scrolls away and
        // cancels, the fetch still completes and warms the cache.
        let task = Task<[EPGListing], Never> {
            await self.acquire()
            let result: [EPGListing]
            do {
                result = try await fetch()
            } catch {
                logger.debug("EPG \(kind.rawValue, privacy: .public) fetch failed for \(streamId): \(error.localizedDescription, privacy: .public)")
                result = []
            }
            await self.release()
            return result
        }
        inFlight[key] = task
        let listings = await task.value
        inFlight[key] = nil
        store(key, listings)
        return listings
    }

    private func store(_ key: String, _ listings: [EPGListing]) {
        if entries.count >= maxEntries {
            // Drop the oldest quarter; cheap and good enough for a UI cache.
            let victims = entries.sorted { $0.value.fetchedAt < $1.value.fetchedAt }
                .prefix(maxEntries / 4)
                .map(\.key)
            for key in victims { entries[key] = nil }
        }
        entries[key] = Entry(fetchedAt: Date(), listings: listings)
    }

    private func acquire() async {
        if running < maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            // Hand the slot straight to the next waiter (running stays the same).
            waiters.removeFirst().resume()
        }
    }
}
