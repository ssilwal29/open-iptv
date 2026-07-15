import SwiftUI
import AVKit
import OSLog

private let itemLogger = Logger(subsystem: "com.openiptv.app", category: "AVPlayerItem")

struct OpenIPTVPlayer: UIViewControllerRepresentable {

    var url: URL
    @Binding var status: VideoStatus
    let isMuted: Bool
    let useNativeLoading: Bool
    let isLive: Bool

    let avplayer: AVPlayer
    let playerItem: AVPlayerItem
    let resourceLoader: InsecureAssetResourceLoader?

    /// Seconds to seek to once the item is ready (resume point); nil to start
    /// from the beginning.
    let resumeAt: Double?
    /// Periodic `(position, duration)` tick for resume-point persistence;
    /// `duration` is 0 when unknown. nil disables tracking (e.g. live).
    let onProgress: ((Double, Double) -> Void)?

    /// - Parameters:
    ///   - useNativeLoading: when true (default), hand the raw URL to AVPlayer
    ///     without the custom-scheme / AVAssetResourceLoader interception.
    ///     AVFoundation's native HLS / HTTP pipeline handles segment fetching,
    ///     range parallelism, prefetch, and adaptive bitrate end-to-end —
    ///     a manual byte-pump via `URLSessionDataTask` (the InsecureAssetResourceLoader
    ///     path) drains the buffer and stalls every few seconds. Relies on
    ///     `NSAllowsArbitraryLoadsForMedia = true` in Info.plist to permit
    ///     plain-HTTP and unusual TLS configs common on Xtream CDNs.
    ///
    ///     Pass `false` only as a compatibility escape hatch for servers whose
    ///     certificate chain AVPlayer rejects despite ATS.
    init(
        url: URL,
        status: Binding<VideoStatus>,
        isMuted: Bool = false,
        useNativeLoading: Bool = true,
        isLive: Bool = false,
        resumeAt: Double? = nil,
        onProgress: ((Double, Double) -> Void)? = nil
    ) {
        self.url = url
        self._status = status
        self.isMuted = isMuted
        self.useNativeLoading = useNativeLoading
        self.isLive = isLive
        self.resumeAt = resumeAt
        self.onProgress = onProgress

        let asset: AVURLAsset
        if useNativeLoading {
            asset = AVURLAsset(url: url)
            self.resourceLoader = nil
        } else {
            let loader = InsecureAssetResourceLoader()
            self.resourceLoader = loader
            let playbackURL = url.asAVPlayerCustomScheme ?? url
            asset = AVURLAsset(url: playbackURL)
            asset.resourceLoader.setDelegate(loader, queue: .main)
        }

        let item = AVPlayerItem(
            asset: asset,
            automaticallyLoadedAssetKeys: ["playable", "hasProtectedContent"]
        )
        // Tell AVPlayer how aggressively to prefetch. Default is 0 ("system
        // decides") which on slower CDNs lands at ~5–10s — fine for fast
        // networks, but causes "play, stall, play, stall" on jitter-prone
        // ones.
        //   • Live HLS: 60s. AVPlayer can only prefetch what the live
        //     playlist exposes, so this effectively means "buffer everything
        //     available".
        //   • VOD (movies/series): 30s. Predictable playback rate, no live
        //     edge to chase, 30s is comfortable on tvOS memory.
        item.preferredForwardBufferDuration = isLive ? 60 : 30

        if isLive {
            // Position the play head 30 seconds behind the live edge and
            // keep it there. Without this, AVPlayer chases the live edge —
            // the moment the play head catches the buffered tip, it stalls
            // until the next segment lands. With a configured offset,
            // network jitter eats into the 30s cushion instead of pausing
            // playback, and `automaticallyPreservesTimeOffsetFromLive`
            // ensures AVPlayer doesn't snap back to live after a stall
            // (which would immediately drain the buffer again).
            //
            // For IPTV (news / talk / shows) a 30s lag is invisible. For
            // live sports it would matter but we'd add a Settings toggle
            // before changing the default.
            item.configuredTimeOffsetFromLive = CMTime(seconds: 30, preferredTimescale: 1)
            item.automaticallyPreservesTimeOffsetFromLive = true
        }
        // tvOS 26 regression: when an AVPlayer is constructed via
        // `AVPlayer(playerItem:)`, `preventsDisplaySleepDuringVideoPlayback`
        // silently stops suppressing the system screensaver — the screensaver
        // overlays the video after a few minutes of remote idle. Routing the
        // item assignment through `replaceCurrentItem(_:)` re-arms the flag.
        // See https://developer.apple.com/forums/thread/801791
        self.avplayer = AVPlayer()
        self.avplayer.preventsDisplaySleepDuringVideoPlayback = true
        // Default is true; explicit so it's obvious that we want AVPlayer to
        // wait until it has enough buffer before resuming after a stall,
        // rather than restarting eagerly with a tiny buffer.
        self.avplayer.automaticallyWaitsToMinimizeStalling = true
        self.avplayer.isMuted = isMuted
        self.avplayer.replaceCurrentItem(with: item)
        self.playerItem = item
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = avplayer
        return vc
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) { }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(playerItem)
        coordinator.prepareToPlay { avplayer, change in
            switch playerItem.status {
            case .readyToPlay:
                itemLogger.notice("AVPlayerItem readyToPlay")
                // Resume to the saved position before playing, when it's a sane
                // seek (past the intro floor, before the tail). Otherwise start
                // from the top.
                let duration = playerItem.duration.seconds
                if let resumeAt = self.resumeAt, resumeAt > 15,
                   duration.isFinite, resumeAt < duration - 10 {
                    self.avplayer.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 1)) { _ in
                        self.avplayer.play()
                    }
                } else {
                    self.avplayer.play()
                }
                self.status = .playing
            case .failed:
                itemLogger.error("AVPlayerItem FAILED: \(playerItem.error?.localizedDescription ?? "nil", privacy: .public)")
                self.status = .failed(playerItem.error?.localizedDescription ?? "Unknown Error While Playing")
            case .unknown:
                itemLogger.notice("AVPlayerItem status unknown")
                self.status = .failed("Unknown error")
            @unknown default:
                self.status = .failed(playerItem.error?.localizedDescription ?? "Unknown Error While Playing")
            }
        }
        if let onProgress {
            coordinator.observeProgress(on: avplayer, every: 5, onProgress)
        }
        return coordinator
    }

    class Coordinator: NSObject {
        let item: AVPlayerItem
        var statusObserver: NSKeyValueObservation?
        private weak var player: AVPlayer?
        private var timeObserverToken: Any?
        private var onProgress: ((Double, Double) -> Void)?

        init(_ item: AVPlayerItem) {
            self.item = item
        }

        func prepareToPlay(changeHandler: @escaping (AVPlayerItem, NSKeyValueObservedChange<AVPlayerItem.Status>) -> Void) {
            self.statusObserver = item.observe(\.status, options: [.new, .old], changeHandler: changeHandler)
        }

        /// Periodic wall-clock tick reporting `(position, duration)` for
        /// resume-point persistence. `duration` is 0 when unknown (e.g. live).
        func observeProgress(on player: AVPlayer, every seconds: Double, _ handler: @escaping (Double, Double) -> Void) {
            self.player = player
            self.onProgress = handler
            let interval = CMTime(seconds: seconds, preferredTimescale: 1)
            self.timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                guard let self, let item = self.player?.currentItem else { return }
                let position = time.seconds
                guard position.isFinite else { return }
                let duration = item.duration.seconds
                self.onProgress?(position, duration.isFinite ? duration : 0)
            }
        }

        deinit {
            self.statusObserver?.invalidate()
            if let timeObserverToken { player?.removeTimeObserver(timeObserverToken) }
        }
    }
}
