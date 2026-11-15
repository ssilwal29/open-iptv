import Foundation
import SwiftData

extension ModelContext {
    @MainActor
    func loadAllProfiles() -> [Profile] {
        let descriptor = FetchDescriptor<Profile>()
        return (try? fetch(descriptor)) ?? []
    }

    @MainActor
    func loadProfile(id: String) -> Profile? {
        let descriptor = FetchDescriptor<Profile>(predicate: #Predicate { $0.id == id })
        return (try? fetch(descriptor))?.first
    }

    @MainActor
    func loadCredentials(for profileId: String) -> XtreamCredentials? {
        guard let profile = loadProfile(id: profileId) else { return nil }
        return XtreamCredentials(
            serverURL: profile.serverURL,
            username: profile.username,
            password: profile.resolvedPassword()
        )
    }

    /// Upserts a Profile from an authenticated Xtream account.
    /// - If `profileId` is provided AND that profile exists, updates it in-place
    ///   (used by Edit Credentials).
    /// - Otherwise creates a new Profile with a fresh UUID (used by Add Profile
    ///   / first-run setup).
    /// Returns the persisted Profile so the caller can seed `activeProfileId`.
    @MainActor
    @discardableResult
    func saveProfile(
        from account: Account,
        serverURL: String,
        name: String? = nil,
        profileId: String? = nil
    ) throws -> Profile {
        // Optional user-chosen display name; blank falls back to the username.
        let trimmedName = name?.trimmingCharacters(in: .whitespaces) ?? ""
        let resolvedName = trimmedName.isEmpty ? account.info.username : trimmedName

        if let id = profileId, let existing = loadProfile(id: id) {
            existing.username = account.info.username
            existing.name = resolvedName
            existing.setPassword(account.info.password)
            existing.status = account.info.status
            existing.maxConnections = account.info.maxConnections
            existing.createdAt = account.info.createdAt
            existing.expiresAt = account.info.expiresAt
            existing.isAuth = true
            existing.serverPort = account.serverInfo.port
            existing.serverHttpsPort = account.serverInfo.httpsPort
            existing.serverProtocol = account.serverInfo.serverProtocol
            if existing.serverURL != serverURL {
                existing.serverURL = serverURL
                existing.lastSyncedAt = nil
            } else {
                existing.serverURL = serverURL
            }
            try save()
            return existing
        } else {
            let profile = Profile(
                name: resolvedName,
                username: account.info.username,
                password: "",
                status: account.info.status,
                maxConnections: account.info.maxConnections,
                createdAt: account.info.createdAt,
                expiresAt: account.info.expiresAt,
                isAuth: true,
                serverURL: serverURL,
                serverPort: account.serverInfo.port,
                serverHttpsPort: account.serverInfo.httpsPort,
                serverProtocol: account.serverInfo.serverProtocol
            )
            insert(profile)
            profile.setPassword(account.info.password)
            try save()
            return profile
        }
    }

    /// Refreshes status / expiry / connection limit from a fresh account
    /// payload (fetched on launch), so Settings doesn't show the values from
    /// the day the account was added.
    @MainActor
    func updateAccountInfo(profileId: String, from account: Account) {
        guard account.info.isAuthenticated, let profile = loadProfile(id: profileId) else { return }
        var changed = false
        if profile.status != account.info.status { profile.status = account.info.status; changed = true }
        if profile.expiresAt != account.info.expiresAt { profile.expiresAt = account.info.expiresAt; changed = true }
        if profile.maxConnections != account.info.maxConnections {
            profile.maxConnections = account.info.maxConnections
            changed = true
        }
        if changed { try? save() }
    }

    /// Removes a profile, its resume points and its Keychain secrets. Run
    /// `ProfileContentRemover.deleteContent(profileId:)` first to delete the
    /// catalog rows. Orphans are swept immediately — if they were left for the
    /// next launch, RootView's legacy backfill would hand them to the
    /// remaining profile when only one is left.
    @MainActor
    func removeProfile(_ profile: Profile) {
        let profileId = profile.id
        let progress = (try? fetch(FetchDescriptor<PlaybackProgress>(
            predicate: #Predicate { $0.profile?.id == profileId }
        ))) ?? []
        for row in progress { delete(row) }

        profile.clearPassword()
        profile.clearParentalPIN()
        delete(profile)
        try? save()
        PersistenceController.cleanupOrphans(in: self)
    }
}

/// Deletes a profile's synced catalog off the main actor. Rows are fetched by
/// profile id and deleted individually (like `PlaylistSyncService.pruneOrphans`)
/// so cascade rules remove movie details, seasons and episodes too. Content
/// relationships to `Profile` have no declared inverse, so they can't be relied
/// on to become nil when the profile itself is deleted.
@ModelActor
actor ProfileContentRemover {
    func deleteContent(profileId: String) {
        do {
            for live in try modelContext.fetch(FetchDescriptor<LiveEntity>(
                predicate: #Predicate { $0.profile?.id == profileId }
            )) { modelContext.delete(live) }
            for movie in try modelContext.fetch(FetchDescriptor<MovieEntity>(
                predicate: #Predicate { $0.profile?.id == profileId }
            )) { modelContext.delete(movie) }
            for serie in try modelContext.fetch(FetchDescriptor<SerieEntity>(
                predicate: #Predicate { $0.profile?.id == profileId }
            )) { modelContext.delete(serie) }
            for category in try modelContext.fetch(FetchDescriptor<CategoryEntity>(
                predicate: #Predicate { $0.profile?.id == profileId }
            )) { modelContext.delete(category) }
            try modelContext.save()
        } catch {
            // Non-fatal: `removeProfile` + `cleanupOrphans` still run, and the
            // next bootstrap sweeps anything left without a profile.
        }
    }
}
