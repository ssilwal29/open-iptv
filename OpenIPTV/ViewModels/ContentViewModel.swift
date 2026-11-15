import Foundation
import SwiftData

@MainActor
@Observable
final class ContentViewModel {
    enum Phase: Equatable {
        case idle
        case initialSync
        case ready
        case failed(String)
    }

    var phase: Phase = .idle
    var progress: SyncProgress = .idle
    private(set) var lastStats: SyncStats?
    private var lastBootstrappedProfileId: String?

    func bootstrap(
        hasCachedPlaylist: Bool,
        profileId: String,
        repository: any IPTVRepository,
        container: ModelContainer,
        context: ModelContext
    ) async {
        // Re-bootstrap when the active profile changes — `bootstrapped` is
        // tracked per-profile via `lastBootstrappedProfileId`.
        guard lastBootstrappedProfileId != profileId else { return }
        lastBootstrappedProfileId = profileId

        let scope: PlaylistSyncService.Scope = .full

        // One-shot zombie sweep before sync runs — handles rows orphaned by
        // an earlier broken profile removal that would otherwise crash detail
        // loads via `MovieDetailEntity.streamId` unique-constraint clashes.
        // Idempotent: a clean store sees no matching rows and this is free.
        PersistenceController.cleanupOrphans(in: context)

        // Refresh status / expiry in the background so Settings and the
        // expiry notice reflect today's state, not the day the account was added.
        Task {
            guard let account = try? await repository.fetchAccount() else { return }
            context.updateAccountInfo(profileId: profileId, from: account)
        }

        if hasCachedPlaylist {
            // Existing profile with cache — show tabs immediately, refresh
            // anything stale in the background.
            phase = .ready
            await refresh(trigger: .stale, scope: scope, profileId: profileId, repository: repository, container: container)
        } else if phase == .ready {
            // The user is already in the app (another profile was loaded) and
            // is now switching to / adding a new empty profile. Stay on .ready
            // so the existing tabs remain mounted; the top SyncBannerView will
            // surface progress as the cold sync chunks arrive. Without this,
            // the entire UI gets replaced by the full-screen SyncProgressView
            // for the duration of the new profile's first sync.
            await refresh(trigger: .cold, scope: scope, profileId: profileId, repository: repository, container: container)
        } else {
            // True first launch — no other profile to fall back to. Use the
            // full-screen progress view.
            phase = .initialSync
            await refresh(trigger: .cold, scope: scope, profileId: profileId, repository: repository, container: container)
        }
    }

    /// Retries a failed initial sync. `bootstrap` guards against re-entry per
    /// profile, so the dead-end `.failed` state needs its own path back into a
    /// cold sync.
    func retry(
        profileId: String,
        repository: any IPTVRepository,
        container: ModelContainer
    ) async {
        phase = .initialSync
        progress = .idle
        await refresh(trigger: .cold, scope: .full, profileId: profileId, repository: repository, container: container)
    }

    func refresh(
        trigger: PlaylistSyncService.Trigger,
        scope: PlaylistSyncService.Scope,
        profileId: String,
        repository: any IPTVRepository,
        container: ModelContainer
    ) async {
        let service = PlaylistSyncService(modelContainer: container)
        let result = await service.refreshIfNeeded(
            trigger: trigger,
            scope: scope,
            profileId: profileId,
            repository: repository,
            progress: { [weak self] step in
                Task { @MainActor [weak self] in self?.progress = step }
            }
        )

        switch result {
        case .upToDate:
            phase = .ready
        case .synced(let stats):
            lastStats = stats
            phase = .ready
            // Hold the "Library updated" banner briefly, then fade it out.
            progress = .done(stats)
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                if case .done = progress { progress = .idle }
            }
        case .failed(let message):
            if phase == .initialSync {
                phase = .failed(message)
            } else {
                progress = .failed(message)
            }
        }
    }
}
