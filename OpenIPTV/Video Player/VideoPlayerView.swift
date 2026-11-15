import SwiftUI
import UIKit
import AVKit
import OSLog
import SwiftData
import NukeUI

private let logger = Logger(subsystem: "com.openiptv.app", category: "VideoPlayer")

struct VideoPlayerView: View {
    let url: URL
    let title: String
    var useNativeLoading: Bool = true
    /// Hint that this is a live stream (HLS `.m3u8` from a `/live/` endpoint).
    /// Drives a deeper forward-buffer target so AVPlayer prefetches more of the
    /// available playlist segments and rides through brief network jitters
    /// without stalling. VOD (movies/series) get a smaller buffer because
    /// their playback rate is predictable and 30s is already comfortable.
    var isLive: Bool = false
    /// Resume-tracking identity for this playback; nil disables Continue
    /// Watching (e.g. live channels).
    var progressKey: PlaybackKey? = nil
    /// When true, ignore any saved resume point and start at 0 (progress is
    /// still recorded as the user watches). Drives "Play from Beginning".
    var startFromBeginning: Bool = false
    /// Title/artwork/description for the player's Info panel. Re-applied when
    /// it changes (e.g. a live programme title arrives after the stream starts).
    var metadata: PlaybackMetadata? = nil
    /// Extra buttons in the transport bar (e.g. live channel up/down).
    var transportActions: [PlayerTransportAction] = []
    /// Called once when a VOD item plays through to its end.
    var onPlayedToEnd: (() -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @State var status: VideoStatus = .stopped
    @State var errorString = ""

    // Last reported playback position, kept in a plain reference so the 5s
    // tick can stash it without invalidating the view. Used for a final save
    // on dismiss (captures the seconds since the last periodic save).
    @State private var tracker = PlaybackTracker()

    var body: some View {
        // Resolved synchronously here so the player's coordinator captures the
        // resume point at creation (it can't pick up a later async change). The
        // fetch is a cheap keyed lookup and this runs only a handful of times.
        let resume = startFromBeginning
            ? nil
            : progressKey.flatMap { PlaybackProgressStore.resumePosition(for: $0, in: modelContext) }

        ZStack {
            OpenIPTVPlayer(
                url: url,
                status: $status,
                useNativeLoading: useNativeLoading,
                isLive: isLive,
                resumeAt: resume,
                metadata: metadata ?? PlaybackMetadata(title: title),
                transportActions: transportActions,
                onPlayedToEnd: onPlayedToEnd,
                onProgress: progressKey == nil ? nil : { position, duration in
                    tracker.lastPosition = position
                    tracker.lastDuration = duration
                    if let key = progressKey {
                        PlaybackProgressStore.record(key, position: position, duration: duration, in: modelContext)
                    }
                }
            )
            .ignoresSafeArea()
            .onAppear {
                // `preventsDisplaySleepDuringVideoPlayback` only inhibits
                // the screensaver while `timeControlStatus == .playing`,
                // and live HLS frequently dips into `.waitingToPlayAtSpecifiedRate`
                // on buffer jitter — those gaps add up and the screensaver fires.
                UIApplication.shared.isIdleTimerDisabled = true
            }
            .onDisappear {
                self.status = .stopped
                UIApplication.shared.isIdleTimerDisabled = false
                // Final save so we don't lose the seconds since the last tick.
                if let key = progressKey, tracker.lastPosition > 0 {
                    PlaybackProgressStore.record(key, position: tracker.lastPosition, duration: tracker.lastDuration, in: modelContext)
                }
            }

            if !errorString.isEmpty {
                Text(errorString).padding(.bottom, 90).foregroundColor(.secondary)
            }
        }
        .background(Color.black)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationTitle(title)
        .onChange(of: status) { _, newValue in
            switch newValue {
            case .playing:
                logger.info("Playing video: \(url.absoluteString, privacy: .private)")
                self.errorString = ""
            case .failed(let error):
                logger.error("Video failed: \(error, privacy: .public) — \(url.absoluteString, privacy: .private)")
                self.errorString = error
            case .stopped:
                logger.info("Stopped: \(url.absoluteString, privacy: .private)")
                // Never echo the URL: Xtream stream URLs embed the username
                // and password in the path.
                self.errorString = ""
            }
        }
    }
}

enum VideoStatus: Equatable, Hashable {
    case playing
    case failed(String)
    case stopped
}

/// Holds the latest reported playback position outside SwiftUI state so the 5s
/// progress tick doesn't invalidate the view. Read once on dismiss for a final
/// resume-point save.
private final class PlaybackTracker {
    var lastPosition: Double = 0
    var lastDuration: Double = 0
}

/// Info-panel metadata for the current item.
struct PlaybackMetadata: Equatable {
    var title: String
    var subtitle: String? = nil
    var description: String? = nil
    var artworkURL: URL? = nil
}

/// A button added to the player's transport bar.
struct PlayerTransportAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let handler: () -> Void
}

/// What plays after the current item finishes (next episode). `resolve` runs
/// only if the viewer accepts, so the next stream URL isn't probed up front.
struct UpNext {
    let title: String
    var subtitle: String? = nil
    var artworkURL: URL? = nil
    let resolve: @MainActor () async -> ResolvedPlayback?
}

/// A fully-resolved playback request. The stream URL is resolved *before* this
/// is presented (with a spinner on the control that was pressed), so the
/// fullScreenCover goes straight to the player — its own spinner then covers
/// buffering. No intermediate "Preparing stream…" surface.
struct ResolvedPlayback: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    var progressKey: PlaybackKey? = nil
    var startFromBeginning: Bool = false
    var isLive: Bool = false
    var metadata: PlaybackMetadata? = nil
    var upNext: UpNext? = nil
}

/// Full-screen playback for a `ResolvedPlayback`, used by every
/// `.fullScreenCover(item:)` that plays VOD. When the item ends and has an
/// `upNext`, the player is swapped for a SwiftUI "Up Next" screen — a plain
/// SwiftUI surface rather than an overlay on `AVPlayerViewController`, because
/// the player view controller would otherwise keep tvOS focus and the
/// overlay's buttons couldn't be reached reliably.
struct PlaybackScreen: View {
    @State private var current: ResolvedPlayback
    @State private var pendingNext: UpNext?
    @State private var isResolvingNext = false
    @Environment(\.dismiss) private var dismiss

    init(playback: ResolvedPlayback) {
        _current = State(initialValue: playback)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let next = pendingNext {
                UpNextScreen(
                    next: next,
                    isResolving: isResolvingNext,
                    onPlay: { play(next) },
                    onCancel: { dismiss() }
                )
            } else {
                VideoPlayerView(
                    url: current.url,
                    title: current.title,
                    isLive: current.isLive,
                    progressKey: current.progressKey,
                    startFromBeginning: current.startFromBeginning,
                    metadata: current.metadata,
                    onPlayedToEnd: current.upNext == nil ? nil : {
                        pendingNext = current.upNext
                    }
                )
                // New identity per item so the AVPlayer + coordinator are rebuilt.
                .id(current.id)
            }
        }
    }

    private func play(_ next: UpNext) {
        guard !isResolvingNext else { return }
        isResolvingNext = true
        Task {
            let resolved = await next.resolve()
            isResolvingNext = false
            if let resolved {
                current = resolved
                pendingNext = nil
            } else {
                dismiss()
            }
        }
    }
}

private struct UpNextScreen: View {
    let next: UpNext
    let isResolving: Bool
    let onPlay: () -> Void
    let onCancel: () -> Void

    private static let countdownSeconds = 10
    @State private var remaining = UpNextScreen.countdownSeconds
    @State private var countdownActive = true
    @FocusState private var playFocused: Bool

    var body: some View {
        ZStack {
            if let url = next.artworkURL {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image.resizable().scaledToFill()
                    }
                }
                .ignoresSafeArea()
                .blur(radius: 40)
                .opacity(0.45)
            }

            HStack(alignment: .center, spacing: 56) {
                if let url = next.artworkURL {
                    LazyImage(url: url) { state in
                        if let image = state.image {
                            image.resizable().scaledToFill()
                        } else {
                            Rectangle().fill(.regularMaterial)
                        }
                    }
                    .frame(width: 560, height: 315)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 18) {
                    Text("UP NEXT")
                        .font(.caption.bold())
                        .tracking(2)
                        .foregroundStyle(.secondary)
                    Text(next.title)
                        .font(.displayTitle)
                        .lineLimit(2)
                    if let subtitle = next.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.heroSubtitle)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text(countdownActive ? "Starting in \(remaining)s" : " ")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                    HStack(spacing: 24) {
                        Button(action: onPlay) {
                            HStack(spacing: 12) {
                                if isResolving {
                                    ProgressView()
                                } else {
                                    Image(systemName: "play.fill")
                                }
                                Text("Play Now")
                            }
                            .padding(.horizontal, 12)
                        }
                        .buttonStyle(.glassProminent)
                        .focused($playFocused)

                        Button(action: onCancel) {
                            Text("Back").padding(.horizontal, 12)
                        }
                        .buttonStyle(.glass)
                    }
                    .padding(.top, 12)
                }
                .frame(maxWidth: 820, alignment: .leading)
            }
            .padding(80)
        }
        .defaultFocus($playFocused, true)
        .onExitCommand(perform: onCancel)
        .onChange(of: playFocused) { _, focused in
            // Moving off "Play Now" means the viewer is deciding — stop the clock.
            if !focused { countdownActive = false }
        }
        .task {
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, countdownActive else { return }
                remaining -= 1
            }
            if countdownActive { onPlay() }
        }
    }
}
