import SwiftUI
import SwiftData
import NukeUI

// MARK: - Layout

private enum MovieLayout {
    /// Top inset that clears the floating nav chrome above the filter bar.
    static let chromeInset: CGFloat = 10
}

// MARK: - Root

struct MovieView: View {
    @AppStorage("activeProfileId") private var activeProfileId: String = ""

    @Query(
        filter: #Predicate<CategoryEntity> { $0.kindRaw == "movie" },
        sort: \CategoryEntity.sortOrder
    )
    private var allMovieCategories: [CategoryEntity]

    @Query private var profiles: [Profile]
    @Environment(\.modelContext) private var modelContext

    /// In-progress movie playback, most-recent first. Small set — resolved to
    /// `MovieEntity` on demand for the Continue Watching rail.
    @Query(
        filter: #Predicate<PlaybackProgress> { $0.mediaKindRaw == "movie" },
        sort: \PlaybackProgress.updatedAt,
        order: .reverse
    )
    private var movieProgress: [PlaybackProgress]

    /// `nil` means "All" — show every category as a horizontal rail.
    /// A specific compositeId means show only that category as a grid.
    @State private var selectedCategoryId: String?
    @FocusState private var focusedMovie: MovieEntity?

    @FocusState private var filterFocused: Bool
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @Namespace private var browseScope

    /// Filtered to the active profile. With a typical Xtream playlist that's
    /// a few dozen categories per profile — in-memory filtering avoids a
    /// 470-line outer/inner-view rebuild for negligible runtime cost.
    private var categories: [CategoryEntity] {
        allMovieCategories.filter { $0.profile?.id == activeProfileId }
    }

    private var activeProfile: Profile? {
        profiles.first(where: { $0.id == activeProfileId })
    }

    private var hideAdult: Bool { activeProfile?.hideAdultContent ?? true }

    /// Resume items for the active profile, resolved to their `MovieEntity` via
    /// a single `contains` fetch (the set is a handful of items).
    private var continueWatchingMovies: [MovieResume] {
        let activeId = activeProfileId
        let hide = hideAdult
        let rows = movieProgress.filter { $0.profile?.id == activeId && !$0.isFinished }
        guard !rows.isEmpty else { return [] }
        let ids = rows.compactMap(\.movieStreamId)
        let fetched = (try? modelContext.fetch(
            FetchDescriptor<MovieEntity>(predicate: #Predicate { ids.contains($0.streamId) })
        )) ?? []
        let byId = Dictionary(
            fetched.filter { $0.profile?.id == activeId && (!hide || !$0.isAdult) }
                .map { ($0.streamId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return rows.compactMap { row in
            guard let sid = row.movieStreamId, let movie = byId[sid] else { return nil }
            return MovieResume(id: row.id, movie: movie, fraction: row.fraction, caption: row.remainingText)
        }
    }

    var body: some View {
        if categories.isEmpty {
            EmptyLibraryView(message: "No movies yet. Pull a fresh sync from Settings.")
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
                    .padding(.top, MovieLayout.chromeInset)
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
            MovieCategoryGrid(category: category, profileId: activeProfileId, focusedMovie: $focusedMovie, scrollPosition: $scrollPosition)
        } else {
            allRails
        }
    }

    private var allRails: some View {
        let entries = continueWatchingMovies

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: PosterSize.catalogSpacing) {
                MovieContinueWatchingRail(
                    entries: entries,
                    focusedMovie: $focusedMovie
                )
                .focusSection()

                ForEach(categories) { category in
                    MovieCatalogRow(
                        category: category,
                        profileId: activeProfileId,
                        focusedMovie: $focusedMovie
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

// MARK: - Continue Watching rail (in-progress movies, pinned at top)

/// A resume entry resolved to its `MovieEntity` (feeds the Continue Watching rail).
struct MovieResume: Identifiable {
    let id: String
    let movie: MovieEntity
    let fraction: Double
    let caption: String
}

private struct MovieContinueWatchingRail: View {
    let entries: [MovieResume]
    @FocusState.Binding var focusedMovie: MovieEntity?

    @Environment(\.iptvRepository) private var repository
    @Environment(\.modelContext) private var modelContext
    @AppStorage("activeProfileId") private var activeProfileId: String = ""
    // Select → resolve on-press (spinner on the card), then resume playback;
    // "Go to Movie" → push the detail page.
    @State private var playback: ResolvedPlayback?
    @State private var resolvingId: String?
    @State private var goToMovie: MovieEntity?

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
                Text("Movies you start will appear here so you can pick up where you left off.")
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
                                    imageURL: entry.movie.streamIconURL,
                                    title: entry.movie.name,
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
                            .focused($focusedMovie, equals: entry.movie)
                            .contextMenu { menu(for: entry) }
                        }
                    }
                    .padding(.horizontal, 56)
                }
                .scrollClipDisabled(true)
            }
        }
        .navigationDestination(item: $goToMovie) { MovieDetailView(movie: $0) }
        .fullScreenCover(item: $playback) { p in
            VideoPlayerView(url: p.url, title: p.title, progressKey: p.progressKey)
        }
    }

    /// Resolve the movie's stream URL on-press (spinner on the card), then play.
    private func resume(_ entry: MovieResume) {
        guard resolvingId == nil,
              let repository,
              let raw = repository.movieStreamURL(
                  streamId: entry.movie.streamId,
                  containerExtension: entry.movie.containerExtension
              )
        else { return }
        resolvingId = entry.id
        Task {
            let resolved = await StreamURLResolver.shared.resolve(raw)
            playback = ResolvedPlayback(
                url: resolved,
                title: entry.movie.name,
                progressKey: .movie(profileId: activeProfileId, streamId: entry.movie.streamId)
            )
            resolvingId = nil
        }
    }

    @ViewBuilder
    private func menu(for entry: MovieResume) -> some View {
        Button {
            goToMovie = entry.movie
        } label: {
            Label("Go to Movie", systemImage: "info.circle")
        }
        Button {
            PlaybackProgressStore.delete(id: entry.id, in: modelContext)
        } label: {
            Label("Mark as Watched", systemImage: "checkmark.circle")
        }
    }
}

// MARK: - Category filter sidebar (vertical, searchable)

/// Vertical, type-to-filter category picker shared by Movies and Series. Replaces
/// the horizontal chip strip, which was unusable with hundreds of categories.
/// Selecting a row drives the same `selectedCategoryId` binding (`nil` = "All"
/// rails). Mirrors the Live TV sidebar's look using the shared theme tokens.
struct CategoryFilterSidebar: View {
    let categories: [CategoryEntity]
    @Binding var selectedCategoryId: String?
    /// Lets the page move focus onto the sidebar's "All" row (the back gesture).
    var firstRowFocus: FocusState<Bool>.Binding? = nil
    var onSelect: (() -> Void)? = nil

    @State private var query = ""

    /// Case/diacritic-insensitive substring match on the category name (same
    /// matcher SearchView uses). Empty query shows every category; order is left
    /// as the API `sortOrder` — search covers findability.
    private var filtered: [CategoryEntity] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return categories }
        return categories.filter { $0.name.localizedStandardContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Categories")
                .font(.sectionTitle)
                .foregroundStyle(Color.textPrimary)

            searchField

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 8) {
                    allRow
                    ForEach(filtered, id: \.compositeId) { category in
                        CategorySidebarRow(
                            label: category.name.capitalized,
                            systemImage: "folder",
                            isSelected: selectedCategoryId == category.compositeId
                        ) {
                            selectedCategoryId = category.compositeId
                            onSelect?()
                        }
                    }
                    if filtered.isEmpty {
                        Text("No categories match “\(query.trimmingCharacters(in: .whitespaces))”")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 18)
                            .padding(.top, 8)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .padding(Spacing.content)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardSurface()
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.body)
                .foregroundStyle(.secondary)
            // Native tvOS field: no custom background (that double-boxes); pin the
            // font so it doesn't shrink when focused/editing.
            TextField("Search categories", text: $query)
                .font(.body)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
            // Focusable clear button — the only way back to the full list without
            // re-opening the keyboard to delete the query by hand.
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private var allRow: some View {
        let row = CategorySidebarRow(
            label: "All",
            systemImage: "square.grid.2x2",
            isSelected: selectedCategoryId == nil
        ) {
            selectedCategoryId = nil
            onSelect?()
        }
        if let firstRowFocus {
            row.focused(firstRowFocus)
        } else {
            row
        }
    }
}

/// One sidebar row (Button spanning the full width). Border-less focus fill —
/// mirrors the Live TV `CategoryRow`. Selected + focused states use the accent
/// tint at different opacities; text is `Color.textPrimary` (readable in both
/// light and dark).
private struct CategorySidebarRow: View {
    let label: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 28)
                Text(label)
                    .font(.body)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(SidebarRowButtonStyle(isSelected: isSelected))
        .focusEffectDisabled()
    }
}

/// Fill-only focus/selection highlight with NO system chrome. Both built-in tvOS
/// styles impose their own focus decoration — `.borderless` a glassy "lens" and
/// `.plain` a white platter — which clashed with the sidebar. This reads focus
/// via the environment (same technique as `SelectableChipButtonStyle`) and draws
/// only the accent fill.
private struct SidebarRowButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, isSelected: isSelected)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                .animation(.smooth(duration: 0.18), value: isFocused)
        }

        @ViewBuilder private var background: some View {
            let shape = RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
            if isFocused {
                shape.fill(Color.accentColor.opacity(0.28))
            } else if isSelected {
                shape.fill(Color.accentColor.opacity(0.14))
            } else {
                Color.clear
            }
        }
    }
}

// MARK: - Category grid (single category, all movies)

struct MovieCategoryGrid: View {
    @Bindable var category: CategoryEntity
    let profileId: String
    @FocusState.Binding var focusedMovie: MovieEntity?
    @Binding var scrollPosition: ScrollPosition
    // See MovieCatalogRow — @Query so background-sync inserts refresh the grid.
    @Query private var categoryMovies: [MovieEntity]
    @Query private var profiles: [Profile]

    init(
        category: CategoryEntity,
        profileId: String,
        focusedMovie: FocusState<MovieEntity?>.Binding,
        scrollPosition: Binding<ScrollPosition>
    ) {
        self._category = Bindable(wrappedValue: category)
        self.profileId = profileId
        self._focusedMovie = focusedMovie
        self._scrollPosition = scrollPosition
        let categoryId = category.categoryId
        _categoryMovies = Query(
            filter: #Predicate<MovieEntity> { $0.categoryId == categoryId },
            sort: [SortDescriptor(\MovieEntity.num)]
        )
    }

    private var hideAdult: Bool {
        profiles.first(where: { $0.id == profileId })?.hideAdultContent ?? true
    }

    private var visibleMovies: [MovieEntity] {
        categoryMovies.filter { $0.profile?.id == profileId && (!hideAdult || !$0.isAdult) }
    }

    private var columns: [GridItem] {
        // Adaptive (fixed tile width) so the grid fits as many poster tiles as the
        // content pane allows. Fixed `.flexible()` columns shrank below the tile's
        // own 260pt width in the narrower sidebar layout, so tiles overlapped.
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
                    Text("\(visibleMovies.count)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 76)

                if visibleMovies.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "film")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        Text("No movies in this category")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: PosterSize.rowSpacing) {
                        ForEach(visibleMovies) { movie in
                            MoviePosterTile(movie: movie)
                                .focused($focusedMovie, equals: movie)
                        }
                    }
                    .padding(.horizontal, 76)
                }

                Spacer(minLength: 40)
            }
            .padding(.top, 16)
        }
        .scrollPosition($scrollPosition)
    }
}

// MARK: - Catalog row (rails view)

struct MovieCatalogRow: View {
    @Bindable var category: CategoryEntity
    let profileId: String
    @FocusState.Binding var focusedMovie: MovieEntity?
    // Items via @Query (not `category.movies`): a background sync's inserts only
    // re-run a @Query, never a materialized relationship array — that array
    // stays stale until the view is rebuilt (relaunch / profile switch).
    @Query private var categoryMovies: [MovieEntity]
    @Query private var profiles: [Profile]

    init(category: CategoryEntity, profileId: String, focusedMovie: FocusState<MovieEntity?>.Binding) {
        self._category = Bindable(wrappedValue: category)
        self.profileId = profileId
        self._focusedMovie = focusedMovie
        let categoryId = category.categoryId
        _categoryMovies = Query(
            filter: #Predicate<MovieEntity> { $0.categoryId == categoryId },
            sort: [SortDescriptor(\MovieEntity.num)]
        )
    }

    private var hideAdult: Bool {
        profiles.first(where: { $0.id == profileId })?.hideAdultContent ?? true
    }

    private var visibleMovies: [MovieEntity] {
        categoryMovies.filter { $0.profile?.id == profileId && (!hideAdult || !$0.isAdult) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(category.name.capitalized)
                    .font(.sectionTitle)
                Spacer()
            }
            .padding(.horizontal, 56)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: PosterSize.rowSpacing) {
                    ForEach(visibleMovies) { movie in
                        MoviePosterTile(movie: movie)
                            .focused($focusedMovie, equals: movie)
                    }
                }
                .padding(.horizontal, 56)
            }
            .scrollClipDisabled(true)
        }
    }
}

