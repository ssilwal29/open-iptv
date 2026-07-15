import Foundation
import SwiftData

@MainActor
@Observable
final class SetupViewModel {
    var isLoading = false
    var errorMessage: String?

    /// Authenticates against the Xtream server, then upserts a Profile.
    /// - When `profileId` is nil → creates a new Profile (Add Profile flow).
    /// - When `profileId` is provided AND that profile exists → updates it
    ///   in-place (Edit Credentials flow).
    /// Returns the persisted Profile's id on success so the caller can set it
    /// as the active profile, or nil on failure.
    func authenticate(
        serverURL: String,
        username: String,
        password: String,
        name: String? = nil,
        profileId: String? = nil,
        modelContext: ModelContext
    ) async -> String? {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let account = try await XtreamAPIService.authenticate(
                serverURL: serverURL,
                username: username,
                password: password
            )
            let saved = try modelContext.saveProfile(
                from: account,
                serverURL: serverURL,
                name: name,
                profileId: profileId
            )
            return saved.id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
