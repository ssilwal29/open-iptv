import SwiftUI
import NukeUI

struct AsyncImageView: View {
    let url: URL?
    var imageWidth: CGFloat = 250
    var imageHeight: CGFloat = 375
    var contentMode: ContentMode = .fit

    var body: some View {
        LazyImage(url: url) { state in
            if let image = state.image {
                image
                    .resizable()
                    .aspectRatio(contentMode: contentMode == .fill ? .fill : .fit)
            } else if state.error != nil {
                placeholderFailure
            } else {
                placeholderLoading
            }
        }
        .priority(.normal)
        .frame(width: imageWidth, height: imageHeight)
        .clipped()
    }

    private var placeholderLoading: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .frame(width: imageWidth, height: imageHeight)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.gray.opacity(0.2),
                    Color.gray.opacity(0.3),
                    Color.gray.opacity(0.2)
                ]),
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    private var placeholderFailure: some View {
        HStack {
            Spacer()
            Image(systemName: "photo")
                .imageScale(.large)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(width: imageWidth, height: imageHeight)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.gray.opacity(0.2),
                    Color.gray.opacity(0.3),
                    Color.gray.opacity(0.2)
                ]),
                startPoint: .top, endPoint: .bottom
            )
        )
    }
}

#Preview {
    AsyncImageView(url: URL(string: "https://picsum.photos/400/600"))
}
