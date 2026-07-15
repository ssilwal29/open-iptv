# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code
in this repository.

## Project Overview

OpenIPTV is a **free, open-source tvOS 26 IPTV client** (Swift 5 / SwiftUI) for the
Xtream Codes Player API. It is a deliberately minimal **bootstrap**: auth, sync,
browse, and playback with no paywall, subscriptions, analytics, or accounts beyond
a single on-device profile.

A single **Profile** (one Xtream account) feeds an on-device library of VOD movies,
TV series, and live channels grouped by category. The app is SwiftData-backed: API
responses are decoded into `Codables/`, then persisted into `@Model` entities so
subsequent launches render instantly from disk and only sync deltas.

## Build & Run

Open `OpenIPTV.xcodeproj` in Xcode and run on a tvOS simulator or Apple TV. There
are no scripts or test targets — development happens through Xcode. Files are added
to the project via explicit references in `project.pbxproj` (no synchronized folder
groups). CI runs `xcodebuild build` on a tvOS simulator (`.github/workflows/ci.yml`).

**Dependency (SPM):** [Nuke / NukeUI](https://github.com/kean/Nuke) for image loading.
That's the only third-party dependency.

## Architecture

### App Entry & State Gate

`OpenIPTVApp` attaches `PersistenceController.shared` as the model container and
renders `RootView`. `RootView` queries `[Profile]`; `isConfigured = !profiles.isEmpty`
gates the app:
- **Not configured** → `SetupView` (credential entry + Xtream auth, persists `Profile`
  + `Server`).
- **Configured** → `ContentView`, which reads `\.iptvRepository` from the environment
  (an `XtreamAPIService` built from the active `Profile`) and runs
  `ContentViewModel.bootstrap(...)` to show the cached library immediately or run an
  initial sync.

### Data Flow

1. `XtreamAPIService` (conforms to `IPTVRepository`) is the only network layer. All
   endpoints are `async throws` over `URLSession`, with HTTPS-first + HTTP fallback
   for self-signed servers and exponential-backoff retry.
2. `PlaylistSyncService` (a `@ModelActor`) orchestrates batch sync: fetches categories
   + content, upserts `CategoryEntity`/`MovieEntity`/`SerieEntity`/`LiveEntity` into
   SwiftData, prunes stale rows, and reports `SyncProgress` back to `ContentViewModel`.
   `Scope` (`.liveOnly` / `.full`) selects how much to sync — Live TV's manual
   "Refresh" uses `.liveOnly`; the initial load and full refreshes use `.full`.
3. Browse views read entirely from SwiftData. They `@Query` `CategoryEntity` filtered
   by `kindRaw` ("movie"/"serie"/"live") and by the active profile.

### SwiftData Layer

- **`Support/PersistenceController.swift`** — `static let shared`, an on-disk
  `ModelContainer` (`cloudKitDatabase: .none` — CloudKit is intentionally off).
- **Schema** — `SchemaV1: VersionedSchema` enumerates `Profile`, `Server`,
  `CategoryEntity`, `MovieEntity`, `SerieEntity`, `SeasonEntity`, `EpisodeEntity`,
  `LiveEntity`, `MovieDetailEntity`, `PlaybackProgress`. **Additive fields must be
  Optional** — a non-optional new attribute crashes lightweight migration on existing
  stores.
- **Credentials:** the Xtream password is stored in the **Keychain** (service
  `io.OpenIPTV.profile.password`, account = `Profile.id`), never in SwiftData. Use
  `Profile.setPassword(_)` / `resolvedPassword()` / `clearPassword()`. See
  `Support/KeychainHelper.swift`.

### Codables vs Models

- `Codables/` — API response shapes (`Movie`, `Serie`, `Live`, `Category`, `Account`,
  plus detail payloads). Decoded per response, then mapped into `@Model` entities.
- `Models/` — SwiftData persistent models.

### ViewModels

All ViewModels are `@MainActor @Observable final class`: `ContentViewModel`,
`MovieDetailViewModel`, `SerieDetailViewModel`, `LiveViewModel`, `SettingsViewModel`,
`SetupViewModel`. Browse views (`MovieView`, `SerieView`, `SearchView`) intentionally
have **no** ViewModel — they `@Query` SwiftData and compute filters inline.

### Search

`SearchView` is a dedicated tab using native tvOS `.searchable`, rendering matches
across `MovieEntity` and `SerieEntity`. Filtering is debounced (min 3 chars, 600 ms).

### Continue Watching

Resume is keyed on `PlaybackProgress` (per profile, per media id). `MovieView` and
`SerieView` each pin a **Continue Watching** rail at the top, sourced only from
progress rows; tapping resumes playback. There is no Watch Later / favorites.

### Video Playback

`VideoPlayerView` → `OpenIPTVPlayer` (`UIViewControllerRepresentable` over
`AVPlayerViewController`), presented as a `.fullScreenCover`. For self-signed servers,
`StreamURLResolver` + `InsecureAssetResourceLoader` broker the connection via a custom
`AVAssetResourceLoaderDelegate` (custom `openiptv://` scheme). Playback is AVPlayer-only.

Stream URLs: `https://{server}/movie/{username}/{password}/{streamId}.{ext}` for
movies; live and episodes are constructed analogously in their detail views.

### Content Filtering

Adult filtering is per-profile via `Profile.hideAdultContent` (default `true`), applied
at view time on `MovieEntity.isAdult`. Series are not adult-filtered (no flag on
`SerieEntity`).

## Key Patterns

- Network calls go through `IPTVRepository` only; views never instantiate
  `XtreamAPIService` directly. It's injected via `\.iptvRepository`.
- All networking and batch persistence is `async/await`. `DispatchQueue` use is
  confined to UIKit/AVFoundation bridging.
- tvOS focus uses `@FocusState`/`.focused()`; `LiveView` uses `.focusSection()` for
  its three-pane layout. The TabView uses `.tabViewStyle(.tabBarOnly)`.
- **`.contextMenu` is unreliable on tvOS** — put secondary actions in explicit
  focusable buttons in the detail/preview surface, never a long-press gesture.
- Shared design tokens live in `GlassStyle.swift` (`Radius`, `Spacing`, `Color`
  theme tokens, `Font` roles, `cardSurface()`, native `glassEffect` wrappers). Brand
  red lives only in `Color.progressFill` (progress bars), never as a global accent.
- Posters render via NukeUI's `LazyImage` inside `MoviePosterTile` / `SeriePosterTile`.
