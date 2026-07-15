import Foundation
import SwiftData

enum SchemaV1: VersionedSchema {
    nonisolated(unsafe) static var versionIdentifier = Schema.Version(1, 6, 0)

    nonisolated(unsafe) static var models: [any PersistentModel.Type] = [
        Profile.self,
        Server.self,
        CategoryEntity.self,
        MovieEntity.self,
        SerieEntity.self,
        SeasonEntity.self,
        EpisodeEntity.self,
        LiveEntity.self,
        MovieDetailEntity.self,
        PlaybackProgress.self
    ]
}

// Schema 1.1.0 (multi-profile foundation): added optional `profile` relationship
// to CategoryEntity / MovieEntity / SerieEntity / LiveEntity, added `name` field
// to Profile (defaults to username), and dropped @Attribute(.unique) on the
// per-server stream/series/composite IDs (uniqueness is now enforced by the
// sync engine's profile-scoped fetch). Lightweight migration covers the schema
// shape; the post-launch backfill in RootView populates missing relationships
// for legacy single-profile installs.
enum OpenIPTVMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] = [SchemaV1.self]
    static var stages: [MigrationStage] = []
}

enum PersistenceController {
    @MainActor
    static let shared: ModelContainer = {
        let schema = Schema(versionedSchema: SchemaV1.self)
        let config = ModelConfiguration(
            "OpenIPTV",
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        do {
            return try ModelContainer(
                for: schema,
                migrationPlan: OpenIPTVMigrationPlan.self,
                configurations: [config]
            )
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    @MainActor
    static let preview: ModelContainer = {
        let schema = Schema(versionedSchema: SchemaV1.self)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create preview ModelContainer: \(error)")
        }
    }()

    /// One-shot cleanup of rows orphaned by an earlier broken profile removal
    /// (where the profile was deleted but its categories/movies/series/lives
    /// were left behind with `profile == nil`). Without this, a re-sign-in
    /// with the same Xtream credentials hits a unique-constraint clash on
    /// `MovieDetailEntity.streamId` that surfaces as a "failed to read from
    /// datastore" crash on detail load.
    ///
    /// Idempotent and fast — after the first run the predicates match
    /// nothing and each `delete(model:where:)` is a near-free SQL no-op, so
    /// it's safe to call from `bootstrap` on every cold launch / profile
    /// switch.
    static func cleanupOrphans(in context: ModelContext) {
        do {
            // Step 1: delete direct-profile entities whose profile is gone.
            // SwiftData's #Predicate macro doesn't support multi-hop optional
            // chains (e.g. `$0.season?.serie?.profile == nil` lowers to a
            // TERNARY that can't be further composed), so we keep predicates
            // single-level and chain them via the deletion order instead.
            try context.delete(
                model: MovieEntity.self,
                where: #Predicate { $0.profile == nil }
            )
            try context.delete(
                model: SerieEntity.self,
                where: #Predicate { $0.profile == nil }
            )
            try context.delete(
                model: LiveEntity.self,
                where: #Predicate { $0.profile == nil }
            )
            try context.delete(
                model: CategoryEntity.self,
                where: #Predicate { $0.profile == nil }
            )
            // Step 2: sweep leaves whose parent is now nil. After the bulk
            // deletes above, SwiftData nullifies dangling back-references on
            // surviving rows; cascade rules cover the rest. Either way, any
            // remaining row here is a true orphan and safe to drop.
            try context.delete(
                model: MovieDetailEntity.self,
                where: #Predicate { $0.movie == nil }
            )
            try context.delete(
                model: SeasonEntity.self,
                where: #Predicate { $0.serie == nil }
            )
            try context.delete(
                model: EpisodeEntity.self,
                where: #Predicate { $0.season == nil }
            )
            try context.save()
        } catch {
            // Non-fatal — sync still proceeds. Worst case: same crash on
            // detail load, which the user can escape by reinstalling.
        }
    }
}
