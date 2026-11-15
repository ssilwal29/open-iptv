# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code
in this repository.

## Project Overview

OpenIPTV is a **free, open-source tvOS 26 IPTV client** (Swift 5 / SwiftUI) for the
Xtream Codes Player API. It is a deliberately minimal **bootstrap**: auth, sync,
browse, and playback with no paywall, subscriptions, analytics, or accounts beyond
a single on-device profile.

Each **Profile** (one Xtream account; several can be added and switched in
Settings) feeds an on-device library of VOD movies, TV series, and live channels
grouped by category. The app is SwiftData-backed: API
responses are decoded into `Codables/`, then persisted into `@Model` entities so
subsequent launches render instantly from disk and only sync deltas.

## Build & Run

Open `OpenIPTV.xcodeproj` in Xcode and run on a tvOS simulator or Apple TV. Files
are added to the project via explicit references in `project.pbxproj` (no
synchronized folder groups). CI (`.github/workflows/ci.yml`) runs `xcodebuild build`
and then `xcodebuild test` on a tvOS simulator.

Targets:
- **OpenIPTV** — the app.
- **OpenIPTVTopShelf** — TV Services extension (Top Shelf "Continue Watching"),
  embedded in the app. Shares `Support/TopShelfShared.swift` with the app and reads a
  JSON snapshot from the `group.io.OpenIPTV` App Group (both targets carry that
  entitlement; unsigned builds just skip Top Shelf).
- **OpenIPTVTests** — Swift Testing unit tests hosted in the app (`@testable import
  OpenIPTV`). Run with ⌘U.

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
  stores. 1.7.0 added `Profile.favoriteLiveStreamIds: [Int]?`.
- **Credentials:** the Xtream password is stored in the **Keychain** (service
  `io.OpenIPTV.profile.password`, account = `Profile.id`), never in SwiftData. Use
  `Profile.setPassword(_)` / `resolvedPassword()` / `clearPassword()`. See
  `Support/KeychainHelper.swift`. The optional parental PIN is also Keychain-only
  (service `io.OpenIPTV.profile.parentalPIN`).
- **Removing a profile** goes through `ModelContext.removeProfile(_:)`, which deletes
  its progress rows and Keychain secrets and sweeps orphans *immediately* — orphans
  left behind would be adopted by `RootView`'s legacy backfill when one profile
  remains.

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
across `MovieEntity`, `SerieEntity` and `LiveEntity` (channels play full screen).
Filtering is debounced (min 3 chars, 600 ms) and done in the SwiftData predicate.

### Continue Watching

Resume is keyed on `PlaybackProgress` (per profile, per media id). `MovieView` and
`SerieView` each pin a **Continue Watching** rail at the top, sourced only from
progress rows; tapping resumes playback. `TopShelfPublisher` mirrors the active
profile's rows to the Top Shelf snapshot after playback and on profile changes;
tiles deep-link back via `openiptvapp://` (`TopShelfLink`, handled in
`ContentView`). There is no Watch Later; **favorites exist for live channels only**
(`Profile.favoriteLiveStreamIds`, a "Favorites" entry in the Live TV sidebar).

### Live TV guide & catch-up

`EPGCache` (actor) fetches `get_short_epg` per channel on demand — channel rows
(debounced, only for channels with an `epgChannelId`) and the preview pane's
now/next. It's in-memory only, TTL'd, coalesces requests and caps concurrency.
Catch-up (`CatchupView`, channels with `tv_archive == 1`) lists
`get_simple_data_table` programmes with `has_archive` and plays them via
`/timeshift/{user}/{pass}/{minutes}/{yyyy-MM-dd:HH-mm}/{id}.m3u8`, using the panel's
server-local start string verbatim.

**AI guide formatting (optional, off by default).** `EPGFormatter` (`@MainActor
@Observable` singleton) tidies guide text through OpenRouter (`OpenRouterClient`,
default model `google/gemini-3.8-flash`, strict JSON-schema output with a no-schema
retry on HTTP 400). Views call `request(_:)` for listings they show and render
`display(for:)` (raw text until the formatted version arrives). Requests are
debounced into batches of 25 (≤2 in flight), deduplicated by a SHA-256 of the text
(`EPGFormatterPrompt.cacheKey`, includes a prompt `version`), and cached on disk in
Caches. Fatal errors (bad key, no credits, unknown model), 3 consecutive failures, or
the per-session cap (`sessionLimit`) pause it until `resume()`/a settings change.
Only programme titles/descriptions are sent — never credentials or stream URLs. The
API key is Keychain-only (service `io.OpenIPTV.openrouter`); enable flag and model
live in UserDefaults (`epgAI.*`). Settings → Guide (AI) holds the controls and
status; `EPGFormattingStatus` is the progress pill in Live TV and Catch-up.
`OpenRouterClient` is the only network call outside `IPTVRepository`.

### Video Playback

VOD covers present `PlaybackScreen(playback:)` (a `ResolvedPlayback` with Info-panel
`PlaybackMetadata` and an optional `UpNext`). When an episode ends, `PlaybackScreen`
swaps the player for a focusable SwiftUI "Up Next" screen (not an overlay — the
player view controller would keep focus). Episode requests are built by
`EpisodePlayback`. Live full screen uses `LiveFullscreenPlayer`, which adds
Previous/Next Channel to the transport bar (`transportBarCustomMenuItems`).
Underneath, `VideoPlayerView` → `OpenIPTVPlayer` (`UIViewControllerRepresentable`
over `AVPlayerViewController`). Screensaver suppression is reference-counted via
`IdleTimerGuard`. For self-signed servers,
`StreamURLResolver` + `InsecureAssetResourceLoader` broker the connection via a custom
`AVAssetResourceLoaderDelegate` (custom `openiptv://` scheme). Playback is AVPlayer-only.

Stream URLs: `https://{server}/movie/{username}/{password}/{streamId}.{ext}` for
movies; live and episodes are constructed analogously in their detail views.

### Content Filtering

Adult filtering is per-profile via `Profile.hideAdultContent` (default `true`),
applied in the SwiftData predicates on `MovieEntity.isAdult` and `LiveEntity.adult`
(`"1"`). Series are not adult-filtered (no flag on `SerieEntity`). An optional
4-digit parental PIN (Settings → Content) is required to turn the filter off.

### Localization

`Text("literal")` is localizable by default. Strings built outside views (errors,
sync status, expiry text) use `String(localized:)`. `Localizable.xcstrings` is the
catalog; Xcode fills it on build. No translations ship yet.

## Key Patterns

- Xtream network calls go through `IPTVRepository` only; views never instantiate
  `XtreamAPIService` directly. It's injected via `\.iptvRepository`. The one other
  network client is `OpenRouterClient`, used only by `EPGFormatter`.
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
