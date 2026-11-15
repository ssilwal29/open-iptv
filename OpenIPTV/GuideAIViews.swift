import SwiftUI

// MARK: - Progress pill

/// Compact, non-focusable "Formatting guide · 18 of 40" pill shown while the
/// AI formatter is working. Renders nothing when idle.
struct EPGFormattingStatus: View {
    private var formatter: EPGFormatter { .shared }

    var body: some View {
        Group {
            if formatter.isRunning {
                HStack(spacing: 14) {
                    Image(systemName: "sparkles")
                        .symbolEffect(.pulse, options: .repeating)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text("Formatting guide")
                                .font(.caption.weight(.semibold))
                            Text("\(min(formatter.runCompleted + formatter.runFailed, formatter.runTotal)) of \(formatter.runTotal)")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: formatter.runFraction)
                            .progressViewStyle(.linear)
                            .tint(Color.progressFill)
                            .frame(width: 220)
                            .animation(.smooth(duration: 0.3), value: formatter.runFraction)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .glassCapsule()
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .allowsHitTesting(false)
                .accessibilityElement(children: .combine)
            }
        }
        .animation(.smooth, value: formatter.isRunning)
    }
}

/// Small "AI" marker next to formatted guide text.
struct FormattedBadge: View {
    var body: some View {
        Image(systemName: "sparkles")
            .font(.caption2)
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel("Formatted by AI")
    }
}

// MARK: - API key sheet

struct OpenRouterKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("OpenRouter API Key")
                .font(.displayTitle)
            Text("Create a key at openrouter.ai/keys and enter it here. It's stored in the Keychain on this Apple TV and only sent to OpenRouter.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("sk-or-…", text: $key)
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($fieldFocused)
                .onSubmit(save)

            HStack(spacing: 24) {
                Button("Save", action: save)
                    .buttonStyle(.glassProminent)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
            }
        }
        .padding(60)
        .frame(maxWidth: 1000)
        .defaultFocus($fieldFocused, true)
        .onExitCommand { dismiss() }
    }

    private func save() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        EPGFormatter.shared.setAPIKey(trimmed)
        dismiss()
    }
}

// MARK: - Model sheet

struct OpenRouterModelSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Model")
                .font(.displayTitle)
            Text("The OpenRouter model id used to format the guide. A fast, low-cost model is best.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField(OpenRouterClient.defaultModel, text: $model)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($fieldFocused)
                .onSubmit(save)

            HStack(spacing: 24) {
                Button("Save", action: save)
                    .buttonStyle(.glassProminent)
                Button("Use Default") {
                    model = OpenRouterClient.defaultModel
                    save()
                }
                .buttonStyle(.glass)
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
            }
        }
        .padding(60)
        .frame(maxWidth: 1000)
        .defaultFocus($fieldFocused, true)
        .onExitCommand { dismiss() }
        .onAppear { model = EPGFormatter.shared.model }
    }

    private func save() {
        EPGFormatter.shared.setModel(model)
        dismiss()
    }
}
