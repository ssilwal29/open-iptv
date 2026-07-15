import SwiftUI
import SwiftData

@main
struct OpenIPTVApp: App {
    @State private var showSplash = true

    init() {
        ImagePipelineConfiguration.apply()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()

                if showSplash {
                    SplashScreenView()
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .task {
                // Hold the splash long enough that the logo is *guaranteed*
                // visible at full opacity, even on fast devices. The entry
                // fade is ~0.45s, so a 2.5s hold leaves ~2s of "logo fully
                // settled" before the 0.5s fade-out begins. Total perceived
                // duration: ~3s.
                try? await Task.sleep(for: .seconds(2.5))
                withAnimation(.smooth(duration: 0.5)) {
                    showSplash = false
                }
            }
        }
        .modelContainer(PersistenceController.shared)
    }
}

private struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [Profile]

    @AppStorage("activeProfileId") private var activeProfileId: String = ""

    @State private var repository: XtreamAPIService?

    private var isConfigured: Bool { !profiles.isEmpty }

    /// The Profile currently in use. Resolves `activeProfileId` to a Profile;
    /// falls back to the first profile when the stored id is empty (fresh
    /// install or legacy single-profile build) or stale (active profile was
    /// removed elsewhere). Returns nil when no profiles exist at all.
    private var activeProfile: Profile? {
        if !activeProfileId.isEmpty,
           let match = profiles.first(where: { $0.id == activeProfileId }) {
            return match
        }
        return profiles.first
    }

    var body: some View {
        ContentView(isConfigured: Binding(
            get: { isConfigured },
            set: { _ in }
        ))
        .environment(\.iptvRepository, repository)
        // Root-level AmbientBackdrop fills the entire window — including the
        // tvOS safe-area overscan margin — so the orange/purple gradient looks
        // continuous from edge to edge. Individual tab views still apply their
        // own AmbientBackdrop for preview-time correctness; both are identical
        // so layering them is visually invisible.
        .background(AmbientBackdrop())
        .task(id: activeProfile?.id) {
            seedActiveProfileIfNeeded()
            backfillLegacyProfileRelationships()
            refreshRepository()
        }
        .onChange(of: activeProfile?.serverURL) { _, _ in
            refreshRepository()
        }
        .onChange(of: activeProfile?.username) { _, _ in
            refreshRepository()
        }
    }

    private func refreshRepository() {
        if let profile = activeProfile {
            let credentials = XtreamCredentials(
                serverURL: profile.serverURL,
                username: profile.username,
                password: profile.resolvedPassword()
            )
            repository = XtreamAPIService(credentials: credentials)
        } else {
            repository = nil
        }
    }

    /// On first launch of the multi-profile build, `activeProfileId` is empty.
    /// Seed it with the existing profile's id so the rest of the app (tab
    /// @Query predicates, ProfilePicker, etc.) lands on a valid selection.
    private func seedActiveProfileIfNeeded() {
        if activeProfileId.isEmpty, let first = profiles.first {
            activeProfileId = first.id
        }
        // If the active id points at a profile that no longer exists (it was
        // removed elsewhere), fall back to the first profile.
        if !activeProfileId.isEmpty,
           profiles.contains(where: { $0.id == activeProfileId }) == false,
           let fallback = profiles.first {
            activeProfileId = fallback.id
        }
    }

    /// One-shot legacy-data migration: with schema 1.1.0 every content entity
    /// gained an optional `profile` relationship. Existing rows from the
    /// single-profile build come across with `profile == nil`. If exactly one
    /// profile exists (the legacy singleton), assume all orphans belong to it
    /// and backfill. No-op once migrated, no-op when the user has multiple
    /// profiles (legacy backfill is ambiguous in that case — we leave it).
    private func backfillLegacyProfileRelationships() {
        guard profiles.count == 1, let owner = profiles.first else { return }

        let categories = (try? modelContext.fetch(
            FetchDescriptor<CategoryEntity>(predicate: #Predicate { $0.profile == nil })
        )) ?? []
        let movies = (try? modelContext.fetch(
            FetchDescriptor<MovieEntity>(predicate: #Predicate { $0.profile == nil })
        )) ?? []
        let series = (try? modelContext.fetch(
            FetchDescriptor<SerieEntity>(predicate: #Predicate { $0.profile == nil })
        )) ?? []
        let lives = (try? modelContext.fetch(
            FetchDescriptor<LiveEntity>(predicate: #Predicate { $0.profile == nil })
        )) ?? []

        guard !(categories.isEmpty && movies.isEmpty && series.isEmpty && lives.isEmpty) else {
            return
        }

        for c in categories { c.profile = owner }
        for m in movies    { m.profile = owner }
        for s in series    { s.profile = owner }
        for l in lives     { l.profile = owner }

        try? modelContext.save()
    }
}
