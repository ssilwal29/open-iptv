import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.iptvRepository) private var repository
    @Environment(\.modelContext) private var modelContext
    @Binding var isConfigured: Bool

    @AppStorage("activeProfileId") private var activeProfileId: String = ""

    @State private var viewModel = ContentViewModel()
    @State private var detailModalActive = false
    @Query private var profiles: [Profile]

    // Top Shelf deep links: held until the library and repository are ready.
    @State private var pendingLink: TopShelfLink?
    @State private var deepLinkMovie: MovieEntity?
    @State private var deepLinkSerie: SerieEntity?
    @State private var deepLinkPlayback: ResolvedPlayback?

    private var activeProfile: Profile? {
        profiles.first(where: { $0.id == activeProfileId })
    }

    /// `true` once the active profile has at least one prior successful sync.
    /// Drives the "skip the full-screen progress, do a stale-refresh in the
    /// background" path on relaunch.
    private var activeProfileHasCache: Bool {
        guard let profile = activeProfile else { return false }
        return profile.lastSyncedAt != nil
    }

    /// The `iptvRepository` is rebuilt asynchronously by `RootView` when the
    /// active profile changes. Until it catches up, the injected repository
    /// still targets the PREVIOUS profile's server — bootstrapping then would
    /// sync the old server's catalog onto the new profile (the "switch shows
    /// old content until Refresh List" bug). Only bootstrap once the repository
    /// actually matches the active profile.
    private var repositoryMatchesActiveProfile: Bool {
        guard let repository, let profile = activeProfile else { return false }
        return repository.identity == profile.repositoryIdentity
    }

    var body: some View {
        if isConfigured {
            contentBody
                .onOpenURL { url in
                    if let link = TopShelfLink(url: url) { pendingLink = link }
                }
                .task(id: deepLinkKey) { await processPendingLink() }
                .task(id: "\(activeProfileId)|\(viewModel.phase)") {
                    guard viewModel.phase == .ready else { return }
                    TopShelfPublisher.publish(profileId: activeProfileId, in: modelContext)
                }
                .task(id: bootstrapKey) {
                    guard let repository, !activeProfileId.isEmpty,
                          repositoryMatchesActiveProfile else { return }
                    await viewModel.bootstrap(
                        hasCachedPlaylist: activeProfileHasCache,
                        profileId: activeProfileId,
                        repository: repository,
                        container: modelContext.container,
                        context: modelContext
                    )
                }
        } else {
            SetupView(isConfigured: $isConfigured)
        }
    }

    private var deepLinkKey: String {
        "\(pendingLink?.url.absoluteString ?? "-")|\(viewModel.phase)|\(bootstrapKey)"
    }

    /// Opens (or plays) the item a Top Shelf tile points at. Switches profile
    /// first when the tile belongs to another one, then waits for the
    /// repository/bootstrap to catch up (the task re-runs on `deepLinkKey`).
    private func processPendingLink() async {
        guard let link = pendingLink else { return }
        if link.profileId != activeProfileId {
            guard profiles.contains(where: { $0.id == link.profileId }) else {
                pendingLink = nil
                return
            }
            activeProfileId = link.profileId
            return
        }
        guard viewModel.phase == .ready, let repository, repositoryMatchesActiveProfile else { return }
        pendingLink = nil
        let profileId = activeProfileId

        switch link.target {
        case .movie(let streamId):
            var d = FetchDescriptor<MovieEntity>(
                predicate: #Predicate { $0.streamId == streamId && $0.profile?.id == profileId }
            )
            d.fetchLimit = 1
            guard let movie = try? modelContext.fetch(d).first else { return }
            guard link.play,
                  let raw = repository.movieStreamURL(streamId: movie.streamId, containerExtension: movie.containerExtension)
            else {
                deepLinkMovie = movie
                return
            }
            let resolved = await StreamURLResolver.shared.resolve(raw)
            deepLinkPlayback = ResolvedPlayback(
                url: resolved,
                title: movie.name,
                progressKey: .movie(profileId: profileId, streamId: movie.streamId),
                metadata: PlaybackMetadata(
                    title: movie.name,
                    description: movie.detail?.plot,
                    artworkURL: movie.streamIconURL
                )
            )

        case .episode(let seriesId, let episodeId):
            var d = FetchDescriptor<SerieEntity>(
                predicate: #Predicate { $0.seriesId == seriesId && $0.profile?.id == profileId }
            )
            d.fetchLimit = 1
            guard let serie = try? modelContext.fetch(d).first else { return }
            guard link.play,
                  let episode = serie.orderedEpisodes.first(where: { $0.episodeId == episodeId })
            else {
                deepLinkSerie = serie
                return
            }
            deepLinkPlayback = await EpisodePlayback.resolve(
                episode: episode,
                serie: serie,
                profileId: profileId,
                repository: repository
            )
        }
    }

    /// Re-bootstrap when either the repository (its credentials/identity) or
    /// the active profile change. Keying off `repository?.identity` — not just
    /// nil-ness — means the task re-fires the moment `RootView` rebuilds the
    /// repository for the newly-selected profile, so bootstrap runs against the
    /// correct server rather than the one present at the instant of the switch.
    private var bootstrapKey: String {
        "\(repository?.identity ?? "_"):\(activeProfileId)"
    }

    @ViewBuilder
    private var contentBody: some View {
        switch viewModel.phase {
        case .idle, .initialSync:
            SyncProgressView(progress: viewModel.progress)

        case .ready:
            NavigationStack {
                TabView {
                    LiveView()
                        .tabItem { Label("Live TV", systemImage: "tv.badge.wifi") }
                        .ignoresSafeArea(edges: [.bottom, .horizontal])

                    MovieView()
                        .tabItem { Label("Movies", systemImage: "movieclapper") }
                        .ignoresSafeArea(edges: [.bottom, .horizontal])

                    SerieView()
                        .tabItem { Label("Series", systemImage: "popcorn") }
                        .ignoresSafeArea(edges: [.bottom, .horizontal])

                    SearchView()
                        .tabItem { Image(systemName: "magnifyingglass") }
                        .ignoresSafeArea(edges: [.bottom, .horizontal])

                    SettingsView()
                        .tabItem { Image(systemName: "gear") }
                        .ignoresSafeArea(edges: [.bottom, .horizontal])
                }
                .tabViewStyle(.tabBarOnly)
                .navigationDestination(item: $deepLinkMovie) { MovieDetailView(movie: $0) }
                .navigationDestination(item: $deepLinkSerie) { SerieDetailView(serie: $0) }
            }
            .fullScreenCover(item: $deepLinkPlayback) { PlaybackScreen(playback: $0) }
            // Chrome overlays on the same top band as the native TabView tab
            // pill. Blurred in sync with any detail-level modal via preference.
            .overlay(alignment: .top) {
                TopChromeView()
                    .blur(radius: detailModalActive ? 24 : 0)
                    .animation(.smooth(duration: 0.25), value: detailModalActive)
                    .ignoresSafeArea(edges: .horizontal)
            }
            .overlay(alignment: .bottomTrailing) {
                if viewModel.progress.isActive {
                    SyncBannerView(progress: viewModel.progress)
                        // Small ambient badge in the bottom-right corner.
                        .transition(.scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity))
                }
            }
            .animation(.smooth, value: viewModel.progress.isActive)
            .overlay(alignment: .bottomLeading) {
                if let profile = activeProfile {
                    ExpiryNotice(profile: profile)
                }
            }
            .onPreferenceChange(DetailModalActiveKey.self) { active in
                detailModalActive = active
            }

        case .failed(let message):
            SyncFailedView(message: message) {
                guard let repository else { return }
                await viewModel.retry(
                    profileId: activeProfileId,
                    repository: repository,
                    container: modelContext.container
                )
            }
        }
    }

}

struct SyncFailedView: View {
    let message: String
    let onRetry: () async -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.red)
            Text("Failed to load content")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await onRetry() }
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            .padding(.top, 8)
        }
        .padding(48)
        .glassCard()
        .padding(64)
    }
}

struct SyncProgressView: View {
    let progress: SyncProgress

    var body: some View {
        VStack(spacing: 28) {
            if case .failed(let message) = progress {
                failureBody(message: message)
            } else {
                progressBody
            }
        }
        .padding(48)
        .glassCard()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HeroGradientBackground())
    }

    private var progressBody: some View {
        VStack(spacing: 28) {
            Image(systemName: progress.step.iconName)
                .font(.system(size: 80))
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.pulse, options: .repeating)
                .contentTransition(.symbolEffect(.replace))

            Text(progress.step.title)
                .font(.title2.weight(.semibold))

            VStack(spacing: 10) {
                ProgressView(value: progress.globalFraction)
                    .progressViewStyle(.linear)
                    .frame(width: 480)
                    .animation(.smooth(duration: 0.35), value: progress.globalFraction)

                Text(progress.globalFraction, format: .percent.precision(.fractionLength(0)))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func failureBody(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 64))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.red)
            Text("Sync failed")
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

struct SyncBannerView: View {
    let progress: SyncProgress

    private var isDone: Bool {
        if case .done = progress { return true }
        return false
    }
    private var percent: Int { Int((progress.globalFraction * 100).rounded()) }

    var body: some View {
        HStack(spacing: 12) {
            // Fixed-size slot so swapping spinner ↔ checkmark doesn't reflow the
            // pill; both crossfade in/out instead of the spinner popping away.
            ZStack {
                if isDone {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                } else {
                    ProgressView()
                        .controlSize(.regular)
                        .transition(.opacity)
                }
            }
            .frame(width: 26, height: 26)

            Text(isDone ? "Done" : "Syncing… \(percent)%")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
                // Plain crossfade: numericText tried to morph "…%" → "Done",
                // which flicked. Opacity handles both the % ticks and the
                // syncing → done swap cleanly.
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .glassCapsule()
        .animation(.smooth(duration: 0.3), value: isDone)
        .animation(.smooth(duration: 0.3), value: percent)
    }
}

/// Brief, non-focusable notice when the active account is expired or expires
/// within a week. Shown once per profile per launch; the details stay in
/// Settings → Account.
private struct ExpiryNotice: View {
    let profile: Profile
    @State private var visible = false

    var body: some View {
        Group {
            if visible {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("\(profile.name): \(ProfileExpiry.summary(for: profile))")
                        .font(.callout)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .glassCapsule()
                .padding(48)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
        .animation(.smooth, value: visible)
        .task(id: "\(profile.id)|\(profile.expiresAt)") {
            guard profile.isExpiringSoon else {
                visible = false
                return
            }
            visible = true
            try? await Task.sleep(for: .seconds(10))
            visible = false
        }
    }
}
