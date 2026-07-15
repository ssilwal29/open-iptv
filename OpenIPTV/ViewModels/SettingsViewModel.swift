import Foundation
import SwiftData

@MainActor
@Observable
final class SettingsViewModel {
    var isRefreshing = false
    var refreshMessage: String?
    var progress: SyncProgress = .idle

    func refresh(
        profileId: String,
        repository: any IPTVRepository,
        container: ModelContainer
    ) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshMessage = nil
        defer { isRefreshing = false }

        let service = PlaylistSyncService(modelContainer: container)
        let result = await service.refreshIfNeeded(
            trigger: .manual,
            scope: .full,
            profileId: profileId,
            repository: repository,
            progress: { [weak self] step in
                Task { @MainActor [weak self] in self?.progress = step }
            }
        )

        switch result {
        case .upToDate:
            refreshMessage = "Already up to date"
        case .synced(let stats):
            let mins = stats.duration.map { String(format: "%.1fs", $0) } ?? "?"
            refreshMessage = "Synced \(stats.totalMovies + stats.totalSeries + stats.totalLives) items in \(mins) · pruned \(stats.pruned)"
        case .failed(let message):
            refreshMessage = "Failed: \(message)"
        }
    }

    func setSyncInterval(_ days: Int, profile: Profile, context: ModelContext) {
        profile.syncIntervalDays = days
        DeferredSave.schedule(context)
    }

    func setHideAdultContent(_ hide: Bool, profile: Profile, context: ModelContext) {
        profile.hideAdultContent = hide
        DeferredSave.schedule(context)
    }
}
