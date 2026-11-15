import Foundation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class LiveViewModel {
    var selectedCategory: CategoryEntity?
    var selectedChannel: LiveEntity?
    var previewURL: URL?
    var isPreviewLoading: Bool = false
    var searchText: String = ""
    var isRefreshing: Bool = false
    /// Sidebar's "Favorites" entry is selected (instead of a category).
    var showFavorites: Bool = false
    /// Channels currently listed in the middle pane — the full-screen player
    /// steps through these for Previous/Next Channel.
    var channelList: [LiveEntity] = []
    /// Now + upcoming programmes for `selectedChannel`.
    var guide: [EPGListing] = []
    var isGuideLoading: Bool = false
    /// Full-screen request (preview pane's "Full Screen").
    var fullscreen: LivePlaybackRequest?

    private var resolveTask: Task<Void, Never>?
    private var guideTask: Task<Void, Never>?

    /// User-initiated playlist refresh from the Live TV sidebar. Runs the same
    /// manual sync as Settings. The sync writes on a background actor context;
    /// the channel list is now @Query-backed (not a `category.lives` traversal),
    /// so it re-runs and shows the new rows once that save lands.
    func refresh(
        profileId: String,
        repository: (any IPTVRepository)?,
        container: ModelContainer
    ) async {
        guard !isRefreshing, let repository else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let service = PlaylistSyncService(modelContainer: container)
        // The Live TV "Refresh List" only refreshes the channel list — never
        // touches Movies/Series (and won't prune them).
        _ = await service.refreshIfNeeded(
            trigger: .manual,
            scope: .liveOnly,
            profileId: profileId,
            repository: repository,
            progress: { _ in }
        )
    }

    func selectChannel(_ channel: LiveEntity, repository: (any IPTVRepository)?) {
        resolveTask?.cancel()
        resolveTask = nil
        selectedChannel = channel
        isPreviewLoading = false

        // Hand AVPlayer the raw HTTPS origin URL. AVFoundation's native HLS pipeline
        // handles segment fetching, redirects, and playlist refreshes far better than
        // our custom AVAssetResourceLoader — and NSAllowsArbitraryLoadsForMedia in
        // Info.plist permits the http redirect targets some Xtream CDNs use.
        previewURL = repository?.liveStreamURL(streamId: channel.streamId)
        loadGuide(for: channel, repository: repository)
    }

    func loadGuide(for channel: LiveEntity, repository: (any IPTVRepository)?) {
        guideTask?.cancel()
        guide = []
        guard channel.hasGuide, let repository else {
            isGuideLoading = false
            return
        }
        isGuideLoading = true
        let streamId = channel.streamId
        guideTask = Task {
            let listings = await EPGCache.shared.upcoming(streamId: streamId, repository: repository)
            guard !Task.isCancelled, selectedChannel?.streamId == streamId else { return }
            guide = listings
            isGuideLoading = false
        }
    }

    /// Opens the selected channel full screen, with the visible list for
    /// channel switching.
    func openFullscreen() {
        guard let channel = selectedChannel else { return }
        var channels = channelList
        var index = channels.firstIndex { $0.streamId == channel.streamId }
        if index == nil {
            channels = [channel]
            index = 0
        }
        fullscreen = LivePlaybackRequest(channels: channels, startIndex: index ?? 0)
    }

    func clearPreview() {
        resolveTask?.cancel()
        resolveTask = nil
        guideTask?.cancel()
        guideTask = nil
        selectedChannel = nil
        previewURL = nil
        isPreviewLoading = false
        guide = []
        isGuideLoading = false
    }
}
