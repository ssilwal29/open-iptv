import SwiftUI
import SwiftData
import NukeUI

// MARK: - Layout

private enum SerieLayout {
    /// Top inset that clears the floating nav chrome above the filter bar.
    static let chromeInset: CGFloat = 10
}

// MARK: - Root

struct SerieView: View {
    @AppStorage("activeProfileId") private var activeProfileId: String = ""

    @Query(
        filter: #Predicate<CategoryEntity> { $0.kindRaw == "serie" },
        sort: \CategoryEntity.sortOrder
    )
    private var allSerieCategories: [CategoryEntity]

    @Environment(\.modelContext) private var modelContext

    /// In-progress episode playback, most-recent first. Collapsed to one entry
    /// per series (latest episode) for the Continue Watching rail.
    @Query(
        filter: #Predicate<PlaybackProgress> { $0.mediaKindRaw == "episode" },
        sort: \PlaybackProgress.updatedAt,
        order: .reverse
    )
    private var episodeProgress: [PlaybackProgress]

    /// Filtered to the active profile. See MovieView for the rationale on
    /// in-memory filtering instead of an outer/inner-view rebuild.
    private var categories: [CategoryEntity] {
        allSerieCategories.filter { $0.profile?.id == activeProfileId }
    }

    /// `nil` means "All" — show every category as a horizontal rail.
    /// A specific compositeId means show only that category as a grid.
    @State private var selectedCategoryId: String?
    @FocusState private var focusedSerie: SerieEntity?

    @FocusState private var filterFocused: Bool
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @Namespace private var browseScope

    /// One resume entry per series (its most-recent in-progress episode),
    /// resolved to `SerieEntity` via a single `contains` fetch.
    private var continueWatchingSeries: [SerieResume] {
        let activeId = activeProfileId
        let rows = episodeProgress.filter { $0.profile?.id == activeId && !$0.isFinished }
        guard !rows.isEmpty else { return [] }
        // Rows are newest-first; keep the first episode seen per series.
        var seenSeries = Set<Int>()
        let latestPerSeries = rows.filter { row in
            guard let sid = row.seriesId else { return false }
            return seenSeries.insert(sid).inserted
        }
        let ids = latestPerSeries.compactMap(\.seriesId)
        let fetched = (try? modelContext.fetch(
            FetchDescriptor<SerieEntity>(predicate: #Predicate { ids.contains($0.seriesId) })
        )) ?? []
        let byId = Dictionary(
            fetched.filter { $0.profile?.id == activeId }.map { ($0.seriesId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return latestPerSeries.compactMap { row in
            guard let sid = row.seriesId, let serie = byId[sid] else { return nil }
            let season = row.seasonNumber ?? 0
            let number = row.episodeNumber ?? 0
            let caption = "S\(season) E\(number) · \(row.remainingText)"
            return SerieResume(
                id: row.id,
                serie: serie,
                episodeId: row.episodeId ?? "",
                seasonNumber: season,
                episodeNumber: number,
                fraction: row.fraction,
                caption: caption
            )
        }
    }

    var body: some View {
        if categories.isEmpty {
            EmptyLibraryView(message: "No series yet. Pull a fresh sync from Settings.")
                .background(AmbientBackdrop())
        } else {
            ZStack {
                AmbientBackdrop()

                // Two-pane: a vertical, searchable category sidebar on the left
                // (scales to hundreds of categories — the horizontal chip strip
                // did not) and the rails/grid content on the right.
                GeometryReader { proxy in
                    HStack(alignment: .top, spacing: 0) {
                        CategoryFilterSidebar(
                            categories: categories,
                            selectedCategoryId: $selectedCategoryId,
                            firstRowFocus: $filterFocused,
                            onSelect: { scrollPosition.scrollTo(edge: .top) }
                        )
                        .frame(width: proxy.size.width * 0.26)
                        .focusSection()
                        .prefersDefaultFocus(true, in: browseScope)

                        // Back snaps the grid to the top and moves focus to the
                        // sidebar's "All" row — moving focus off the (now
                        // scrolled-away) card is what makes the scroll-to-top
                        // stick against tvOS focus restoration.
                        content
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .onExitCommand {
                                scrollPosition.scrollTo(edge: .top)
                                filterFocused = true
                            }
                            .focusSection()
                    }
                    .padding(.leading, 56)
                    .padding(.top, SerieLayout.chromeInset)
                    .padding(.bottom, 40)
                    .focusScope(browseScope)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let id = selectedCategoryId,
           let category = categories.first(where: { $0.compositeId == id }) {
            SerieCategoryGrid(category: category, profileId: activeProfileId, focusedSerie: $focusedSerie, scrollPosition: $scrollPosition)
        } else {
            allRails
        }
    }

    private var allRails: some View {
        let entries = continueWatchingSeries

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: PosterSize.catalogSpacing) {
                SerieContinueWatchingRail(
                    entries: entries,
                    focusedSerie: $focusedSerie
                )
                .focusSection()

                ForEach(categories) { category in
                    SerieCatalogRow(
                        category: category,
                        profileId: activeProfileId,
                        focusedSerie: $focusedSerie
                    )
                    .focusSection()
                }
            }
            .scrollTargetLayout()
            .padding(.top, 16)
            .padding(.bottom, 40)
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition($scrollPosition)
    }
}

// MARK: - Continue Watching rail (in-progress series, pinned at top)

/// A resume entry resolved to its `SerieEntity` (feeds the Continue Watching rail).
struct SerieResume: Identifiable {
    let id: String
    let serie: SerieEntity
    let episodeId: String
    let seasonNumber: Int
    let episodeNumber: Int
    let fraction: Double
    let caption: String
}

private struct SerieContinueWatchingRail: View {
    let entries: [SerieResume]
    @FocusState.Binding var focusedSerie: SerieEntity?

    @Environment(\.iptvRepository) private var repository
    @Environment(\.modelContext) private var modelContext
    @AppStorage("activeProfileId") private var activeProfileId: String = ""
    // Select → resolve on-press (spinner on the card), then resume;
    // "Go to Series" → push the detail page.
    @State private var playback: ResolvedPlayback?
    @State private var resolvingId: String?
    @State private var goToSerie: SerieEntity?

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "play.circle")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.yellow)
                Text("Continue Watching")
                    .font(.sectionTitle)
            }
            .padding(.horizontal, 56)

            if entries.isEmpty {
                Text("Series you start will appear here so you can pick up where you left off.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 56)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: MediaCardSize.spacing) {
                        ForEach(entries) { entry in
                            Button {
                                resume(entry)
                            } label: {
                                MediaLandscapeCard(
                                    imageURL: entry.serie.coverURL,
                                    title: entry.serie.name,
                                    caption: entry.caption,
                                    progress: entry.fraction
                                )
                                .overlay {
                                    if resolvingId == entry.id {
                                        ZStack {
                                            Color.black.opacity(0.4)
                                            ProgressView().controlSize(.large)
                                        }
                                        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                                    }
                                }
                            }
                            .buttonStyle(.card)
                            .focused($focusedSerie, equals: entry.serie)
                            .contextMenu { menu(for: entry) }
                        }
                    }
                    .padding(.horizontal, 56)
                }
                .scrollClipDisabled(true)
            }
        }
        .navigationDestination(item: $goToSerie) { SerieDetailView(serie: $0) }
        .fullScreenCover(item: $playback) { p in
            VideoPlayerView(url: p.url, title: p.title, progressKey: p.progressKey)
        }
    }

    /// Resolve the in-progress episode's stream URL on-press (spinner on the
    /// card), then play. The resume row stores the episode id but not its
    /// container extension, so we resolve the `EpisodeEntity` for the ext + title.
    private func resume(_ entry: SerieResume) {
        guard resolvingId == nil, let repository else { return }
        let episodeId = entry.episodeId
        let episode = self.episode(for: episodeId)
        let ext = (episode?.containerExtension.isEmpty == false) ? episode!.containerExtension : "mp4"
        guard !episodeId.isEmpty,
              let raw = repository.episodeStreamURL(episodeId: episodeId, containerExtension: ext)
        else { return }
        resolvingId = entry.id
        Task {
            let resolved = await StreamURLResolver.shared.resolve(raw)
            playback = ResolvedPlayback(
                url: resolved,
                title: (episode?.title.isEmpty == false) ? episode!.title : entry.serie.name,
                progressKey: .episode(
                    profileId: activeProfileId,
                    seriesId: entry.serie.seriesId,
                    episodeId: episodeId,
                    season: entry.seasonNumber,
                    number: entry.episodeNumber
                )
            )
            resolvingId = nil
        }
    }

    @ViewBuilder
    private func menu(for entry: SerieResume) -> some View {
        Button {
            goToSerie = entry.serie
        } label: {
            Label("Go to Series", systemImage: "info.circle")
        }
        Button {
            PlaybackProgressStore.deleteSeriesEpisodes(
                seriesId: entry.serie.seriesId,
                profileId: activeProfileId,
                in: modelContext
            )
        } label: {
            Label("Mark as Watched", systemImage: "checkmark.circle")
        }
    }

    private func episode(for episodeId: String) -> EpisodeEntity? {
        guard !episodeId.isEmpty else { return nil }
        var descriptor = FetchDescriptor<EpisodeEntity>(predicate: #Predicate { $0.episodeId == episodeId })
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }
}

// MARK: - Category grid (single category, all series)

struct SerieCategoryGrid: View {
    @Bindable var category: CategoryEntity
    let profileId: String
    @FocusState.Binding var focusedSerie: SerieEntity?
    @Binding var scrollPosition: ScrollPosition
    // See SerieCatalogRow — @Query so background-sync inserts refresh the grid.
    @Query private var categorySeries: [SerieEntity]

    init(
        category: CategoryEntity,
        profileId: String,
        focusedSerie: FocusState<SerieEntity?>.Binding,
        scrollPosition: Binding<ScrollPosition>
    ) {
        self._category = Bindable(wrappedValue: category)
        self.profileId = profileId
        self._focusedSerie = focusedSerie
        self._scrollPosition = scrollPosition
        let categoryId = category.categoryId
        // Profile scoping in the store: `categoryId` isn't unique across profiles.
        _categorySeries = Query(
            filter: #Predicate<SerieEntity> { $0.categoryId == categoryId && $0.profile?.id == profileId },
            sort: [SortDescriptor(\SerieEntity.num)]
        )
    }

    private var visibleSeries: [SerieEntity] { categorySeries }

    private var columns: [GridItem] {
        // Adaptive (fixed tile width) so the grid fits as many poster tiles as the
        // content pane allows. Fixed `.flexible()` columns shrank below the tile's
        // own width in the narrower sidebar layout, so tiles overlapped.
        [GridItem(.adaptive(minimum: PosterSize.width, maximum: PosterSize.width),
                  spacing: PosterSize.rowSpacing, alignment: .top)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(category.name.capitalized)
                        .font(.sectionTitle)
                    Spacer()
                    Text("\(visibleSeries.count)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 76)

                if visibleSeries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tv")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        Text("No series in this category")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: PosterSize.rowSpacing) {
                        ForEach(visibleSeries) { serie in
                            SeriePosterTile(serie: serie)
                                .focused($focusedSerie, equals: serie)
                        }
                    }
                    .padding(.horizontal, 56)
                }

                Spacer(minLength: 40)
            }
            .padding(.top, 16)
        }
        .scrollPosition($scrollPosition)
    }
}

// MARK: - Catalog row (rails view)

struct SerieCatalogRow: View {
    @Bindable var category: CategoryEntity
    let profileId: String
    @FocusState.Binding var focusedSerie: SerieEntity?
    // Items via @Query (not `category.series`): a background sync's inserts only
    // re-run a @Query, never a materialized relationship array.
    @Query private var categorySeries: [SerieEntity]

    init(category: CategoryEntity, profileId: String, focusedSerie: FocusState<SerieEntity?>.Binding) {
        self._category = Bindable(wrappedValue: category)
        self.profileId = profileId
        self._focusedSerie = focusedSerie
        let categoryId = category.categoryId
        // Profile scoping in the store: `categoryId` isn't unique across profiles.
        _categorySeries = Query(
            filter: #Predicate<SerieEntity> { $0.categoryId == categoryId && $0.profile?.id == profileId },
            sort: [SortDescriptor(\SerieEntity.num)]
        )
    }

    private var visibleSeries: [SerieEntity] { categorySeries }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(category.name.capitalized)
                    .font(.sectionTitle)
                Spacer()
            }
            .padding(.horizontal, 56)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: PosterSize.rowSpacing) {
                    ForEach(visibleSeries) { serie in
                        SeriePosterTile(serie: serie)
                            .focused($focusedSerie, equals: serie)
                    }
                }
                .padding(.horizontal, 56)
            }
            .scrollClipDisabled(true)
        }
    }
}

