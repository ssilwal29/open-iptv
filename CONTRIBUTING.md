# Contributing to OpenIPTV

Thanks for your interest! OpenIPTV is a bootstrap meant to be built on, so
contributions are very welcome. A few ground rules keep the codebase coherent.

## Before you open a PR

- **One concern per PR.** If you're refactoring and adding a feature, split them.
- **Match existing style.** Apple's Swift API Design Guidelines, `@Observable` for
  view models, `@Query` for reads, `async/await` for all networking.
- **No dead code or commented-out blocks.** If it's worth keeping, wrap it in a
  feature flag. Otherwise delete it.
- **No force unwraps** outside of unambiguously safe `fatalError` cases
  (preview-bundle loading, app schema init).
- **`os.Logger` instead of `print`.** Subsystem `com.openiptv.app`, category
  per-file.
- **Additive SwiftData fields must be Optional.** A non-optional new attribute
  crashes lightweight migration on existing stores.

## Things we do **not** accept

- Bundled playlists, hardcoded credentials, stream URLs, or provider domains
- ATS exceptions for specific hosts (the global `NSAllowsArbitraryLoadsForMedia`
  is enough — we do not endorse specific providers)
- Telemetry, analytics, or ad SDKs
- Paywalls, subscriptions, or any gating of features
- Cloud-sync of credentials / CloudKit (intentionally off; the password lives in
  the Keychain, on-device only)

## Local setup

```
git clone <your fork>
cd OpenIPTV
open OpenIPTV.xcodeproj
```

Build against a tvOS 26 simulator. There are no scripts or generators — files are
added to the project via explicit references in `project.pbxproj`.

## Submitting

1. Fork → feature branch → PR against `main`
2. Describe the user-visible change in the PR body
3. Include before/after screenshots for UI changes
4. CI must be green (runs `xcodebuild build` on tvOS)

## Questions

Open a GitHub discussion. Please do **not** ask where to find playlists — that's
out of scope for this project.
