import SwiftUI
import SwiftData

/// Top chrome: app logo (left), profile badge (right). Lays out inline at the
/// top of the root view as a normal row — no overlay, no scrim.
struct TopChromeView: View {
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage("activeProfileId") private var activeProfileId: String = ""
    @Query private var profiles: [Profile]

    private var activeProfile: Profile? {
        profiles.first(where: { $0.id == activeProfileId }) ?? profiles.first
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Wordmark(size: 34)

            Spacer(minLength: 0)

            if let profile = activeProfile {
                ProfileBadge(profile: profile)
            }
        }
        .padding(.horizontal, 56)
        // Nudge the whole chrome row up so the logo + profile pill sit on the
        // same vertical center as the floating nav tab pill (the safe-area-inset
        // overlay otherwise lands a bit below it).
        .offset(y: -8)
    }
}

// MARK: - Profile badge (static chrome)

private struct ProfileBadge: View {
    let profile: Profile

    var body: some View {
        HStack(spacing: 12) {
            Text(profile.name)
                .font(.system(size: 20, design: .rounded).weight(.medium))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)

            ZStack {
                Circle().fill(Color.gray.opacity(0.5))
                Image(systemName: "person.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)
        }
        .padding(.leading, 22)
        // Inset the avatar (and content) so there's a margin around it, and keep
        // total height at 40 + 12 = 52 to match the logo → vertically centered
        // with the nav band.
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        // Translucent + grayish (material tinted with the theme surface token)
        // rather than the plain white material.
        .background {
            Capsule().fill(.ultraThinMaterial)
            Capsule().fill(Color.surfaceTint)
        }
    }
}
