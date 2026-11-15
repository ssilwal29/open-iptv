import SwiftUI
import SwiftData
import NukeUI

private enum SearchDesign {
    static let topInset: CGFloat = 10
}

struct SearchView: View {
    @AppStorage("activeProfileId") private var activeProfileId: String = ""

    @Query private var profiles: [Profile]

    @State private var query: String = ""
    @State private var appliedQuery: String = ""

    private let minSearchLength = 3
    private let debounceNanoseconds: UInt64 = 600_000_000

    private var activeProfile: Profile? {
        profiles.first(where: { $0.id == activeProfileId })
    }

    private var hideAdult: Bool {
        activeProfile?.hideAdultContent ?? true
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AmbientBackdrop()
                content
            }
            .searchable(
                text: $query,
                placement: .automatic,
                prompt: "Search Movies, Series and Channels"
            )
            .mask(scrollFadeMask)
            .task(id: query) {
                let trimmed = query.trimmingCharacters(in: .whitespaces)
                guard trimmed.count >= minSearchLength else {
                    appliedQuery = ""
                    return
                }
                try? await Task.sleep(nanoseconds: debounceNanoseconds)
                guard !Task.isCancelled else { return }
                appliedQuery = trimmed
            }
        }
    }

    private var scrollFadeMask: some View {
        GeometryReader { proxy in
            let opaqueStart = SearchDesign.topInset / proxy.size.height
            let fadeStart = max(0, opaqueStart - 0.035)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: fadeStart),
                    .init(color: .black, location: opaqueStart),
                    .init(color: .black, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        if appliedQuery.isEmpty {
            SearchPlaceholder(title: "Search Movies, Series and Channels")
        } else {
            // Dynamic-query child: filtering + sorting happen in SwiftData/SQLite
            // scoped to the active profile, so we never flatMap the whole library
            // into memory. Re-inits (and thus re-queries) only when appliedQuery
            // changes, which is already debounced above.
            SearchResultsView(query: appliedQuery, profileId: activeProfileId, hideAdult: hideAdult)
        }
    }
}

private struct SearchPlaceholder: View {
    let title: String
    var systemImage: String = "magnifyingglass"

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SearchResultsView: View {
    @Query private var movies: [MovieEntity]
    @Query private var series: [SerieEntity]
    @Query private var channels: [LiveEntity]

    @State private var livePlayback: LivePlaybackRequest?

    private let query: String

    init(query: String, profileId: String, hideAdult: Bool) {
        self.query = query
        let includeAdult = !hideAdult

        let moviePredicate = #Predicate<MovieEntity> { movie in
            movie.profile?.id == profileId
                && (includeAdult || !movie.isAdult)
                && movie.name.localizedStandardContains(query)
        }
        _movies = Query(filter: moviePredicate, sort: \MovieEntity.name)

        let seriePredicate = #Predicate<SerieEntity> { serie in
            serie.profile?.id == profileId
                && serie.name.localizedStandardContains(query)
        }
        _series = Query(filter: seriePredicate, sort: \SerieEntity.name)

        let channelPredicate = #Predicate<LiveEntity> { live in
            live.profile?.id == profileId
                && (includeAdult || live.adult != "1")
                && live.name.localizedStandardContains(query)
        }
        _channels = Query(filter: channelPredicate, sort: \LiveEntity.name)
    }

    var body: some View {
        if movies.isEmpty && series.isEmpty && channels.isEmpty {
            SearchPlaceholder(title: "No matches for \"\(query)\"")
        } else {
            results
        }
    }

    private var movieColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: PosterSize.rowSpacing, alignment: .top),
            count: PosterSize.gridColumnCount
        )
    }

    private var serieColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: PosterSize.rowSpacing, alignment: .top),
            count: PosterSize.gridColumnCount
        )
    }

    private var results: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 48) {
                if !movies.isEmpty {
                    sectionHeader(title: "Movies", count: movies.count)
                    LazyVGrid(columns: movieColumns, spacing: PosterSize.rowSpacing) {
                        ForEach(movies) { movie in
                            MoviePosterTile(movie: movie)
                        }
                    }
                }

                if !channels.isEmpty {
                    sectionHeader(title: "Channels", count: channels.count)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: PosterSize.rowSpacing) {
                            ForEach(Array(channels.enumerated()), id: \.element.streamId) { index, channel in
                                ChannelSearchTile(channel: channel) {
                                    livePlayback = LivePlaybackRequest(channels: channels, startIndex: index)
                                }
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    .scrollClipDisabled(true)
                }

                if !series.isEmpty {
                    sectionHeader(title: "Series", count: series.count)
                    LazyVGrid(columns: serieColumns, spacing: PosterSize.rowSpacing) {
                        ForEach(series) { serie in
                            SeriePosterTile(serie: serie)
                        }
                    }
                }

                Spacer(minLength: 40)
            }
            .padding(.horizontal, 56)
            .padding(.top, 32)
        }
        .scrollClipDisabled(true)
        .fullScreenCover(item: $livePlayback) { LiveFullscreenPlayer(request: $0) }
    }

    private func sectionHeader(title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.sectionTitle)
            Text("\(count)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
        }
    }
}

/// Live channel result: logo + name; plays full screen on select.
private struct ChannelSearchTile: View {
    let channel: LiveEntity
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            VStack(spacing: 14) {
                LazyImage(url: channel.streamIconURL) { state in
                    if let image = state.image {
                        image.resizable().scaledToFit()
                    } else {
                        Image(systemName: "tv")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 140, height: 100)

                Text(channel.name)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 220)
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 16)
        }
        .buttonStyle(.card)
    }
}
