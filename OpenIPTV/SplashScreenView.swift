import SwiftUI

/// First-frame splash. Renders on top of `RootView` for ~1.8s while SwiftData
/// opens its store and the initial @Query resolves, then fades out. Pure
/// cosmetic — does not gate any data flow; the underlying `RootView` is live
/// and ticking the whole time.
struct SplashScreenView: View {
    @State private var settled = false

    var body: some View {
        ZStack {
            AmbientBackdrop()
                .ignoresSafeArea()

            Wordmark(size: 84)
                .opacity(settled ? 1 : 0)
                .scaleEffect(settled ? 1.0 : 0.88)
                .blur(radius: settled ? 0 : 14)
                .shadow(
                    color: Color.accentColor.opacity(settled ? 0.45 : 0),
                    radius: 40,
                    x: 0,
                    y: 0
                )
        }
        .task {
            // Snappy entry so the logo lands at full opacity within ~½ a
            // second — leaves the bulk of the splash window with the logo
            // fully visible rather than fading in.
            withAnimation(.smooth(duration: 0.45)) {
                settled = true
            }
        }
    }
}

#Preview {
    SplashScreenView()
}
