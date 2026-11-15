import SwiftUI
import SwiftData
import NukeUI

// MARK: - Design tokens (mirror SettingsDesign / MovieDetailDesign)

private enum LiveDesign {
    static let topInset: CGFloat = 10
}

/// Vertical alpha-gradient mask applied to inner scroll views so partially-visible
/// rows fade smoothly at the panel's top/bottom edges instead of being hard-cut.
/// Works around tvOS focus behaviour where a focused row at the scroll edge would
/// otherwise look "clipped" by the panel's clipShape.
private extension View {
    func liveScrollFade() -> some View {
        self.mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black, location: 0.05),
                    .init(color: .black, location: 0.95),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

// MARK: - Root

struct LiveView: View {
    @AppStorage("activeProfileId") private var activeProfileId: String = ""

    @Query(
        filter: #Predicate<CategoryEntity> { $0.kindRaw == "live" },
        sort: \CategoryEntity.sortOrder
    )
    private var allLiveCategories: [CategoryEntity]

    /// Filtered to the active profile (see MovieView).
    private var categories: [CategoryEntity] {
        allLiveCategories.filter { $0.profile?.id == activeProfileId }
    }

    @Query private var profiles: [Profile]

    @Environment(\.iptvRepository) private var repository
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = LiveViewModel()

    private var activeProfile: Profile? {
        profiles.first { $0.id == activeProfileId }
    }

    private var hideAdult: Bool { activeProfile?.hideAdultContent ?? true }

    private var favoriteIds: [Int] { activeProfile?.favoriteLiveStreamIds ?? [] }

    private var channelSource: ChannelSource {
        viewModel.showFavorites ? .favorites(favoriteIds) : .category(viewModel.selectedCategory)
    }

    @Namespace private var liveScope

    var body: some View {
        if categories.isEmpty {
            EmptyLibraryView(message: "No live channels yet. Pull a fresh sync from Settings.")
                .background(AmbientBackdrop())
        } else {
            GeometryReader { proxy in
                HStack(alignment: .top, spacing: Spacing.panel) {
                    CategorySidebar(
                        categories: categories,
                        selectedCategoryId: viewModel.showFavorites ? nil : viewModel.selectedCategory?.compositeId,
                        favoritesCount: favoriteIds.count,
                        favoritesSelected: viewModel.showFavorites,
                        onSelectFavorites: {
                            viewModel.showFavorites = true
                        },
                        onSelectCategory: { category in
                            viewModel.showFavorites = false
                            viewModel.selectedCategory = category
                        },
                        isRefreshing: viewModel.isRefreshing,
                        onRefresh: {
                            Task {
                                await viewModel.refresh(
                                    profileId: activeProfileId,
                                    repository: repository,
                                    container: modelContext.container
                                )
                            }
                        }
                    )
                    .frame(width: proxy.size.width * 0.22)
                    .focusSection()
                    .prefersDefaultFocus(true, in: liveScope)

                    ChannelListPane(
                        source: channelSource,
                        profileId: activeProfileId,
                        hideAdult: hideAdult,
                        favoriteIds: favoriteIds,
                        searchText: $viewModel.searchText,
                        selectedChannel: viewModel.selectedChannel,
                        onSelect: { channel in
                            viewModel.selectChannel(channel, repository: repository)
                        },
                        onListChange: { channels in
                            viewModel.channelList = channels
                        }
                    )
                    .frame(width: proxy.size.width * 0.44)
                    .focusSection()

                    PreviewPane(
                        viewModel: viewModel,
                        isFavorite: viewModel.selectedChannel.map { favoriteIds.contains($0.streamId) } ?? false,
                        onToggleFavorite: toggleFavorite
                    )
                    .frame(maxWidth: .infinity)
                    .focusSection()
                }
                .padding(.horizontal, 56)
                .padding(.top, LiveDesign.topInset)
                .padding(.bottom, 40)
                .focusScope(liveScope)
            }
            .background(AmbientBackdrop())
            .onAppear {
                if viewModel.selectedCategory == nil {
                    viewModel.selectedCategory = categories.first
                }
            }
            .onChange(of: activeProfileId) { _, _ in
                // Profile switched — drop the previous profile's selection so the
                // panes stop showing its channels; reseed from the new profile.
                viewModel.clearPreview()
                viewModel.showFavorites = false
                viewModel.selectedCategory = categories.first
            }
            .onChange(of: hideAdult) { _, hide in
                // The adult filter was switched on: drop an adult preview.
                if hide, viewModel.selectedChannel?.isAdult == true {
                    viewModel.clearPreview()
                }
            }
            .onChange(of: categories.map(\.compositeId)) { _, ids in
                // Keep a valid selection as categories arrive (e.g. a newly added
                // profile finishing its first sync).
                if let sel = viewModel.selectedCategory?.compositeId, ids.contains(sel) { return }
                viewModel.selectedCategory = categories.first
            }
            .onDisappear {
                viewModel.clearPreview()
            }
        }
    }
}

extension LiveView {
    fileprivate func toggleFavorite() {
        guard let channel = viewModel.selectedChannel, let profile = activeProfile else { return }
        profile.toggleFavoriteLive(channel.streamId)
        try? modelContext.save()
    }
}

/// What the middle pane lists.
enum ChannelSource {
    case category(CategoryEntity?)
    case favorites([Int])
}

// MARK: - Shared glass panel (mirror SettingsPanel pattern)

private struct LivePanel<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.sectionTitle)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            content()
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(Spacing.content)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
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

// MARK: - Categories sidebar

private struct CategorySidebar: View {
    let categories: [CategoryEntity]
    let selectedCategoryId: String?
    let favoritesCount: Int
    let favoritesSelected: Bool
    let onSelectFavorites: () -> Void
    let onSelectCategory: (CategoryEntity) -> Void
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        LivePanel(
            title: "Categories",
            subtitle: "\(categories.count) total"
        ) {
            ScrollView(.vertical) {
                LazyVStack(spacing: 10) {
                    RefreshRow(isRefreshing: isRefreshing, onRefresh: onRefresh)

                    SidebarRow(
                        title: "FAVORITES",
                        systemImage: favoritesSelected ? "star.fill" : "star",
                        trailing: favoritesCount > 0 ? "\(favoritesCount)" : nil,
                        isSelected: favoritesSelected,
                        onSelect: onSelectFavorites
                    )

                    ForEach(categories, id: \.compositeId) { category in
                        CategoryRow(
                            category: category,
                            isSelected: selectedCategoryId == category.compositeId
                        ) {
                            onSelectCategory(category)
                        }
                    }
                }
                // Generous vertical inset so the first/last rows sit inside
                // the fade-mask's "solid" zone — they always render fully.
                .padding(.vertical, 16)
                .padding(.horizontal, 4)
            }
            .liveScrollFade()
        }
    }
}

/// Refresh action styled as a sidebar menu row, pinned
/// at the top of the category list so it's reachable without scrolling. Flips
/// to a spinner + "REFRESHING…" while the manual sync runs.
private struct RefreshRow: View {
    let isRefreshing: Bool
    let onRefresh: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if isRefreshing {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.body)
                        .foregroundStyle(isFocused ? Color.accentColor : .secondary)
                }
            }
            .frame(width: 28)

            Button(action: onRefresh) {
                Text(isRefreshing ? "REFRESHING…" : "REFRESH LIST")
                    .font(.body)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .focused($isFocused)
            .animation(.smooth(duration: 0.18), value: isFocused)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
    }

    @ViewBuilder
    private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
        if isFocused {
            shape.fill(Color.accentColor.opacity(0.28))
        } else {
            Color.clear
        }
    }
}

/// Non-category sidebar entry (Favorites), styled like `CategoryRow`.
private struct SidebarRow: View {
    let title: String
    let systemImage: String
    let trailing: String?
    let isSelected: Bool
    let onSelect: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 28)

            Button(action: onSelect) {
                HStack {
                    Text(title)
                        .font(.body)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let trailing {
                        Text(trailing)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .focused($isFocused)
            .animation(.smooth(duration: 0.18), value: isFocused)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
    }

    @ViewBuilder
    private var rowBackground: some View {
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

private struct CategoryRow: View {
    let category: CategoryEntity
    let isSelected: Bool
    let onSelect: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: iconFor(category))
                .font(.body)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 28)
            
            Button(action: onSelect) {
                Text(category.name.uppercased())
                    .font(.body)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .focused($isFocused)
            .animation(.smooth(duration: 0.18), value: isFocused)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
    }

    @ViewBuilder
    private var rowBackground: some View {
        // Border-less focus indicator (fill only) so when a focused row is at
        // the panel's top/bottom edge, no stroke gets clipped by the panel
        // clipShape. The fade-mask handles partial-visibility gracefully.
        let shape = RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
        if isFocused {
            shape.fill(Color.accentColor.opacity(0.28))
        } else if isSelected {
            shape.fill(Color.accentColor.opacity(0.14))
        } else {
            Color.clear
        }
    }

    private func iconFor(_ category: CategoryEntity) -> String {
        let n = category.name.lowercased()
        if n.contains("sport") || n.contains("futebol") || n.contains("brasileir") { return "sportscourt" }
        if n.contains("news") || n.contains("noticia") { return "newspaper" }
        if n.contains("movie") || n.contains("cinema") || n.contains("film") { return "film" }
        if n.contains("kid") || n.contains("infanti") || n.contains("child") { return "figure.child" }
        if n.contains("music") || n.contains("musica") { return "music.note" }
        if n.contains("doc") { return "book" }
        if n.contains("hbo") || n.contains("telecine") || n.contains("premium") { return "star.circle" }
        return "tv"
    }
}

// MARK: - Channel list + search

private struct ChannelListPane: View {
    let source: ChannelSource
    let profileId: String
    let favoriteIds: [Int]
    @Binding var searchText: String
    let selectedChannel: LiveEntity?
    let onSelect: (LiveEntity) -> Void
    let onListChange: ([LiveEntity]) -> Void

    // Channels for the selected category sourced from a @Query, not the
    // `category.lives` relationship: a background sync (Refresh / profile add)
    // writes on the sync actor's context, and only a @Query re-runs on that
    // save — a materialized relationship array stays stale until the view is
    // rebuilt. Profile + adult scoping are part of the predicate.
    @Query private var categoryChannels: [LiveEntity]

    @FocusState private var searchFocused: Bool

    init(
        source: ChannelSource,
        profileId: String,
        hideAdult: Bool,
        favoriteIds: [Int],
        searchText: Binding<String>,
        selectedChannel: LiveEntity?,
        onSelect: @escaping (LiveEntity) -> Void,
        onListChange: @escaping ([LiveEntity]) -> Void
    ) {
        self.source = source
        self.profileId = profileId
        self.favoriteIds = favoriteIds
        self._searchText = searchText
        self.selectedChannel = selectedChannel
        self.onSelect = onSelect
        self.onListChange = onListChange

        let includeAdult = !hideAdult
        let filter: Predicate<LiveEntity>
        switch source {
        case .category(let category):
            // No selection → a categoryId no channel has, so the query is empty.
            let categoryId = category?.categoryId ?? "\u{01}"
            filter = #Predicate<LiveEntity> { live in
                live.categoryId == categoryId
                    && live.profile?.id == profileId
                    && (includeAdult || live.adult != "1")
            }
        case .favorites(let ids):
            filter = #Predicate<LiveEntity> { live in
                ids.contains(live.streamId)
                    && live.profile?.id == profileId
                    && (includeAdult || live.adult != "1")
            }
        }
        _categoryChannels = Query(filter: filter, sort: [SortDescriptor(\LiveEntity.num)])
    }

    private var category: CategoryEntity? {
        if case .category(let category) = source { return category }
        return nil
    }

    private var isFavorites: Bool {
        if case .favorites = source { return true }
        return false
    }

    /// Active profile's channels for the current source. Favourites keep the
    /// order they were added in.
    private var categoryChannelsForProfile: [LiveEntity] {
        guard isFavorites else { return categoryChannels }
        let order = Dictionary(favoriteIds.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return categoryChannels.sorted { (order[$0.streamId] ?? .max) < (order[$1.streamId] ?? .max) }
    }

    // Debounced mirror of `searchText`. The channel list can hold 1,000+ rows,
    // so filtering + sorting it on every keystroke janks on Apple TV. We only
    // apply the query once the user pauses typing (matches SearchView's 600ms
    // window); clearing applies immediately so the full list snaps back.
    @State private var appliedSearch: String = ""

    private var visibleChannels: [LiveEntity] {
        guard category != nil || isFavorites else { return [] }
        let source = categoryChannelsForProfile
        let filtered = appliedSearch.isEmpty
            ? source
            : source.filter { $0.name.localizedCaseInsensitiveContains(appliedSearch) }
        return isFavorites ? filtered : filtered.sorted { $0.num < $1.num }
    }

    var body: some View {
        LivePanel(
            title: titleText,
            subtitle: subtitleText
        ) {
            searchField
                .focusSection()
            content
                .focusSection()
        }
        .onAppear { onListChange(visibleChannels) }
        .onChange(of: visibleChannels.map(\.streamId)) { _, _ in
            onListChange(visibleChannels)
        }
        .task(id: searchText) {
            if searchText.isEmpty {
                appliedSearch = ""
                return
            }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            appliedSearch = searchText
        }
    }

    private var titleText: String {
        isFavorites ? "Favorites" : "Channels"
    }

    private var subtitleText: String {
        if isFavorites {
            let count = categoryChannelsForProfile.count
            return count == 0
                ? "Add channels from the preview pane"
                : "\(count) favorite \(count == 1 ? "channel" : "channels")"
        }
        guard let category else { return "Pick a category" }
        let channelCount = categoryChannelsForProfile.count
        return "\(channelCount) \(channelCount == 1 ? "channel" : "channels") found in \(category.name.uppercased())"
    }

    private var searchField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 20) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search channels", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private var content: some View {
        if category == nil && !isFavorites {
            placeholder("list.bullet", "Select a category")
        } else if visibleChannels.isEmpty {
            if isFavorites && appliedSearch.isEmpty {
                placeholder("star", "No favorites yet. Pick a channel, then choose Add to Favorites in the preview pane.")
            } else {
                placeholder(
                    "magnifyingglass",
                    appliedSearch.isEmpty ? "No channels here yet" : "No matches"
                )
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(visibleChannels, id: \.streamId) { channel in
                        ChannelRow(
                            channel: channel,
                            isPreviewed: selectedChannel?.streamId == channel.streamId,
                            isFavorite: favoriteIds.contains(channel.streamId),
                            onSelect: { onSelect(channel) }
                        )
                    }
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 4)
            }
            .liveScrollFade()
        }
    }

    private func placeholder(_ icon: String, _ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

private struct ChannelRow: View {
    let channel: LiveEntity
    let isPreviewed: Bool
    let isFavorite: Bool
    let onSelect: () -> Void
    @State private var isAnimating = false
    /// Programme on air now, from the guide (nil until loaded / no guide).
    @State private var nowTitle: String?

    @Environment(\.iptvRepository) private var repository

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 16) {
            LazyImage(url: channel.streamIconURL) { state in
                if let image = state.image {
                    image.resizable().scaledToFit()
                } else {
                    Image(systemName: "tv")
                        .foregroundStyle(.secondary)
                        .scaledToFit()
                }
            }
            .frame(width: 52, height: 52)
            .padding(8)
            .cardSurface(cornerRadius: 12)

            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(channel.name.uppercased())
                            .font(.caption)
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if isFavorite {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                                .accessibilityLabel("Favorite")
                        }
                    }

                    if isPreviewed {
                        HStack(spacing: 6) {
                            Circle().fill(Color.red).frame(width: 6, height: 6)
                                .scaleEffect(isAnimating ? 1.8 : 1.0) // Animate from 100% to 180% size
                                .onAppear {
                                    withAnimation(.easeIn.speed(0.9).delay(0.1).repeatForever()) {
                                        isAnimating = true
                                    }
                                }
                                .onDisappear { isAnimating = false }
                            Text(verbatim: " LIVE  ·  \(secondaryText)")
                                .font(.caption)
                                .bold()
                                .foregroundStyle(Color.accentColor)
                                .lineLimit(1)
                        }
                    } else {
                        Text(verbatim: secondaryText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.borderless)
            .focused($isFocused)
            .animation(.smooth(duration: 0.18), value: isFocused)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .task(id: channel.streamId) {
            nowTitle = nil
            guard channel.hasGuide, let repository else { return }
            // Short delay so rows flicked past while scrolling never fetch.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let upcoming = await EPGCache.shared.upcoming(streamId: channel.streamId, repository: repository)
            guard !Task.isCancelled else { return }
            nowTitle = upcoming.first { $0.isAiring() }?.title
        }
    }

    /// "Channel 12 · Evening News" once the guide has loaded.
    private var secondaryText: String {
        if let nowTitle, !nowTitle.isEmpty {
            return "Channel \(channel.num)  ·  \(nowTitle)"
        }
        return "Channel \(channel.num)"
    }

    @ViewBuilder
    private var rowBackground: some View {
        // Border-less focus indicator (fill only) so when a focused row is at
        // the panel's top/bottom edge, no stroke gets clipped by the panel
        // clipShape. The fade-mask handles partial-visibility gracefully.
        let shape = RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
        if isFocused {
            shape.fill(Color.accentColor.opacity(0.28))
        } else if isPreviewed {
            shape.fill(Color.accentColor.opacity(0.14))
        } else {
            shape.fill(.ultraThinMaterial.opacity(0.5))
        }
    }
}

// MARK: - Preview pane

private struct PreviewPane: View {
    @Bindable var viewModel: LiveViewModel
    let isFavorite: Bool
    let onToggleFavorite: () -> Void
    @State private var showCatchup = false
    @State private var isAnimating = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.panel) {
            playerCard
            infoCard
        }
        // Fill the full column height and anchor to the top so the player card
        // stays put regardless of the info card's content height — matching the
        // sidebar and channel-list panels (which top-anchor via LivePanel).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .fullScreenCover(item: $viewModel.fullscreen) { request in
            // Native AVPlayerViewController via the same VideoPlayerView
            // movies/series use (audio/subtitle pickers, Info, AirPlay), plus
            // Previous/Next Channel in the transport bar.
            LiveFullscreenPlayer(request: request)
        }
        .fullScreenCover(isPresented: $showCatchup) {
            if let channel = viewModel.selectedChannel {
                CatchupView(channel: channel)
            }
        }
    }

    // Passive display only — never focusable. Fullscreen entry happens via the
    // borderedProminent button in `infoCard`.
    private var playerCard: some View {
        ZStack(alignment: .topTrailing) {
            playerSurface
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(colorScheme == .dark ? Color.black : Color.gray)
                .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
                        .strokeBorder(Color.hairline, lineWidth: 1)
                )

            if viewModel.previewURL != nil {
                HStack(spacing: 12) {
                    liveBadge
                    qualityBadge
                }
                .padding(16)
                .allowsHitTesting(false)
            }
        }
        .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
    }

    private var liveBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(.white).frame(width: 6, height: 6)
                .scaleEffect(isAnimating ? 1.8 : 1.0) // Animate from 100% to 180% size
                .onAppear {
                    withAnimation(.easeIn.speed(0.9).delay(0.1).repeatForever()) {
                        isAnimating = true
                    }
                }
                .onDisappear { isAnimating = false }
            Text(" LIVE")
                .font(.caption.bold())
                .tracking(1)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.red, in: Capsule())
    }

    private var qualityBadge: some View {
        Text("HD  ·  HLS")
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassCapsule()
    }

    @ViewBuilder
    private var infoCard: some View {
        if let channel = viewModel.selectedChannel {
            LivePanel(
                title: channel.name.capitalized,
                subtitle: "Channel \(channel.num)"
            ) {
                GuideSummary(
                    guide: viewModel.guide,
                    isLoading: viewModel.isGuideLoading,
                    hasGuide: channel.hasGuide
                )
                .padding(.bottom, 6)

                if viewModel.previewURL != nil {
                    VStack(spacing: 16) {
                        Button {
                            viewModel.openFullscreen()
                        } label: {
                            Label("Full Screen", systemImage: "rectangle.inset.filled.and.arrow.up.forward.fill")
                                .font(.callout)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.glassProminent)

                        HStack(spacing: 16) {
                            Button(action: onToggleFavorite) {
                                Label(
                                    isFavorite ? "Remove Favorite" : "Add to Favorites",
                                    systemImage: isFavorite ? "star.slash" : "star"
                                )
                                .font(.callout)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.glass)

                            if channel.hasCatchup {
                                Button {
                                    showCatchup = true
                                } label: {
                                    Label("Catch-up", systemImage: "clock.arrow.circlepath")
                                        .font(.callout)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                }
                                .buttonStyle(.glass)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            LivePanel(
                title: "Preview",
                subtitle: nil
            ) {
                Text("Select a channel to see what's on, then choose Full Screen to watch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .frame(maxHeight: 270)
        }
    }

    @ViewBuilder
    private var playerSurface: some View {
        if viewModel.isPreviewLoading {
            ZStack {
                Color.black
                ProgressView().controlSize(.large)
            }
        } else {
            placeholderSurface
        }
    }

    // Placeholder art shown in the preview pane. Live playback happens in the
    // fullscreen AVPlayer (via the "Full Screen" button), which brokers
    // self-signed streams; there is no inline preview player. Icon-only — the
    // guidance lives once in the info card below, not duplicated here.
    private var placeholderSurface: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            Image(systemName: "play.tv")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Guide summary (now / next)

/// Now/next block for the preview pane. Re-evaluates every 30s so the progress
/// bar advances and "next" rolls into "now" without a refetch.
private struct GuideSummary: View {
    let guide: [EPGListing]
    let isLoading: Bool
    let hasGuide: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let date = context.date
            let current = guide.first { $0.isAiring(at: date) }
            let upcoming = guide.filter { $0.start >= (current?.end ?? date) }.prefix(2)

            VStack(alignment: .leading, spacing: 14) {
                if isLoading {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Loading guide…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let current {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("NOW")
                            .font(.caption2.bold())
                            .tracking(1.5)
                            .foregroundStyle(Color.accentColor)
                        Text(current.title.isEmpty ? "Untitled programme" : current.title)
                            .font(.callout.weight(.semibold))
                            .lineLimit(2)
                        HStack(spacing: 12) {
                            ProgressView(value: current.progress(at: date))
                                .tint(Color.progressFill)
                            Text(EPGFormat.timeRange(current))
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                    }
                    ForEach(Array(upcoming)) { listing in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(EPGFormat.time(listing.start))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 90, alignment: .leading)
                            Text(listing.title.isEmpty ? "Untitled programme" : listing.title)
                                .font(.caption)
                                .lineLimit(1)
                        }
                    }
                } else {
                    Label(
                        hasGuide ? "No guide information right now" : "No guide for this channel",
                        systemImage: "calendar.badge.exclamationmark"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview("Live TV — populated") {
    let schema = Schema([CategoryEntity.self, LiveEntity.self, MovieEntity.self, SerieEntity.self, Profile.self])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: schema, configurations: config)
    let context = container.mainContext

    let sampleCategories: [(String, [String])] = [
        ("Sports",      ["ESPN HD", "Premier League", "Sky Sports F1", "NBA TV", "Tennis Channel"]),
        ("News",        ["CNN International", "BBC World News", "Sky News", "Bloomberg TV"]),
        ("Movies",      ["HBO", "Cinemax", "Showtime", "Starz", "Movie Network"]),
        ("Kids",        ["Cartoon Network", "Nickelodeon", "Disney Channel"]),
        ("Music",       ["MTV", "VH1", "Music Choice"]),
        ("Documentary", ["National Geographic", "Discovery", "History Channel"])
    ]

    for (i, (name, channelNames)) in sampleCategories.enumerated() {
        let category = CategoryEntity(
            categoryId: "live-\(i)",
            name: name,
            kind: .live,
            sortOrder: i
        )
        context.insert(category)
        for (j, channelName) in channelNames.enumerated() {
            let live = LiveEntity(
                streamId: i * 100 + j,
                num: j + 1,
                name: channelName,
                streamType: "live",
                streamIcon: "",
                epgChannelId: nil,
                added: "0",
                adult: "0",
                categoryId: "live-\(i)",
                customSid: nil,
                tvArchive: 0,
                directSource: "",
                category: category
            )
            context.insert(live)
            category.lives.append(live)
        }
    }
    try? context.save()

    return LiveView()
        .modelContainer(container)
}

#Preview("Live TV — empty") {
    let schema = Schema([CategoryEntity.self, LiveEntity.self, MovieEntity.self, SerieEntity.self, Profile.self])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: schema, configurations: config)
    return LiveView()
        .modelContainer(container)
}
