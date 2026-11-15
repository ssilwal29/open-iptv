import SwiftUI
import UIKit
import NukeUI

// MARK: - Full-screen live player with channel switching

/// A live channel to play full screen, plus the list it came from so the
/// viewer can step through neighbouring channels without leaving the player.
struct LivePlaybackRequest: Identifiable {
    let id = UUID()
    let channels: [LiveEntity]
    let startIndex: Int
}

/// Full-screen live playback. "Previous/Next Channel" sit in the transport bar
/// (swipe down → transport bar on the Siri Remote); switching rebuilds the
/// player for the new stream. The current programme (from the guide) is shown
/// in the Info panel.
struct LiveFullscreenPlayer: View {
    let request: LivePlaybackRequest

    @Environment(\.iptvRepository) private var repository
    @State private var index: Int
    @State private var programme: EPGListing?

    init(request: LivePlaybackRequest) {
        self.request = request
        let upper = max(0, request.channels.count - 1)
        _index = State(initialValue: min(max(0, request.startIndex), upper))
    }

    private var channel: LiveEntity? {
        request.channels.indices.contains(index) ? request.channels[index] : nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let channel, let url = repository?.liveStreamURL(streamId: channel.streamId) {
                VideoPlayerView(
                    url: url,
                    title: channel.name,
                    isLive: true,
                    metadata: PlaybackMetadata(
                        title: channel.name,
                        subtitle: programme?.title ?? "Channel \(channel.num)",
                        description: programme?.description,
                        artworkURL: channel.streamIconURL
                    ),
                    transportActions: transportActions
                )
                .id(channel.streamId)
            }
        }
        .task(id: channel?.streamId) {
            programme = nil
            guard let channel, channel.hasGuide, let repository else { return }
            let upcoming = await EPGCache.shared.upcoming(streamId: channel.streamId, repository: repository)
            guard !Task.isCancelled else { return }
            programme = upcoming.first { $0.isAiring() }
        }
    }

    private var transportActions: [PlayerTransportAction] {
        let channels = request.channels
        guard channels.count > 1 else { return [] }
        let count = channels.count
        let previous = channels[(index - 1 + count) % count]
        let next = channels[(index + 1) % count]
        return [
            PlayerTransportAction(
                id: "channel.previous",
                title: "Previous: \(previous.name)",
                systemImage: "chevron.down"
            ) { index = (index - 1 + count) % count },
            PlayerTransportAction(
                id: "channel.next",
                title: "Next: \(next.name)",
                systemImage: "chevron.up"
            ) { index = (index + 1) % count }
        ]
    }
}

// MARK: - Catch-up browser

/// Lists a channel's archived programmes (newest first, grouped by day) and
/// plays the selected one through the panel's timeshift endpoint.
struct CatchupView: View {
    let channel: LiveEntity

    @Environment(\.iptvRepository) private var repository
    @Environment(\.dismiss) private var dismiss
    @State private var listings: [EPGListing] = []
    @State private var isLoading = true
    @State private var playback: ResolvedPlayback?
    @State private var failedListingId: String?

    private struct Day: Identifiable {
        let id: Date
        let listings: [EPGListing]
    }

    private var days: [Day] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: listings) { calendar.startOfDay(for: $0.start) }
        return grouped.keys.sorted(by: >).map { Day(id: $0, listings: grouped[$0] ?? []) }
    }

    var body: some View {
        ZStack {
            AmbientBackdrop()
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 24) {
                    LazyImage(url: channel.streamIconURL) { state in
                        if let image = state.image {
                            image.resizable().scaledToFit()
                        } else {
                            Image(systemName: "tv").foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 72, height: 72)
                    .padding(8)
                    .cardSurface(cornerRadius: 14)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Catch-up")
                            .font(.displayTitle)
                        Text(channel.name)
                            .font(.heroSubtitle)
                            .foregroundStyle(.secondary)
                    }
                }

                content
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 60)
        }
        .task {
            guard let repository else {
                isLoading = false
                return
            }
            listings = await EPGCache.shared.archive(streamId: channel.streamId, repository: repository)
            isLoading = false
        }
        .fullScreenCover(item: $playback) { PlaybackScreen(playback: $0) }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if listings.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text("No archived programmes for this channel.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Back") { dismiss() }
                    .buttonStyle(.glass)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(days) { day in
                        Text(day.id, format: .dateTime.weekday(.wide).day().month(.wide))
                            .font(.sectionTitle)
                            .padding(.top, 18)
                        ForEach(day.listings) { listing in
                            CatchupRow(
                                listing: listing,
                                failed: failedListingId == listing.id,
                                onPlay: { play(listing) }
                            )
                        }
                    }
                }
                .padding(.vertical, 12)
            }
        }
    }

    private func play(_ listing: EPGListing) {
        guard let url = repository?.catchupStreamURL(streamId: channel.streamId, listing: listing) else {
            failedListingId = listing.id
            return
        }
        failedListingId = nil
        playback = ResolvedPlayback(
            url: url,
            title: listing.title,
            metadata: PlaybackMetadata(
                title: listing.title,
                subtitle: "\(channel.name) · \(EPGFormat.timeRange(listing))",
                description: listing.description,
                artworkURL: channel.streamIconURL
            )
        )
    }
}

private struct CatchupRow: View {
    let listing: EPGListing
    let failed: Bool
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(alignment: .firstTextBaseline, spacing: 28) {
                Text(EPGFormat.timeRange(listing))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 230, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    Text(listing.title.isEmpty ? "Untitled programme" : listing.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if failed {
                        Text("This programme can't be played from the archive.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if !listing.description.isEmpty {
                        Text(listing.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "play.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.card)
    }
}

// MARK: - Formatting

enum EPGFormat {
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "20:00 – 21:00"
    static func timeRange(_ listing: EPGListing) -> String {
        "\(time(listing.start)) – \(time(listing.end))"
    }
}

// MARK: - Screensaver guard

/// Reference-counted `isIdleTimerDisabled`. Switching channels or moving to the
/// next episode swaps one player view for another, and SwiftUI doesn't
/// guarantee the old view's `onDisappear` runs before the new one's
/// `onAppear` — a plain on/off toggle could re-enable the screensaver while
/// video is still playing.
@MainActor
enum IdleTimerGuard {
    private static var holders = 0

    static func acquire() {
        holders += 1
        UIApplication.shared.isIdleTimerDisabled = true
    }

    static func release() {
        holders = max(0, holders - 1)
        UIApplication.shared.isIdleTimerDisabled = holders > 0
    }
}
