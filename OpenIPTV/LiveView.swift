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

    @Environment(\.iptvRepository) private var repository
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = LiveViewModel()

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
                        selectedCategoryId: viewModel.selectedCategory?.compositeId,
                        onSelectCategory: { category in
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
                        category: viewModel.selectedCategory,
                        profileId: activeProfileId,
                        searchText: $viewModel.searchText,
                        selectedChannel: viewModel.selectedChannel,
                        onSelect: { channel in
                            viewModel.selectChannel(channel, repository: repository)
                        }
                    )
                    .frame(width: proxy.size.width * 0.44)
                    .focusSection()

                    PreviewPane(viewModel: viewModel)
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
                viewModel.selectedCategory = categories.first
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
    let category: CategoryEntity?
    let profileId: String
    @Binding var searchText: String
    let selectedChannel: LiveEntity?
    let onSelect: (LiveEntity) -> Void

    // Channels for the selected category sourced from a @Query, not the
    // `category.lives` relationship: a background sync (Refresh / profile add)
    // writes on the sync actor's context, and only a @Query re-runs on that
    // save — a materialized relationship array stays stale until the view is
    // rebuilt. `categoryId` isn't profile-unique, so scope by profile in memory.
    @Query private var categoryChannels: [LiveEntity]

    @FocusState private var searchFocused: Bool

    init(
        category: CategoryEntity?,
        profileId: String,
        searchText: Binding<String>,
        selectedChannel: LiveEntity?,
        onSelect: @escaping (LiveEntity) -> Void
    ) {
        self.category = category
        self.profileId = profileId
        self._searchText = searchText
        self.selectedChannel = selectedChannel
        self.onSelect = onSelect

        // No selection → a categoryId no channel has, so the query is empty.
        let categoryId = category?.categoryId ?? "\u{01}"
        _categoryChannels = Query(
            filter: #Predicate<LiveEntity> { $0.categoryId == categoryId },
            sort: [SortDescriptor(\LiveEntity.num)]
        )
    }

    /// Active profile's channels in the selected category.
    private var categoryChannelsForProfile: [LiveEntity] {
        categoryChannels.filter { $0.profile?.id == profileId }
    }

    // Debounced mirror of `searchText`. The channel list can hold 1,000+ rows,
    // so filtering + sorting it on every keystroke janks on Apple TV. We only
    // apply the query once the user pauses typing (matches SearchView's 600ms
    // window); clearing applies immediately so the full list snaps back.
    @State private var appliedSearch: String = ""

    private var visibleChannels: [LiveEntity] {
        let source: [LiveEntity]
        if category != nil {
            source = categoryChannelsForProfile
        } else {
            return []
        }
        let filtered = appliedSearch.isEmpty
            ? source
            : source.filter { $0.name.localizedCaseInsensitiveContains(appliedSearch) }
        return filtered.sorted { $0.num < $1.num }
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
        "Channels"
    }

    private var subtitleText: String {
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
        if category == nil {
            placeholder("list.bullet", "Select a category")
        } else if visibleChannels.isEmpty {
            placeholder(
                "magnifyingglass",
                appliedSearch.isEmpty ? "No channels here yet" : "No matches"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(visibleChannels, id: \.streamId) { channel in
                        ChannelRow(
                            channel: channel,
                            isPreviewed: selectedChannel?.streamId == channel.streamId,
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
    let onSelect: () -> Void
    @State private var isAnimating = false

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
                    Text(channel.name.uppercased())
                        .font(.caption)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)

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
                            Text(verbatim: " LIVE  ·  Channel \(channel.num)")
                                .font(.caption)
                                .bold()
                                .foregroundStyle(Color.accentColor)
                        }
                    } else {
                        Text(verbatim: "Channel \(channel.num)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
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
    @State private var showFullscreen = false
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
        .fullScreenCover(isPresented: $showFullscreen) {
            if let url = viewModel.previewURL, let channel = viewModel.selectedChannel {
                // Native AVPlayerViewController via the same VideoPlayerView
                // movies/series use. Gives system focus, scrubbing (where
                // applicable), audio/subtitle pickers, Info, and AirPlay — and
                // brokers self-signed streams through StreamURLResolver.
                VideoPlayerView(url: url, title: channel.name, isLive: true)
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
                if viewModel.previewURL != nil {
                    HStack(spacing: 10) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        Text("Streaming live")
                    }
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)
                    .padding(.bottom, 10)

                    Button {
                        showFullscreen = true
                    } label: {
                        Label("Full Screen", systemImage: "rectangle.inset.filled.and.arrow.up.forward.fill")
                            .font(.callout)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.glassProminent)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(maxHeight: 330)
        } else {
            LivePanel(
                title: "Preview",
                subtitle: nil
            ) {
                Text("Select a channel to preview it here, then tap the preview to go full screen.")
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
