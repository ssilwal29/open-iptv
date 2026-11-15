import SwiftUI
import SwiftData
import NukeUI

// MARK: - Design tokens

private enum MovieDetailDesign {
    static let posterWidth: CGFloat = 240
    static let posterHeight: CGFloat = 360
    static let infoCardHeight: CGFloat = 340
    static let topInset: CGFloat = 160
}

/// Placeholder strings sized to match typical loaded content. Rendering them
/// while the page is in its skeleton state preserves the exact final layout
/// so nothing shifts when real data arrives.
private enum Placeholder {
    static let meta = "Genre / Subgenre  ·  2h 00m  ·  2026"
    static let plot = "When a mysterious letter draws the hero back to a familiar city, they encounter a world transformed by an unknown force. As they descend into the darkness, terrifying figures both familiar and new emerge, forcing them to question their sanity while struggling to understand reality and hold on long enough to save what they love."
    static let cast = "Jane Doe, John Smith, Alex Johnson, Emily Brown, Chris Williams, Pat Taylor, Morgan Lee, Riley Garcia"
    static let released = "0000-00-00"
    static let duration = "00:00:00"
    static let rating = "0.0"
    static let emptyValue = "—"
}

// MARK: - Root

enum InfoCardKind: Hashable {
    case about, cast, details
}

struct MovieDetailView: View {
    @Environment(\.iptvRepository) private var repository
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme

    let movie: MovieEntity
    @AppStorage("activeProfileId") private var activeProfileId: String = ""
    @State private var viewModel = MovieDetailViewModel()
    /// The stream URL resolves on-press (spinner in the Play button); once ready
    /// this is set and the player is presented straight away.
    @State private var playback: ResolvedPlayback?
    @State private var isResolvingPlay = false

    @Query(filter: #Predicate<PlaybackProgress> { $0.mediaKindRaw == "movie" })
    private var movieProgress: [PlaybackProgress]

    /// This movie's active (unfinished) resume point, if any.
    private var resumePoint: PlaybackProgress? {
        let sid = movie.streamId
        let pid = activeProfileId
        return movieProgress.first {
            $0.movieStreamId == sid && $0.profile?.id == pid && !$0.isFinished && $0.position >= 15
        }
    }
    @State private var expandedCard: InfoCardKind?
    @FocusState private var focusedCard: InfoCardKind?
    @FocusState private var playFocused: Bool

    /// True while metadata fetch is in flight AND we have nothing cached to
    /// show. Keeps the skeleton up only during the actual "no data yet" window.
    private var isSkeleton: Bool {
        viewModel.isLoading && viewModel.genre.isEmpty && viewModel.cast.isEmpty
    }

    var body: some View {
        ZStack {
            // Main page — blurred when a modal is open.
            mainContent
                .blur(radius: expandedCard != nil ? 24 : 0)
                .animation(.smooth(duration: 0.25), value: expandedCard)

            // Modal overlay drawn on top. Handles its own scrim + dismiss tap.
            if let card = expandedCard {
                expandedModal(for: card)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        // Tell ContentView's top chrome to blur along with this page when a
        // modal is open. Flows up via PreferenceKey.
        .preference(key: DetailModalActiveKey.self, value: expandedCard != nil)
        .defaultFocus($playFocused, true)
        .fullScreenCover(item: $playback) { p in
            PlaybackScreen(playback: p)
        }
        .task {
            guard let repository else { return }
            await viewModel.load(movie: movie, using: repository, context: modelContext)
        }
    }

    /// Resolve the stream URL on-press (spinner in the Play button), then present
    /// the player straight away — no intermediate "Preparing stream…" surface.
    private func startPlayback(fromBeginning: Bool) {
        guard !isResolvingPlay,
              let repository,
              let raw = repository.movieStreamURL(
                  streamId: movie.streamId,
                  containerExtension: movie.containerExtension
              )
        else { return }
        isResolvingPlay = true
        Task {
            let resolved = await StreamURLResolver.shared.resolve(raw)
            playback = ResolvedPlayback(
                url: resolved,
                title: movie.name,
                progressKey: .movie(profileId: activeProfileId, streamId: movie.streamId),
                startFromBeginning: fromBeginning,
                metadata: PlaybackMetadata(
                    title: movie.name,
                    description: movie.detail?.plot,
                    artworkURL: movie.streamIconURL
                )
            )
            isResolvingPlay = false
        }
    }

    private var mainContent: some View {
        // NOTE: ambientBackdrop must be a true background — applied via .background()
        // — not a ZStack sibling. As a sibling, LazyImage(.scaledToFill()) reports
        // its image's intrinsic size to the ZStack, pulling the layout out of
        // alignment and pushing the VStack content above the visible area.
        VStack(alignment: .leading, spacing: 40) {
            heroRow
            infoCardsRow
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 56)
        .padding(.top, MovieDetailDesign.topInset)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Shimmer over text while first fetch is in-flight.
        .redacted(reason: isSkeleton ? .placeholder : [])
        .background(ambientBackdrop)
    }

    @ViewBuilder
    private func expandedModal(for card: InfoCardKind) -> some View {
        let (title, subtitle, body) = modalContent(for: card)
        InfoCardModal(
            title: title,
            subtitle: subtitle,
            content: { body },
            dismiss: {
                let prev = expandedCard
                // Set focus intent FIRST — while the modal is still in the view
                // tree, its focus trap prevents a visible jump. Then drop the
                // modal in the same transaction.
                focusedCard = prev
                withAnimation(.smooth(duration: 0.25)) {
                    expandedCard = nil
                }
            }
        )
    }

    private func modalContent(for card: InfoCardKind) -> (String, String?, AnyView) {
        switch card {
        case .about:
            return ("About", viewModel.genre.isEmpty ? nil : viewModel.genre, AnyView(aboutExpanded))
        case .cast:
            return ("Cast & Crew", viewModel.director.isEmpty ? nil : viewModel.director, AnyView(castExpanded))
        case .details:
            return ("Details", nil, AnyView(detailsExpanded))
        }
    }

    // MARK: Ambient backdrop

    /// Heavily blurred + darkened backdrop derived from the movie art. Acts as
    /// ambient mood lighting for the page — the viewer shouldn't recognize the
    /// image, just feel its color palette.
    @ViewBuilder
    private var ambientBackdrop: some View {
        let url = viewModel.backdropURL ?? movie.streamIconURL

        ZStack {
            // Warm cinematic fallback gradient so the page always has atmosphere,
            // even when no backdrop / poster is available.
            emptyStateBackdrop

            if let url {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 80, opaque: true)
                            .scaleEffect(1.3)
                            .offset(y: -80)
                            .clipped()
                            .opacity(colorScheme == .dark ? 0.6 : 0.3)
                    }
                }
            }

            // Uniform darken + subtle vertical gradient for readable foreground.
            LinearGradient(
                colors: colorScheme == .dark
                    ? [.black.opacity(0.55), .black.opacity(0.75), .black.opacity(0.9)]
                    : [.white.opacity(0.35), .white.opacity(0.55), .white.opacity(0.75)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    /// Reuses the shared AmbientBackdrop so the fallback (no-art) state matches
    /// every other page in the app pixel-for-pixel.
    private var emptyStateBackdrop: some View {
        AmbientBackdrop()
    }

    // MARK: Hero row (poster + title + actions, no glass panel)

    private var heroRow: some View {
        HStack(alignment: .top, spacing: 40) {
            poster
            titleBlock
        }
        // Hard-lock the row height so the page layout can never collapse even
        // if every child inside (poster, metadata, rating) returns zero size.
        .frame(height: MovieDetailDesign.posterHeight)
    }

    private var poster: some View {
        LazyImage(url: movie.streamIconURL) { state in
            if let image = state.image {
                image.resizable().scaledToFill()
            } else if state.error != nil || movie.streamIconURL == nil {
                posterErrorState
            } else {
                SkeletonShimmer()
            }
        }
        .frame(width: MovieDetailDesign.posterWidth, height: MovieDetailDesign.posterHeight)
        .overlay(alignment: .bottom) {
            if let resumePoint {
                ResumeProgressBar(fraction: resumePoint.fraction)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
    }

    private var posterErrorState: some View {
        LinearGradient(
            colors: [Color(white: 0.15), Color(white: 0.28)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            VStack(spacing: 12) {
                Image(systemName: "film")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("No art")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(movie.name)
                .font(.displayTitle)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)

            // Always render — placeholder while loading, real meta (or em-dash)
            // when loaded. Unconditional render keeps the layout height stable.
            Text(resolvedMetaLine)
                .font(.cardTitle)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)

            StarRatingView(rating: .constant(Int(movie.rating5Based)))
                .padding(.leading, 18)

            Spacer(minLength: 16)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 20) {
                    Button {
                        startPlayback(fromBeginning: false)
                    } label: {
                        HStack(spacing: 8) {
                            if isResolvingPlay {
                                // Resolving the stream URL — spinner in place,
                                // then we present the player straight away.
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "play.fill")
                            }
                            Text(resumePoint != nil ? "Resume" : "Play")
                        }
                        .font(.default)
                        .frame(minWidth: 180)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .focused($playFocused)
                    .disabled(isResolvingPlay)

                    if resumePoint != nil {
                        Button {
                            startPlayback(fromBeginning: true)
                        } label: {
                            Label("Play from Beginning", systemImage: "gobackward")
                                .font(.default)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .disabled(isResolvingPlay)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: MovieDetailDesign.posterHeight, alignment: .topLeading)
    }

    private var metaLine: String {
        var parts: [String] = []
        if !viewModel.genre.isEmpty { parts.append(viewModel.genre) }
        if !viewModel.duration.isEmpty { parts.append(viewModel.duration) }
        if !viewModel.releaseDate.isEmpty {
            let year = String(viewModel.releaseDate.prefix(4))
            if !year.isEmpty { parts.append(year) }
        }
        return parts.joined(separator: "  ·  ")
    }

    /// Meta line that always has content to render so the layout height stays
    /// constant. Placeholder while loading, em-dash when data is genuinely empty.
    private var resolvedMetaLine: String {
        if isSkeleton { return Placeholder.meta }
        return metaLine.isEmpty ? Placeholder.emptyValue : metaLine
    }

    // MARK: Info cards row

    private var infoCardsRow: some View {
        HStack(alignment: .top, spacing: Spacing.panel) {
            InfoCard(
                title: "About",
                subtitle: "",
                compactBody: { aboutCompact },
                onTap: { expandedCard = .about }
            )
            .frame(maxWidth: .infinity)
            .focused($focusedCard, equals: .about)

            InfoCard(
                title: "Cast & Crew",
                subtitle: "",
                compactBody: { castCompact },
                onTap: { expandedCard = .cast }
            )
            .frame(maxWidth: .infinity)
            .focused($focusedCard, equals: .cast)

            InfoCard(
                // No subtitle: Details has no real one, and reserving the blank
                // line pushed the 3 fixed rows + MORE past the fixed card height.
                title: "Details",
                subtitle: "",
                compactBody: { detailsCompact },
                onTap: { expandedCard = .details }
            )
            .frame(maxWidth: .infinity)
            .focused($focusedCard, equals: .details)
        }
        // Same hard-lock on the cards row — guarantees the 3-card strip keeps
        // its height even if every card internally collapses.
        .frame(height: MovieDetailDesign.infoCardHeight)
    }

    // MARK: Info card bodies

    private var aboutCompact: some View {
        Text(isSkeleton ? Placeholder.plot : viewModel.plot)
            .font(.body)
            .foregroundStyle(Color.textPrimary)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: false)
    }

    private var aboutExpanded: some View {
        Text(viewModel.plot)
            .font(.body)
            .foregroundStyle(Color.textPrimary)
            .lineSpacing(6)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var castCompact: some View {
        // Always render — placeholder while skeleton, real cast when loaded,
        // em-dash if there's no cast at all. Stable height in every state.
        let text: String = {
            if isSkeleton { return Placeholder.cast }
            if !viewModel.cast.isEmpty { return viewModel.cast }
            return Placeholder.emptyValue
        }()
        return Text(text)
            .font(.body)
            .foregroundStyle(Color.textPrimary)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: false)
    }

    @ViewBuilder
    private var castExpanded: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !viewModel.director.isEmpty {
                labeled("Director", value: viewModel.director, lineLimit: nil)
            }
            if !viewModel.cast.isEmpty {
                labeled("Cast", value: viewModel.cast, lineLimit: nil)
            }
        }
    }

    private var detailsCompact: some View {
        // Always render all 3 rows — placeholder values while skeleton, real
        // values once loaded, em-dash for truly missing fields. Stable height.
        VStack(alignment: .leading, spacing: 6) {
            detailRow("Released", resolvedDetailValue(viewModel.releaseDate, skeleton: Placeholder.released))
            detailRow("Duration", resolvedDetailValue(viewModel.duration, skeleton: Placeholder.duration))
            detailRow("Rating", resolvedDetailValue(viewModel.rating, skeleton: Placeholder.rating))
        }
    }

    private func resolvedDetailValue(_ value: String, skeleton: String) -> String {
        if isSkeleton { return skeleton }
        return value.isEmpty ? Placeholder.emptyValue : value
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        // .callout (not .body) so all three rows + MORE fit inside the fixed
        // card height — a VStack of fixed single-line rows can't compress to
        // fit the way the About/Cast single Text does, so .body overflowed and
        // clipped MORE.
        Text("\(Text(label).foregroundStyle(.secondary))  \(Text(value).foregroundStyle(Color.textPrimary))")
            .font(.callout)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    @ViewBuilder
    private var detailsExpanded: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !viewModel.genre.isEmpty { labeled("Genre", value: viewModel.genre, lineLimit: nil) }
            if !viewModel.releaseDate.isEmpty { labeled("Released", value: viewModel.releaseDate, lineLimit: nil) }
            if !viewModel.duration.isEmpty { labeled("Duration", value: viewModel.duration, lineLimit: nil) }
            if !viewModel.rating.isEmpty { labeled("Rating", value: viewModel.rating, lineLimit: nil) }
        }
    }

    // MARK: Row helpers

    private func labeled(_ label: String, value: String, lineLimit: Int? = 2) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.caption2.bold())
                .tracking(1.2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func kv(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.callout)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.tertiary)
    }
}

// MARK: - InfoCard (tinted glass with …MORE truncation hint)

private struct InfoCard<Compact: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let compactBody: () -> Compact
    let onTap: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        card
            .contentShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
            .focusable(true)
            .focused($isFocused)
            .onTapGesture { onTap() }
            .scaleEffect(isFocused ? 1.02 : 1.0)
            .shadow(color: .black.opacity(isFocused ? 0.45 : 0.0), radius: isFocused ? 24 : 0, y: isFocused ? 12 : 0)
            .animation(.smooth(duration: 0.18), value: isFocused)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.sectionTitle)
                .foregroundStyle(Color.textPrimary)

            // Always render — empty subtitles collapse to a space to reserve
            // the line height so cards stay the same size whether or not a
            // subtitle is available.
            if !subtitle.isEmpty { Text(subtitle)
                    .font(.heroSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            compactBody()
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Text("MORE")
                    .font(.caption2.bold())
                    .tracking(1.5)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Spacing.content)
        // Single frame with explicit topLeading alignment so short content
        // (Details with only 4 rows) anchors to the top and the trailing
        // Spacer pushes MORE to the true bottom of the 340pt card.
        .frame(maxWidth: .infinity, minHeight: MovieDetailDesign.infoCardHeight, maxHeight: MovieDetailDesign.infoCardHeight, alignment: .topLeading)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
    }

    @ViewBuilder
    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
        shape
            .fill(.thinMaterial)
            .overlay(shape.fill(Color.surfaceTint))
            .overlay(shape.strokeBorder(Color.hairline, lineWidth: 1))
    }
}

// MARK: - Skeleton shimmer

/// Animated gradient placeholder used while an image is loading.
private struct SkeletonShimmer: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var phase: CGFloat = -1

    var body: some View {
        let base = colorScheme == .dark ? Color(white: 0.15) : Color(white: 0.85)
        let highlight = colorScheme == .dark ? Color(white: 0.25) : Color(white: 0.95)
        let clampedPhase = min(max(phase, 0), 1)
        let startX = -1 + (2 * clampedPhase)
        let endX = startX + 1

        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: base, location: 0),
                .init(color: highlight, location: 0.5),
                .init(color: base, location: 1)
            ]),
            startPoint: UnitPoint(x: startX, y: 0.5),
            endPoint: UnitPoint(x: endX, y: 0.5)
        )
        .onAppear {
            withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                phase = 2
            }
        }
    }
}

// MARK: - Modal (overlay; parent blurs the page behind it)

private struct InfoCardModal<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: () -> Content
    let dismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var didAppear = false
    @FocusState private var isFocusTrap: Bool

    var body: some View {
        ZStack {
            // Gentle darken + focus trap on top of the already-blurred page.
            // The focus trap is critical: without a focusable view inside the
            // modal, Siri Back bypasses our .onExitCommand and pops the parent
            // NavigationStack instead of dismissing the modal.
            Color.black.opacity(colorScheme == .dark ? 0.45 : 0.25)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .focusable(true)
                .focused($isFocusTrap)
                .onTapGesture { dismiss() }

            VStack(alignment: .leading, spacing: 20) {
                Text(title)
                    .font(.displayTitle)
                    .foregroundStyle(Color.textPrimary)

                if let subtitle {
                    Text(subtitle)
                        .font(.cardTitle)
                        .foregroundStyle(.secondary)
                }

                ScrollView {
                    content()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                        .padding(.bottom, 40)
                }
            }
            .padding(48)
            .frame(minWidth: 500, maxWidth: 900, minHeight: 300, maxHeight: 700, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 36, style: .continuous)
                    .fill(.thinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 36, style: .continuous)
                            .fill(Color.surfaceTint)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 36, style: .continuous)
                            .strokeBorder(Color.hairline, lineWidth: 1)
                    )
            )
            .scaleEffect(didAppear ? 1.0 : 0.88)
            .opacity(didAppear ? 1.0 : 0.0)
        }
        .onAppear {
            // Grab focus so Siri Back lands on us, not the parent nav stack.
            isFocusTrap = true
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                didAppear = true
            }
        }
        .onExitCommand { dismiss() }
    }
}
