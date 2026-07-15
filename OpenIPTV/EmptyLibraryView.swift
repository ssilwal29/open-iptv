import SwiftUI

struct EmptyLibraryView: View {
    let message: String

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(48)
        .glassCard()
        .frame(maxWidth: 700)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
