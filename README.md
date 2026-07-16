# OpenIPTV

<p align="center">
  <img src="docs/open-iptv-cta.png" alt="OpenIPTV — a free, open-source tvOS IPTV client" width="820">
</p>

A free, open-source, native **tvOS 26** IPTV client for Apple TV. Bring your own
Xtream Codes account and watch your movies, TV series, and live channels with a
native SwiftUI interface.

> ⚠️ OpenIPTV **does not** ship any playlist, stream, or content, and has no
> affiliation with any provider. You supply your own Xtream Codes credentials.
> Use only with services you are legally entitled to access.

This project is a **bootstrap** — a clean, minimal foundation meant to be built on.
It ships the core of an IPTV client (auth, sync, browse, playback) with no paywall,
no subscriptions, and no tracking, so contributors can add features on top of a
solid base. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Features

- **Native SwiftUI tvOS 26 UI** — focus-aware posters, native Liquid Glass materials
- **Movies, TV Series (seasons + episodes), and Live TV**
- **Search** across your movie and series library
- **Continue Watching** — resume movies and episodes where you left off
- **Local SwiftData cache** — the catalog is persisted on-device; first launch does
  the download, every subsequent launch renders instantly and only syncs deltas
- **Configurable sync** — automatic refresh (1/3/7/14 days or manual), with
  prune-on-refresh so titles removed by your provider disappear from the app
- **Settings** — edit credentials, sign out, pick sync interval, hide adult content
- **Resilient networking** — exponential-backoff retry, and HTTPS → HTTP fallback
  plus a custom resource loader for providers with self-signed certificates

## Requirements

- Xcode 17+
- tvOS 26.0 or later
- Swift 5 (SwiftUI, SwiftData)

## Getting started

1. Clone the repo
2. Open `OpenIPTV.xcodeproj` in Xcode
3. Select an Apple TV simulator or device
4. Build + run (`⌘R`)
5. On first launch, enter your Xtream server URL (e.g. `example.com`), username,
   and password

The one dependency ([Nuke](https://github.com/kean/Nuke), for image loading) is
resolved automatically by Swift Package Manager — no extra setup.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ SwiftUI Views (@Query-driven)                                │
│   MovieView / SerieView / LiveView / SearchView / Settings   │
└────────────────┬─────────────────────────────────────────────┘
                 │ @Observable @MainActor ViewModels
                 ▼
┌─────────────────────────────────────────────────────────────┐
│ PlaylistSyncService (@ModelActor)                            │
│   ├─ fetch categories + content via the repository           │
│   ├─ chunked upsert into SwiftData                           │
│   └─ prune-on-refresh (rows the provider dropped)            │
└────────────────┬─────────────────────────────────────────────┘
                 │
         ┌───────┴───────┐
         ▼               ▼
┌────────────────┐  ┌─────────────────────────────────────────┐
│ XtreamAPI      │  │ SwiftData on disk                        │
│  (retry +      │  │   Profile · CategoryEntity               │
│  https→http    │  │   MovieEntity · MovieDetailEntity        │
│  fallback)     │  │   SerieEntity · SeasonEntity             │
└────────────────┘  │   EpisodeEntity · LiveEntity             │
                    │   PlaybackProgress                       │
                    └─────────────────────────────────────────┘
```

**Key design points:**
- UI reads directly from SwiftData via `@Query` — no in-memory mirror
- Network calls go through the `IPTVRepository` protocol (injected via the
  environment); views never instantiate the API service directly
- Writes happen on the `@ModelActor`'s isolated context, never the main context
- Detail data (`MovieDetailEntity`, seasons, episodes) is lazy-fetched on first
  open and cached for 30 days
- The Xtream **password is stored in the Keychain**, never in SwiftData

## Project layout

```
OpenIPTV/
├─ Codables/          # API response shapes (Movie, Serie, Live, Category, Account)
├─ Models/            # SwiftData entities (MovieEntity, CategoryEntity, …)
├─ ViewModels/        # @Observable @MainActor view models
├─ Services/          # IPTVRepository + XtreamAPIService + PlaylistSyncService
├─ Support/           # PersistenceController, Keychain, ModelContext extensions
├─ Video Player/      # AVPlayerViewController bridge + self-signed stream loader
└─ *.swift            # Top-level views + shared design tokens (GlassStyle.swift)
```

## Contributing

Pull requests welcome — this repo exists to be extended. See
[CONTRIBUTING.md](CONTRIBUTING.md) for code style and the review flow.

## License

[MIT](LICENSE)
