import SwiftUI
import UIKit
import AVKit
import OSLog
import SwiftData

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
}
