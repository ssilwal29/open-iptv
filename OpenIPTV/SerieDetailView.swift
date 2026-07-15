import SwiftUI
import SwiftData
import NukeUI

// MARK: - Design tokens (mirror MovieDetailDesign exactly)

private enum SerieDetailDesign {
    static let posterWidth: CGFloat = 240
    static let posterHeight: CGFloat = 360
    static let infoCardHeight: CGFloat = 340
    static let topInset: CGFloat = 160
    static let episodeTileWidth: CGFloat = 320
    static let episodeTileImageHeight: CGFloat = 180
    static let episodeRailSpacing: CGFloat = 28
}

private enum SeriePlaceholder {
    static let meta = "Genre / Subgenre  ·  3 Seasons  ·  2026"
    static let plot = "When a mysterious force changes everything the protagonist thought they knew, they embark on a journey through unfamiliar worlds. Each episode peels back another layer of the story, revealing connections that span generations and asking what truly matters when reality itself is in question."
    static let cast = "Jane Doe, John Smith, Alex Johnson, Emily Brown, Chris Williams, Pat Taylor, Morgan Lee, Riley Garcia"
    static let emptyValue = "—"
}

enum SerieInfoCardKind: Hashable {
    case about, cast
}

// MARK: - Root

struct SerieDetailView: View {
    @Environment(\.iptvRepository) private var repository
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme

    let serie: SerieEntity
    @AppStorage("activeProfileId") private var activeProfileId: String = ""

    /// Episode resume rows — mapped to per-episode progress so each card shows
    /// its own bar (Continue Watching only surfaces the latest one per series).
    @Query(
        filter: #Predicate<PlaybackProgress> { $0.mediaKindRaw == "episode" },
        sort: \PlaybackProgress.updatedAt,
        order: .reverse
    )
    private var episodeProgress: [PlaybackProgress]

    /// Resolved on-press, then presented straight to the player. Loading shows
    /// as a spinner on the pressed control (hero button or the tapped episode
    /// tile), not an intermediate "Preparing stream…" surface.
    @State private var playback: ResolvedPlayback?
    @State private var heroResolving = false
    @State private var resolvingEpisodeId: String?

    /// This series' most-recent unfinished episode resume row, if any.
    private var resumeRow: PlaybackProgress? {
        let sid = serie.seriesId
        let pid = activeProfileId
        return episodeProgress.first { $0.seriesId == sid && $0.profile?.id == pid && !$0.isFinished }
    }

    private var resumeEpisode: EpisodeEntity? {
        guard let eid = resumeRow?.episodeId else { return nil }
        return episodeEntity(for: eid)
    }

    private func episodeEntity(for episodeId: String) -> EpisodeEntity? {
        guard !episodeId.isEmpty else { return nil }
        var descriptor = FetchDescriptor<EpisodeEntity>(predicate: #Predicate { $0.episodeId == episodeId })
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    private var progressByEpisodeId: [String: Double] {
        let sid = serie.seriesId
        let pid = activeProfileId
        var map: [String: Double] = [:]
        for row in episodeProgress
        where row.seriesId == sid && row.profile?.id == pid && !row.isFinished {
            if let eid = row.episodeId { map[eid] = row.fraction }
        }
        return map
    }
    @State private var viewModel = SerieDetailViewModel()
    @State private var expandedCard: SerieInfoCardKind?
    @State private var selectedSeasonNumber: Int?
    @FocusState private var focusedCard: SerieInfoCardKind?
    @FocusState private var playFocused: Bool

    private var isSkeleton: Bool {
        viewModel.isLoading && serie.seasons.isEmpty
    }

    private var sortedSeasons: [SeasonEntity] {
        serie.seasons.sorted { $0.seasonNumber < $1.seasonNumber }
    }

    /// First playable episode across all seasons in order — skips empty seasons
    /// (e.g. a "Specials" season 0 with no loaded episodes) so Play still works,
    /// and carries the owning season so the button label stays accurate.
    private var firstPlayable: (season: Int, episode: EpisodeEntity)? {
        for season in sortedSeasons {
            if let ep = season.episodes.sorted(by: { $0.episodeNum < $1.episodeNum }).first {
                return (season.seasonNumber, ep)
            }
        }
        return nil
    }

    private var selectedSeason: SeasonEntity? {
        guard let n = selectedSeasonNumber else { return sortedSeasons.first }
        return sortedSeasons.first { $0.seasonNumber == n } ?? sortedSeasons.first
    }

    private var episodesForSelectedSeason: [EpisodeEntity] {
        (selectedSeason?.episodes ?? []).sorted { $0.episodeNum < $1.episodeNum }
    }

    var body: some View {
        ZStack {
            mainContent
                .blur(radius: expandedCard != nil ? 24 : 0)
                .animation(.smooth(duration: 0.25), value: expandedCard)

            if let card = expandedCard {
                expandedModal(for: card)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        .preference(key: DetailModalActiveKey.self, value: expandedCard != nil)
        .defaultFocus($playFocused, true)
        .fullScreenCover(item: $playback) { p in
            VideoPlayerView(
                url: p.url,
                title: p.title,
                progressKey: p.progressKey,
                startFromBeginning: p.startFromBeginning
            )
        }
        .onAppear {
            if selectedSeasonNumber == nil {
                selectedSeasonNumber = sortedSeasons.first?.seasonNumber
            }
        }
        .onChange(of: sortedSeasons.first?.seasonNumber) { _, new in
            // Once data loads in, latch onto the first season as default.
            if selectedSeasonNumber == nil { selectedSeasonNumber = new }
        }
        .task {
            guard let repository else { return }
            await viewModel.load(serie: serie, using: repository, context: modelContext)
        }
    }

    private var mainContent: some View {
        // Series page is taller than the viewport (hero + episode rail + cards
        // ~1300pt > 1080pt), so the whole page scrolls. tvOS auto-scroll keeps
        // focused elements in view as the user moves between hero / rail / cards.
        ScrollView {
            VStack(alignment: .leading, spacing: 64) {
                heroRow
                episodesSection
                infoCardsRow
            }
            .padding(.horizontal, 56)
            .padding(.top, SerieDetailDesign.topInset)
            .padding(.bottom, 64)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .redacted(reason: isSkeleton ? .placeholder : [])
        }
        // Dissolve scrolling content before it reaches the top logo chrome
        // (which is intentionally scrim-free), so the logo never sits over live
        // poster/text. Applied to the scroll content only — the ambient
        // backdrop is added afterwards and stays full-bleed. The solid region
        // begins at topInset, exactly where the hero rests at scroll offset 0.
        .mask(alignment: .top) {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: SerieDetailDesign.topInset)
                Rectangle().fill(.black)
            }
        }
        .background(ambientBackdrop)
    }

    // MARK: Modal

    @ViewBuilder
    private func expandedModal(for card: SerieInfoCardKind) -> some View {
        let (title, subtitle, body) = modalContent(for: card)
        SerieInfoCardModal(
            title: title,
            subtitle: subtitle,
            content: { body },
            dismiss: dismissModal
        )
    }

    private func modalContent(for card: SerieInfoCardKind) -> (String, String?, AnyView) {
        switch card {
        case .about:
            return ("About", serie.genre.isEmpty ? nil : serie.genre, AnyView(aboutExpanded))
        case .cast:
            return ("Cast & Crew", serie.director.isEmpty ? nil : serie.director, AnyView(castExpanded))
        }
    }

    private func dismissModal() {
        let prev = expandedCard
        focusedCard = prev
        withAnimation(.smooth(duration: 0.25)) {
            expandedCard = nil
        }
    }

    // MARK: Ambient backdrop

    @ViewBuilder
    private var ambientBackdrop: some View {
        let url = serie.coverURL

        ZStack {
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

    // MARK: Hero

    private var heroRow: some View {
        HStack(alignment: .top, spacing: 40) {
            poster
            titleBlock
        }
        .frame(height: SerieDetailDesign.posterHeight)
    }

    private var poster: some View {
        LazyImage(url: serie.coverURL) { state in
            if let image = state.image {
                image.resizable().scaledToFill()
            } else if state.error != nil || serie.coverURL == nil {
                posterErrorState
            } else {
                SerieSkeletonShimmer()
            }
        }
        .frame(width: SerieDetailDesign.posterWidth, height: SerieDetailDesign.posterHeight)
        .overlay(alignment: .bottom) {
            if let resumeRow {
                ResumeProgressBar(fraction: resumeRow.fraction)
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
                Image(systemName: "tv.and.mediabox")
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
            Text(serie.name)
                .font(.displayTitle)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(resolvedMetaLine)
                .font(.cardTitle)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)

            StarRatingView(rating: .constant(Int(serie.rating5Based)))
                .padding(.leading, 18)

            Spacer(minLength: 16)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 20) {
                    Button {
                        playHero()
                    } label: {
                        HStack(spacing: 10) {
                            // Spinner while metadata loads (no data yet) or while
                            // the stream URL resolves on-press; play glyph otherwise.
                            if isSkeleton || heroResolving {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "play.fill")
                            }
                            Text(playButtonLabel)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(minWidth: 220)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .focused($playFocused)
                    // Nothing to play once loading is done and no season has
                    // episodes — dim rather than present a live-but-dead button.
                    .disabled(heroResolving || (!isSkeleton && firstPlayable == nil && resumeEpisode == nil))

                    if let ep = resumeEpisode {
                        Button {
                            playFromBeginning(ep)
                        } label: {
                            Label("Play from Beginning", systemImage: "gobackward")
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .disabled(heroResolving)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: SerieDetailDesign.posterHeight, alignment: .topLeading)
    }

    private var playButtonLabel: String {
        if let row = resumeRow {
            return "Resume  ·  S\(row.seasonNumber ?? 0) E\(row.episodeNumber ?? 0)"
        }
        if let (season, ep) = firstPlayable {
            return "Play  ·  S\(season) E\(ep.episodeNum)"
        }
        return "Play"
    }

    private var metaLine: String {
        var parts: [String] = []
        if !serie.genre.isEmpty { parts.append(serie.genre) }
        let count = serie.seasons.count
        if count > 0 { parts.append("\(count) Season\(count == 1 ? "" : "s")") }
        if let raw = serie.releaseDate, !raw.isEmpty {
            let year = String(raw.prefix(4))
            if !year.isEmpty { parts.append(year) }
        }
        return parts.joined(separator: "  ·  ")
    }

    private var resolvedMetaLine: String {
        if isSkeleton { return SeriePlaceholder.meta }
        return metaLine.isEmpty ? SeriePlaceholder.emptyValue : metaLine
    }

    // MARK: Episodes section (header + season picker + horizontal rail)

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Episodes")
                    .font(.cardTitle)
                    .foregroundStyle(Color.textPrimary)
                    .padding(.horizontal, 10)
                seasonPicker
            }

            episodesRail
                .padding(8)
        }
    }

    @ViewBuilder
    private var seasonPicker: some View {
        // A lone season chip is noise — only surface the picker when there's an
        // actual choice to make.
        if sortedSeasons.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(sortedSeasons, id: \.seasonNumber) { season in
                        seasonButton(season)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
            }
            .scrollClipDisabled(true)
            .frame(maxWidth: 720)
            // Group the whole picker as one focus section so Up from the
            // left-most chip (which sits under the non-focusable poster) still
            // escapes to the hero buttons instead of dead-ending.
            .focusSection()
        }
    }

    private func seasonButton(_ season: SeasonEntity) -> some View {
        let isSelected = selectedSeasonNumber == season.seasonNumber
        // One Button + a single style that reads `isSelected`. Branching between
        // .glassProminent and .glass swapped the Button's view identity on
        // selection, which dropped focus back to the first chip — parameterizing
        // the style instead keeps identity stable so focus stays put.
        return Button {
            selectedSeasonNumber = season.seasonNumber
        } label: {
            Text(seasonLabel(season))
        }
        .buttonStyle(SeasonButtonStyle(isSelected: isSelected))
    }

    @ViewBuilder
    private var episodesRail: some View {
        if isSkeleton {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: SerieDetailDesign.episodeRailSpacing) {
                    ForEach(0..<6, id: \.self) { i in
                        EpisodeTile.skeleton(number: i + 1)
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollClipDisabled(true)
        } else if episodesForSelectedSeason.isEmpty {
            HStack {
                Text("No episodes available for this season.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .frame(height: SerieDetailDesign.episodeTileImageHeight + 60)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: SerieDetailDesign.episodeRailSpacing) {
                    ForEach(episodesForSelectedSeason, id: \.episodeId) { episode in
                        EpisodeTile(
                            episode: episode,
                            progress: progressByEpisodeId[episode.episodeId],
                            isResolving: resolvingEpisodeId == episode.episodeId
                        ) {
                            playTile(episode)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollClipDisabled(true)
        }
    }

    // MARK: Info cards (2-card row: About + Cast & Crew)

    private var infoCardsRow: some View {
        HStack(alignment: .top, spacing: Spacing.panel) {
            SerieInfoCard(
                title: "About",
                subtitle: "",
                compactBody: { aboutCompact },
                onTap: { expandedCard = .about }
            )
            .frame(maxWidth: .infinity)
            .focused($focusedCard, equals: .about)

            SerieInfoCard(
                title: "Cast & Crew",
                subtitle: "",
                compactBody: { castCompact },
                onTap: { expandedCard = .cast }
            )
            .frame(maxWidth: .infinity)
            .focused($focusedCard, equals: .cast)
        }
        .frame(height: SerieDetailDesign.infoCardHeight)
    }

    // MARK: Compact bodies

    private var aboutCompact: some View {
        Text(isSkeleton ? SeriePlaceholder.plot : (serie.plot.isEmpty ? SeriePlaceholder.emptyValue : serie.plot))
            .font(.body)
            .foregroundStyle(Color.textPrimary)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: false)
    }

    private var castCompact: some View {
        let text: String = {
            if isSkeleton { return SeriePlaceholder.cast }
            if !serie.cast.isEmpty { return serie.cast }
            return SeriePlaceholder.emptyValue
        }()
        return Text(text)
            .font(.body)
            .foregroundStyle(Color.textPrimary)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: false)
    }

    // MARK: Expanded bodies

    private var aboutExpanded: some View {
        Text(serie.plot.isEmpty ? SeriePlaceholder.emptyValue : serie.plot)
            .font(.body)
            .foregroundStyle(Color.textPrimary)
            .lineSpacing(6)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var castExpanded: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !serie.director.isEmpty {
                labeled("Director", value: serie.director, lineLimit: nil)
            }
            if !serie.cast.isEmpty {
                labeled("Cast", value: serie.cast, lineLimit: nil)
            }
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

    // MARK: Helpers

    private func seasonLabel(_ season: SeasonEntity) -> String {
        if !season.name.isEmpty { return season.name }
        return "Season \(season.seasonNumber)"
    }

    private func streamURL(for episode: EpisodeEntity) -> URL? {
        guard !episode.episodeId.isEmpty else { return nil }
        let ext = episode.containerExtension.isEmpty ? "mp4" : episode.containerExtension
        return repository?.episodeStreamURL(episodeId: episode.episodeId, containerExtension: ext)
    }

    // MARK: Playback (resolve on-press, then present)

    private func playHero() {
        guard !heroResolving, let episode = resumeEpisode ?? firstPlayable?.episode else { return }
        heroResolving = true
        resolveAndPresent(episode: episode, fromBeginning: false) { heroResolving = false }
    }

    private func playFromBeginning(_ episode: EpisodeEntity) {
        guard !heroResolving else { return }
        heroResolving = true
        resolveAndPresent(episode: episode, fromBeginning: true) { heroResolving = false }
    }

    private func playTile(_ episode: EpisodeEntity) {
        guard resolvingEpisodeId == nil else { return }
        resolvingEpisodeId = episode.episodeId
        resolveAndPresent(episode: episode, fromBeginning: false) { resolvingEpisodeId = nil }
    }

    /// Resolve the episode's stream URL, then present the player. The spinner
    /// lives on the control that initiated (cleared via `done`).
    private func resolveAndPresent(episode: EpisodeEntity, fromBeginning: Bool, done: @escaping () -> Void) {
        guard let raw = streamURL(for: episode) else { done(); return }
        Task {
            let resolved = await StreamURLResolver.shared.resolve(raw)
            playback = ResolvedPlayback(
                url: resolved,
                title: episode.title.isEmpty ? serie.name : episode.title,
                progressKey: .episode(
                    profileId: activeProfileId,
                    seriesId: serie.seriesId,
                    episodeId: episode.episodeId,
                    season: episode.season?.seasonNumber ?? 0,
                    number: episode.episodeNum
                ),
                startFromBeginning: fromBeginning
            )
            done()
        }
    }
}

// MARK: - Season chip style

/// Selection-aware glass chip. A single ButtonStyle (rather than swapping
/// between `.glassProminent`/`.glass`) so selecting a season doesn't change the
/// Button's identity and steal focus back to the first chip.
private struct SeasonButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        SeasonChip(configuration: configuration, isSelected: isSelected)
    }

    private struct SeasonChip: View {
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
                .scaleEffect(isFocused ? 1.12 : (configuration.isPressed ? 0.96 : 1.0))
                .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: isFocused ? 14 : 0, y: isFocused ? 8 : 0)
                .animation(.smooth(duration: 0.16), value: isFocused)
                .animation(.smooth(duration: 0.16), value: isSelected)
                .animation(.smooth(duration: 0.1), value: configuration.isPressed)
        }
    }
}

// MARK: - Episode tile

private struct EpisodeTile: View {
    let episode: EpisodeEntity?
    let placeholderNumber: Int?
    /// Resume progress in `0...1` for this episode; nil hides the bar.
    let progress: Double?
    /// True while this tile's stream URL is resolving on-press — shows a spinner
    /// in place of the play glyph.
    let isResolving: Bool
    let onPlay: () -> Void
    @FocusState private var isFocused: Bool

    init(episode: EpisodeEntity, progress: Double? = nil, isResolving: Bool = false, onPlay: @escaping () -> Void) {
        self.episode = episode
        self.progress = progress
        self.isResolving = isResolving
        self.placeholderNumber = nil
        self.onPlay = onPlay
    }

    private init(skeletonNumber: Int) {
        self.episode = nil
        self.progress = nil
        self.isResolving = false
        self.placeholderNumber = skeletonNumber
        self.onPlay = {}
    }

    static func skeleton(number: Int) -> EpisodeTile { EpisodeTile(skeletonNumber: number) }

    var body: some View {
        Button {
            onPlay()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                thumbnail
                    .frame(width: SerieDetailDesign.episodeTileWidth, height: SerieDetailDesign.episodeTileImageHeight)
                    .clipped()
                    .overlay {
                        // Play affordance on the focused tile so it's clear the
                        // thumbnail is the play control; a spinner replaces it
                        // while this tile's URL resolves. Skeletons get neither.
                        if episode != nil {
                            if isResolving {
                                ProgressView()
                                    .controlSize(.large)
                                    .padding(20)
                                    .background(.ultraThinMaterial, in: Circle())
                                    .shadow(radius: 8)
                            } else {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 30, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(20)
                                    .background(.ultraThinMaterial, in: Circle())
                                    .shadow(radius: 8)
                                    .opacity(isFocused ? 1 : 0)
                                    .scaleEffect(isFocused ? 1 : 0.8)
                                    .animation(.smooth(duration: 0.18), value: isFocused)
                            }
                        }
                    }
                    .overlay(alignment: .bottom) {
                        // Per-episode resume progress, pinned to the bottom edge.
                        // A scrim darkens the bottom strip so the bar reads on
                        // light thumbnails.
                        if let progress, progress > 0 {
                            let fraction = min(max(progress, 0), 1)
                            ZStack(alignment: .bottom) {
                                LinearGradient(
                                    colors: [.clear, .black.opacity(0.55)],
                                    startPoint: .center, endPoint: .bottom
                                )
                                .frame(height: 40)

                                ZStack(alignment: .leading) {
                                    Rectangle().fill(.white.opacity(0.35))
                                    Rectangle().fill(Color.progressFill)
                                        .frame(width: SerieDetailDesign.episodeTileWidth * fraction)
                                }
                                .frame(height: 6)
                            }
                        }
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text(headline)
                        .font(.system(.callout, design: .rounded))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(plotPreview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(12)
                .frame(width: SerieDetailDesign.episodeTileWidth, alignment: .leading)
            }
        }
        .buttonStyle(.card)
        .focused($isFocused)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let episode, !episode.movieImage.isEmpty {
            LazyImage(url: episode.movieImage.secureURL) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                } else if state.error != nil {
                    // Real episode but image failed — static fallback art.
                    errorArt
                } else {
                    // Real episode, image still loading — shimmer.
                    SerieSkeletonShimmer()
                }
            }
        } else if episode != nil {
            // Real episode with no artwork URL — go straight to fallback art
            // instead of a shimmer that would never resolve.
            errorArt
        } else {
            // Skeleton tile (no episode at all yet) — shimmer to match the
            // hero poster's loading state.
            SerieSkeletonShimmer()
        }
    }

    private var errorArt: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.18), Color(white: 0.28)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "tv")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
        }
    }

    private var headline: String {
        if let episode {
            let title = episode.title.isEmpty ? "Episode \(episode.episodeNum)" : episode.title
            return "E\(episode.episodeNum)  ·  \(title)"
        }
        return "E\(placeholderNumber ?? 0)  ·  Episode title placeholder"
    }

    private var plotPreview: String {
        if let episode, !episode.plot.isEmpty { return episode.plot }
        return "Episode synopsis placeholder text. Just enough to give a feel for tile height."
    }
}

// MARK: - InfoCard (mirrors MovieDetailView.InfoCard)

private struct SerieInfoCard<Compact: View>: View {
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

            if !subtitle.isEmpty {
                Text(subtitle)
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
        .frame(maxWidth: .infinity, minHeight: SerieDetailDesign.infoCardHeight, maxHeight: SerieDetailDesign.infoCardHeight, alignment: .topLeading)
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

private struct SerieSkeletonShimmer: View {
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

// MARK: - Modal (mirrors MovieDetailView.InfoCardModal)

private struct SerieInfoCardModal<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: () -> Content
    let dismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var didAppear = false
    @FocusState private var isFocusTrap: Bool

    var body: some View {
        ZStack {
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
            isFocusTrap = true
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                didAppear = true
            }
        }
        .onExitCommand { dismiss() }
    }
}
