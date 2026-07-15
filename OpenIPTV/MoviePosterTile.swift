import SwiftUI
import SwiftData
import NukeUI

struct MoviePosterTile: View {
    let movie: MovieEntity

    var body: some View {
        NavigationLink {
            MovieDetailView(movie: movie)
        } label: {
            ZStack(alignment: .topTrailing) {
                LazyImage(url: movie.streamIconURL) { state in
                    if let image = state.image {
                        image.resizable().scaledToFill()
                    } else if state.error != nil {
                        posterPlaceholder(systemImage: "photo")
                    } else {
                        posterPlaceholder(systemImage: nil)
                    }
                }
                .priority(.normal)
                .frame(width: PosterSize.width, height: PosterSize.height)
                .clipped()
            }
        }
        .buttonStyle(.card)
    }

    private func posterPlaceholder(systemImage: String?) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.15), Color(white: 0.25)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: PosterSize.width, height: PosterSize.height)
    }
}
