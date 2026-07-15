import SwiftUI
import SwiftData

struct EditCredentialsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// The profile being edited. Required — unlike the previous singleton
    /// design where `profiles.first` was implicitly the only profile.
    let profile: Profile

    @State private var viewModel = SetupViewModel()
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var profileName = ""

    var body: some View {
        // Presented as a sheet, which supplies its own dimmed background — no
        // AmbientBackdrop here, otherwise its gradient fills the sheet and reads
        // as a gradient border around the centered form panel.
        CredentialsForm(
                title: "Edit Credentials",
                subtitle: "Update your Xtream account details.",
                serverURL: $serverURL,
                username: $username,
                password: $password,
                profileName: $profileName,
                isLoading: viewModel.isLoading,
                errorMessage: viewModel.errorMessage,
                primaryTitle: "Save",
                primaryLoadingTitle: "Saving…",
                primaryIcon: "checkmark",
                onPrimary: { Task { await save() } },
                onCancel: { dismiss() },
                requiresPassword: false
            )
        .padding(.horizontal, 60)
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand { dismiss() }
        .task {
            // Prefill the known fields; password is re-entered for security.
            serverURL = profile.serverURL
            username = profile.username
            profileName = profile.name
        }
    }

    private func save() async {
        // Blank password means "keep the current one" — re-validate with the
        // saved credential rather than forcing the user to retype it.
        let effectivePassword = password.isEmpty ? profile.resolvedPassword() : password
        let updatedId = await viewModel.authenticate(
            serverURL: serverURL,
            username: username,
            password: effectivePassword,
            name: profileName,
            profileId: profile.id,
            modelContext: modelContext
        )
        if updatedId != nil { dismiss() }
    }
}
