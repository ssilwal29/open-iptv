import SwiftUI
import UIKit
import NukeUI

/// Shared corner-radius tokens. Replaces the per-file `*Design.panelCornerRadius`
/// / `cardCornerRadius` / `rowCornerRadius` copies that had drifted (glassCard
/// used 24 while panels used 26).
enum Radius {
    static let panel: CGFloat = 26
    static let card: CGFloat = 22
    static let row: CGFloat = 18
}

/// Shared spacing tokens (previously duplicated as `panelSpacing` / `contentPadding`).
enum Spacing {
    static let panel: CGFloat = 24
    static let content: CGFloat = 28
}

/// Shared poster grid geometry for Movie and Series tiles (previously duplicated
/// as identical `MoviePosterSize` / `SeriePosterSize` enums).
enum PosterSize {
    static let width: CGFloat = 260
    static let height: CGFloat = 390
    static let rowSpacing: CGFloat = 28
    static let catalogSpacing: CGFloat = 48
    /// Fixed column count for full-width grids (e.g. Search). The Movie/Series
    /// category grids use an adaptive column count instead, since their content
    /// pane is narrowed by the category sidebar.
    static let gridColumnCount: Int = 6
}

/// Geometry for the pinned-rail cards (Watch Later, and Continue Watching
/// later): the portrait catalog tile rotated to landscape — same footprint,
/// ~3:2. Shorter than the tall portrait tiles so two rails stack on screen.
enum MediaCardSize {
    static let width: CGFloat = PosterSize.height   // 390
    static let height: CGFloat = PosterSize.width   // 260
    static let spacing: CGFloat = PosterSize.rowSpacing
}

extension Color {
    /// Vivid brand red for playback-progress fills. Deliberately a standalone
    /// token, NOT the global accent: `AccentColor` is intentionally left as the
    /// neutral `secondaryLabelColor` gray. A colored (red) global accent was
    /// tried and reverted — it turned every `.glassProminent` CTA and the
    /// selected filter chip red, which looked wrong. Use this only for progress
    /// bars / brand marks, never as an app-wide tint.
    static let progressFill = Color(red: 0.85, green: 0.12, blue: 0.14)

    // MARK: Theme tokens (adaptive light/dark)
    //
    // Resolve per scheme automatically via a UIColor trait provider. Light
    // values keep the existing system-label look; dark values follow a standard
    // elevated-surface dark theme — off-white text (not pure white) and a
    // lightening surface tint so cards sit ABOVE the near-black canvas.

    /// Primary text — off-white in dark (softer than pure white), `.label` in light.
    static let textPrimary = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.92) : .label
    })
    /// Secondary text.
    static let textSecondary = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.60) : .secondaryLabel
    })
    /// Hairline border used to define card edges.
    static let hairline = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.12) : UIColor(white: 0, alpha: 0.08)
    })
    /// Tint layered over a card's material: lightens in dark (elevation),
    /// darkens slightly in light. Drives `cardSurface`.
    static let surfaceTint = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.07) : UIColor(white: 0.5, alpha: 0.20)
    })
}

// MARK: - Card surface

/// Standard elevated card/panel surface: translucent material + a scheme-aware
/// tint (lightens in dark so it reads above the near-black canvas, darkens in
/// light) + a hairline border for definition. Replaces the old per-site
/// `.thinMaterial` + `Color.gray.opacity(colorScheme …)` fills that vanished
/// against the dark background.
struct CardSurface: ViewModifier {
    var cornerRadius: CGFloat = Radius.panel

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                shape.fill(.thinMaterial)
                shape.fill(Color.surfaceTint)
            }
            .overlay(shape.strokeBorder(Color.hairline, lineWidth: 1))
            .clipShape(shape)
    }
}

extension View {
    func cardSurface(cornerRadius: CGFloat = Radius.panel) -> some View {
        modifier(CardSurface(cornerRadius: cornerRadius))
    }
}

/// Thin resume-progress bar over a dark scrim, pinned to the bottom edge of an
/// artwork tile. Width-agnostic. Drop into `.overlay(alignment: .bottom)` on any
/// poster/thumbnail (add it before `.clipShape` so it follows the rounded corners).
struct ResumeProgressBar: View {
    let fraction: Double

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                .frame(height: 40)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.3))
                    Rectangle().fill(Color.progressFill)
                        .frame(width: geo.size.width * clamped)
                }
            }
            .frame(height: 6)
        }
    }
}

// MARK: - Landscape media card (pinned rails)

/// Landscape poster card. The portrait artwork fills the frame anchored to the
/// TOP (the poster's own title/credits at the bottom crop away), under a black
/// bottom-up gradient that carries our own title and an optional length caption.
/// A thin progress bar pins to the bottom edge when `progress` is supplied.
///
/// Presentational only — the caller wraps it in `NavigationLink` +
/// `.buttonStyle(.card)` for tvOS focus lift and navigation (as `MoviePosterTile`).
struct MediaLandscapeCard: View {
    let imageURL: URL?
    let title: String
    /// Secondary line under the title, e.g. "1h 58m" or "S2 E4 · 23 min left".
    /// `nil` for Watch Later, which has no length/progress yet.
    var caption: String? = nil
    /// Watch progress in `0...1`; `nil` hides the bottom bar.
    var progress: Double? = nil

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LazyImage(url: imageURL) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                } else {
                    LinearGradient(
                        colors: [Color(white: 0.15), Color(white: 0.25)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                }
            }
            .priority(.normal)
            // Anchor to the top so the poster's key art shows and its own title
            // text (usually bottom-third) is the part that gets cropped.
            .frame(width: MediaCardSize.width, height: MediaCardSize.height, alignment: .top)
            .clipped()

            LinearGradient(
                colors: [.clear, .black.opacity(0.9)],
                startPoint: .center, endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.bottom, progress == nil ? 16 : 20)

            if let progress {
                let fraction = min(max(progress, 0), 1)
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.3))
                    Rectangle().fill(Color.progressFill)
                        .frame(width: MediaCardSize.width * fraction)
                }
                .frame(height: 6)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(width: MediaCardSize.width, height: MediaCardSize.height)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
    }
}

// MARK: - Typography
//
// Semantic Dynamic Type scale — scales with the system and respects
// accessibility text sizes, unlike the previous hardcoded `.system(size:)`
// values that had sprawled across ~15 files. `.rounded` is the app's brand
// design for display/title text. Roles map to tvOS text styles by hierarchy:
//   displayXL   → .largeTitle   (biggest hero — paywall / setup)
//   displayTitle→ .title        (detail-page hero + modal titles)
//   sectionTitle→ .title2       (rail / section / panel headers)
//   cardTitle   → .title3       (info-card / row titles)
//   heroSubtitle→ .title3       (hero subtitles / prominent secondary)
extension Font {
    static let displayXL = Font.system(.largeTitle, design: .rounded).weight(.bold)
    static let displayTitle = Font.system(.title, design: .rounded).weight(.bold)
    static let sectionTitle = Font.system(.title2, design: .rounded).weight(.bold)
    static let cardTitle = Font.system(.title3, design: .rounded).weight(.semibold)
    static let heroSubtitle = Font.system(.title3, design: .rounded)
}

// MARK: - Wordmark

/// The app's text wordmark — "Open" in the primary text color, "IPTV" in the
/// brand red. A text mark (not a bundled image) so it needs no asset and adapts
/// to light/dark automatically. Used on the splash, setup, and top chrome.
struct Wordmark: View {
    var size: CGFloat = 44

    var body: some View {
        (Text("Open").foregroundStyle(Color.textPrimary)
         + Text("IPTV").foregroundStyle(Color.progressFill))
            .font(.system(size: size, weight: .heavy, design: .rounded))
            .accessibilityLabel("OpenIPTV")
    }
}

extension View {
    /// tvOS 26 Liquid Glass container with a rounded-rectangle shape.
    func glassCard(cornerRadius: CGFloat = Radius.panel) -> some View {
        glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// tvOS 26 Liquid Glass capsule for floating status banners / pills.
    func glassCapsule() -> some View {
        glassEffect(.regular, in: Capsule())
    }

    /// Focus-aware lift + shadow for poster tiles.
    func posterFocus(isFocused: Bool) -> some View {
        self
            .scaleEffect(isFocused ? 1.08 : 1.0)
            .shadow(color: .black.opacity(isFocused ? 0.6 : 0.2), radius: isFocused ? 24 : 8, y: isFocused ? 12 : 4)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
    }
}

// MARK: - Credentials form (shared: first-run setup / Add Profile / Edit)

/// The Xtream credentials form. Single source of truth for the setup, Add
/// Profile, and Edit Credentials flows so they can't drift in layout, field
/// styling, fonts, or buttons. Presentational — the caller owns the text
/// bindings, loading/error state, and actions.
struct CredentialsForm: View {
    let title: String
    let subtitle: String
    @Binding var serverURL: String
    @Binding var username: String
    @Binding var password: String
    /// Optional user-chosen display name; blank falls back to the username.
    @Binding var profileName: String
    let isLoading: Bool
    let errorMessage: String?
    let primaryTitle: String
    let primaryLoadingTitle: String
    let primaryIcon: String
    let onPrimary: () -> Void
    /// When nil, no Cancel button — first-run setup has nowhere to cancel to.
    var onCancel: (() -> Void)? = nil
    /// When false (Edit Credentials), the password may be left blank to keep the
    /// saved one, so it isn't required to submit.
    var requiresPassword: Bool = true

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case server, username, password, name }

    private var canSubmit: Bool {
        !isLoading && !serverURL.isEmpty && !username.isEmpty && (!requiresPassword || !password.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.cardTitle)
                    .foregroundStyle(Color.textPrimary)
                Text(subtitle)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 6)

            field(label: "Server URL", placeholder: "example.com", text: $serverURL, secure: false, focusKey: .server)
            field(label: "Username", placeholder: "your username", text: $username, secure: false, focusKey: .username)
            field(label: "Password", placeholder: requiresPassword ? "your password" : "Leave blank to keep current", text: $password, secure: true, focusKey: .password)
            field(label: "Profile name", placeholder: "Optional — defaults to your username", text: $profileName, secure: false, focusKey: .name)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 16) {
                if let onCancel {
                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.body.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                }

                Button(action: onPrimary) {
                    HStack(spacing: 10) {
                        if isLoading {
                            ProgressView().controlSize(.small)
                            Text(primaryLoadingTitle)
                        } else {
                            Image(systemName: primaryIcon)
                            Text(primaryTitle)
                        }
                    }
                    .font(.body.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(!canSubmit)
            }
            .padding(.top, 8)
        }
        .padding(40)
        // Fixed (not max) width so Setup / Add Profile / Edit are pinned to the
        // exact same size regardless of how each sheet hugs its content.
        .frame(width: 720, alignment: .topLeading)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
        .task { focusedField = .server }
    }

    private func field(
        label: String,
        placeholder: String,
        text: Binding<String>,
        secure: Bool,
        focusKey: Field
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.caption2.bold())
                .tracking(1.2)
                .foregroundStyle(.secondary)
            // Use the native tvOS text field (a single rounded, focus-aware
            // field). A custom `.background` on top of it produced a second box
            // showing around the native field.
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                }
            }
            // Pin an explicit font so the text doesn't shrink when the native
            // tvOS field enters its focused/editing state (it otherwise renders
            // large when idle, small while editing). `.callout` matches the native
            // editing size, so idle and editing read consistently — smaller
            // fonts (caption2) leave the text lost inside the field's fixed
            // padding, larger ones (title3) balloon the idle state.
            .font(.callout)
            .focused($focusedField, equals: focusKey)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var panelBackground: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
        shape
            .fill(.thinMaterial)
            .overlay(shape.fill(Color.surfaceTint))
            .overlay(shape.strokeBorder(Color.hairline, lineWidth: 1))
    }
}

/// Single shared ambient backdrop used across every page in the app — home
/// rails, settings, setup, edit credentials, and detail-page fallbacks.
/// Centralizing this keeps the look perfectly consistent and makes
/// theme tweaks one-line edits. Detail pages overlay their title art on top
/// of this; all other pages use it directly.
struct AmbientBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if colorScheme == .dark {
                // Standard neutral dark canvas — a subtle vertical gradient (no
                // hue), a touch lighter at the top for depth. Cards elevate above
                // this via `cardSurface`.
                LinearGradient(
                    colors: [Color(white: 0.12), Color(white: 0.07)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else {
                // Light — warm ambient gradient (unchanged).
                ZStack {
                    Color(white: 0.92)
                    RadialGradient(
                        colors: [Color.orange.opacity(0.12), Color.clear],
                        center: .topLeading, startRadius: 0, endRadius: 900
                    )
                    RadialGradient(
                        colors: [Color.purple.opacity(0.10), Color.clear],
                        center: .bottomTrailing, startRadius: 0, endRadius: 900
                    )
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// Backdrop gradient used behind hero panels — layered on top of an AsyncImage for cinema feel.
struct HeroGradientBackground: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.0), location: 0.0),
                .init(color: .black.opacity(0.35), location: 0.6),
                .init(color: .black.opacity(0.85), location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

// MARK: - Selectable chip button style

/// Selection-aware glass chip used by the season picker and the sync-interval
/// picker. A single ButtonStyle (rather than swapping `.glassProminent`/`.glass`
/// per branch) so toggling selection doesn't change the Button's view identity
/// and steal focus back to the first chip. Reads focus like the paywall's
/// plan cards.
struct SelectableChipButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Chip(configuration: configuration, isSelected: isSelected)
    }

    private struct Chip: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(isSelected ? .callout.bold() : .callout)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .glassEffect(
                    isSelected
                        ? .regular.tint(.accentColor).interactive()
                        : .regular.interactive(),
                    in: Capsule()
                )
                .scaleEffect(isFocused ? 1.10 : (configuration.isPressed ? 0.96 : 1.0))
                .shadow(color: .black.opacity(isFocused ? 0.35 : 0), radius: isFocused ? 12 : 0, y: isFocused ? 6 : 0)
                .animation(.smooth(duration: 0.16), value: isFocused)
                .animation(.smooth(duration: 0.16), value: isSelected)
                .animation(.smooth(duration: 0.1), value: configuration.isPressed)
        }
    }
}
