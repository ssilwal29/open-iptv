import SwiftUI
import SwiftData

// MARK: - Add account

/// Adds another Xtream account and makes it active. The new profile's first
/// sync runs in the background (ContentView re-bootstraps on the switch).
struct AddAccountView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @AppStorage("activeProfileId") private var activeProfileId: String = ""

    @State private var viewModel = SetupViewModel()
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var profileName = ""

    var body: some View {
        CredentialsForm(
            title: "Add Account",
            subtitle: "Enter another Xtream Codes account. You can switch between accounts in Settings.",
            serverURL: $serverURL,
            username: $username,
            password: $password,
            profileName: $profileName,
            isLoading: viewModel.isLoading,
            errorMessage: viewModel.errorMessage,
            primaryTitle: "Add",
            primaryLoadingTitle: "Connecting…",
            primaryIcon: "plus.circle.fill",
            onPrimary: { Task { await add() } },
            onCancel: { dismiss() }
        )
        .padding(.horizontal, 60)
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand { dismiss() }
    }

    private func add() async {
        let newId = await viewModel.authenticate(
            serverURL: serverURL,
            username: username,
            password: password,
            name: profileName,
            modelContext: modelContext
        )
        if let newId {
            activeProfileId = newId
            dismiss()
        }
    }
}

// MARK: - Parental PIN

/// Collects a 4-digit PIN for one of: unlocking (verify), setting (enter +
/// confirm), changing (verify, enter + confirm) or removing (verify).
struct ParentalPINSheet: View {
    enum Purpose {
        case unlock, set, change, remove
    }

    private enum Stage {
        case verify, enterNew, confirmNew
    }

    let profile: Profile
    let purpose: Purpose
    let onSuccess: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var stage: Stage
    @State private var entry = ""
    @State private var newPIN = ""
    @State private var errorMessage: String?
    @FocusState private var fieldFocused: Bool

    init(profile: Profile, purpose: Purpose, onSuccess: @escaping () -> Void) {
        self.profile = profile
        self.purpose = purpose
        self.onSuccess = onSuccess
        _stage = State(initialValue: purpose == .set ? .enterNew : .verify)
    }

    private var title: String {
        switch purpose {
        case .unlock: return "Enter PIN"
        case .set: return "Set Parental PIN"
        case .change: return "Change Parental PIN"
        case .remove: return "Remove Parental PIN"
        }
    }

    private var prompt: String {
        switch stage {
        case .verify: return "Enter the current \(Profile.parentalPINLength)-digit PIN."
        case .enterNew: return "Choose a \(Profile.parentalPINLength)-digit PIN."
        case .confirmNew: return "Enter the new PIN again to confirm."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(title)
                .font(.displayTitle)
            Text(prompt)
                .font(.callout)
                .foregroundStyle(.secondary)

            SecureField("PIN", text: $entry)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($fieldFocused)
                .onSubmit(submit)
                .onChange(of: entry) { _, value in
                    let digits = String(value.filter(\.isNumber).prefix(Profile.parentalPINLength))
                    if digits != value { entry = digits }
                }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 24) {
                Button("Continue", action: submit)
                    .buttonStyle(.glassProminent)
                    .disabled(entry.count != Profile.parentalPINLength)
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
            }
        }
        .padding(60)
        .frame(maxWidth: 900)
        .onExitCommand { dismiss() }
        .defaultFocus($fieldFocused, true)
    }

    private func submit() {
        guard entry.count == Profile.parentalPINLength else {
            errorMessage = "The PIN must be \(Profile.parentalPINLength) digits."
            return
        }
        errorMessage = nil
        switch stage {
        case .verify:
            guard profile.verifyParentalPIN(entry) else {
                errorMessage = "Incorrect PIN."
                entry = ""
                return
            }
            switch purpose {
            case .unlock:
                finish()
            case .remove:
                profile.clearParentalPIN()
                finish()
            case .change, .set:
                stage = .enterNew
                entry = ""
            }
        case .enterNew:
            newPIN = entry
            entry = ""
            stage = .confirmNew
        case .confirmNew:
            guard entry == newPIN else {
                errorMessage = "The PINs didn't match. Try again."
                entry = ""
                newPIN = ""
                stage = .enterNew
                return
            }
            profile.setParentalPIN(newPIN)
            finish()
        }
    }

    private func finish() {
        onSuccess()
        dismiss()
    }
}
