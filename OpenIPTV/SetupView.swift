import SwiftUI
import SwiftData

struct SetupView: View {
    @Environment(\.modelContext) private var modelContext
    @Binding var isConfigured: Bool
    @AppStorage("activeProfileId") private var activeProfileId: String = ""
    @State private var viewModel = SetupViewModel()
    @State private var username = ""
    @State private var password = ""
    @State private var domain = ""
    @State private var profileName = ""

    var body: some View {
        // First-run setup — full brand + form layout over the ambient
        // backdrop (this fills the whole screen, not a floating panel).
        ZStack {
            AmbientBackdrop()
            HStack(spacing: 80) {
                brandingColumn
                form
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 60)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Form

    private var form: some View {
        CredentialsForm(
            title: "Connect your playlist",
            subtitle: "Enter your Xtream Codes account details.",
            serverURL: $domain,
            username: $username,
            password: $password,
            profileName: $profileName,
            isLoading: viewModel.isLoading,
            errorMessage: viewModel.errorMessage,
            primaryTitle: "Connect",
            primaryLoadingTitle: "Connecting…",
            primaryIcon: "arrow.right.circle.fill",
            onPrimary: connect,
            // First-run has nowhere to cancel to.
            onCancel: nil
        )
    }

    private func connect() {
        Task {
            let newId = await viewModel.authenticate(
                serverURL: domain,
                username: username,
                password: password,
                name: profileName,
                modelContext: modelContext
            )
            if let newId {
                // New profile is now the active one. Existing single-profile
                // builds also benefit: legacy data (no profile relationship
                // yet) gets backfilled to this new id by RootView's
                // backfillLegacyProfileRelationships() pass.
                activeProfileId = newId
                isConfigured = true
            }
        }
    }

    // MARK: Branding column

    private var brandingColumn: some View {
        VStack(alignment: .leading, spacing: 28) {
            Wordmark(size: 60)

            VStack(alignment: .leading, spacing: 12) {
                Text("Welcome to OpenIPTV")
                    .font(.displayTitle)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)

                Text("Movies, series, and live TV from your Xtream Codes account")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    SetupView(isConfigured: .constant(false))
}
