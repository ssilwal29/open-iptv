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
}
