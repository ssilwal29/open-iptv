import SwiftUI
import SwiftData

// MARK: - Design tokens (mirror MovieDetailDesign / SerieDetailDesign)

private enum SettingsDesign {
    static let contentPadding: CGFloat = 32
    // Settings has no filter bar (unlike Movies/Series), so it only needs a
    // small inset to clear the nav — not the filter-bar-sized reserve. Drives
    // both the scroll content inset and the fade-mask opaque start.
    static let topInset: CGFloat = 30
}

// MARK: - Root

struct SettingsView: View {
    @Environment(\.iptvRepository) private var repository
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage("activeProfileId") private var activeProfileId: String = ""

    @Query private var profiles: [Profile]

    @State private var viewModel = SettingsViewModel()
    @State private var showingCredentialsEdit = false
    @State private var selectedSection: SettingsSection = .account

    @Namespace private var settingsScope

    private var activeProfile: Profile? {
        profiles.first(where: { $0.id == activeProfileId }) ?? profiles.first
    }

    /// Counts scoped to the active profile so PlaylistPanel reflects the
    /// library the user is currently looking at. We use `fetchCount` rather
    /// than an `@Query`-then-filter so the main context isn't holding ~15k
    /// MovieEntity/SerieEntity/LiveEntity rows just to display three numbers
    /// — that bloat made every `modelContext.save()` (favorite toggle, etc.)
    /// journal a much larger object graph than necessary.
    private var movieCount: Int {
        let id = activeProfileId
        let d = FetchDescriptor<MovieEntity>(predicate: #Predicate { $0.profile?.id == id })
        return (try? modelContext.fetchCount(d)) ?? 0
    }
    private var serieCount: Int {
        let id = activeProfileId
        let d = FetchDescriptor<SerieEntity>(predicate: #Predicate { $0.profile?.id == id })
        return (try? modelContext.fetchCount(d)) ?? 0
    }
    private var liveCount: Int {
        let id = activeProfileId
        let d = FetchDescriptor<LiveEntity>(predicate: #Predicate { $0.profile?.id == id })
        return (try? modelContext.fetchCount(d)) ?? 0
    }

    var body: some View {
        ZStack {
            AmbientBackdrop()

            GeometryReader { proxy in
                HStack(alignment: .top, spacing: Spacing.panel) {
                    SectionSidebar(selected: $selectedSection)
                        .frame(width: proxy.size.width * 0.26)
                        .focusSection()
                        .prefersDefaultFocus(true, in: settingsScope)

                    detailPane
                        .frame(maxWidth: .infinity)
                        .focusSection()
                }
                .padding(.horizontal, 56)
                .padding(.top, SettingsDesign.topInset)
                .padding(.bottom, 40)
                .focusScope(settingsScope)
            }
        }
        .sheet(isPresented: $showingCredentialsEdit) {
            if let profile = activeProfile {
                EditCredentialsView(profile: profile)
            }
        }
    }

    // MARK: Detail pane

    @ViewBuilder
    private var detailPane: some View {
        switch selectedSection {
        case .account:
            if let profile = activeProfile {
                AccountPanel(
                    profile: profile,
                    onEdit: { showingCredentialsEdit = true }
                )
            } else { notSignedInPanel }
        case .content:
            if let profile = activeProfile {
                PlaylistPanel(
                    profile: profile,
                    movieCount: movieCount,
                    serieCount: serieCount,
                    liveCount: liveCount,
                    viewModel: viewModel,
                    onIntervalChange: { viewModel.setSyncInterval($0, profile: profile, context: modelContext) },
                    onRefresh: { Task { await runRefresh(for: profile) } },
                    onToggleAdult: { viewModel.setHideAdultContent($0, profile: profile, context: modelContext) }
                )
            } else { notSignedInPanel }
        }
    }

    private var notSignedInPanel: some View {
        SettingsPanel(title: "Not signed in", subtitle: nil) {
            Text("There's no account configured.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Helpers

    private func runRefresh(for profile: Profile) async {
        guard let repository else {
            viewModel.refreshMessage = "Not signed in"
            return
        }
        await viewModel.refresh(
            profileId: profile.id,
            repository: repository,
            container: modelContext.container
        )
    }
}

// MARK: - Sections

private enum SettingsSection: CaseIterable, Hashable {
    case account, content

    var title: String {
        switch self {
        case .account: return "Account"
        case .content: return "Content"
        }
    }

    var icon: String {
        switch self {
        case .account: return "person.text.rectangle"
        case .content: return "film.stack"
        }
    }

    static var visibleCases: [SettingsSection] {
        [.account, .content]
    }
}

// MARK: - Section sidebar (mirrors LiveView's category sidebar)

private struct SectionSidebar: View {
    @Binding var selected: SettingsSection

    var body: some View {
        SettingsPanel(title: "Settings", subtitle: nil) {
            VStack(spacing: 10) {
                ForEach(SettingsSection.visibleCases, id: \.self) { section in
                    SectionRow(section: section, isSelected: selected == section) {
                        selected = section
                    }
                }
            }
        }
    }
}

private struct SectionRow: View {
    let section: SettingsSection
    let isSelected: Bool
    let onSelect: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: section.icon)
                .font(.body)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 30)

            Button(action: onSelect) {
                Text(section.title)
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
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
    }

    @ViewBuilder
    private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
        if isFocused {
            shape.fill(Color.accentColor.opacity(0.28))
        } else if isSelected {
            shape.fill(Color.accentColor.opacity(0.14))
        } else {
            Color.clear
        }
    }
}

// MARK: - Generic glass panel

private struct SettingsPanel<Content: View>: View {
    let title: String
    let subtitle: String?
    let trailingAccent: Color?
    /// When true (default) the body wraps content in a scroll view. Panels that
    /// manage their own scrolling internally (e.g. Account's profile list) pass
    /// false so their content fills the fixed panel height instead of growing.
    let scrolls: Bool
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    init(
        title: String,
        subtitle: String?,
        trailingAccent: Color? = nil,
        scrolls: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailingAccent = trailingAccent
        self.scrolls = scrolls
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.sectionTitle)
                        .foregroundStyle(Color.textPrimary)
                    Spacer()
                    if let trailingAccent {
                        Circle()
                            .fill(trailingAccent)
                            .frame(width: 12, height: 12)
                    }
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, SettingsDesign.contentPadding)

            // Title/subtitle stay pinned; only overflowing controls scroll —
            // like Live TV's panes, so headers never clip under the nav.
            if scrolls {
                ScrollView {
                    content()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, SettingsDesign.contentPadding)
                }
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    content()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, SettingsDesign.contentPadding)
            }
        }
        .padding(SettingsDesign.contentPadding)
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

// MARK: - Settings row

private struct SettingsRow: View {
    let label: String
    let value: String
    var monospaced: Bool = false
    var truncateValue: Bool = true

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(truncateValue ? 1 : nil)
                .truncationMode(.tail)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Account panel

private struct AccountPanel: View {
    let profile: Profile
    let onEdit: () -> Void

    var body: some View {
        SettingsPanel(
            title: "Account",
            subtitle: profile.username,
            trailingAccent: statusColor,
            scrolls: false
        ) {
            accountColumn
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
        }
    }

    // MARK: Active account details + actions

    private var accountColumn: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                SettingsRow(label: "Server", value: profile.serverURL)
                SettingsRow(label: "Status", value: profile.status.capitalized)
                if let ts = TimeInterval(profile.expiresAt) {
                    SettingsRow(label: "Expires", value: parseDateFormat(timestamp: ts))
                }
                SettingsRow(label: "Max connections", value: profile.maxConnections, monospaced: true)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(cornerRadius: Radius.card)

            VStack(alignment: .center, spacing: 30) {
                Text("Manage the creditials used to connect")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)

                Button(action: onEdit) {
                    Label("Edit Credentials", systemImage: "pencil")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                }
                .frame(maxWidth: .infinity)
                .buttonStyle(.glass)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(cornerRadius: Radius.card)
        }
    }

    private var statusColor: Color {
        switch profile.status.lowercased() {
        case "active": return .green
        case "expired", "banned", "disabled": return .red
        case "trial": return .yellow
        default: return .secondary
        }
    }
}

// MARK: - Playlist panel

private struct PlaylistPanel: View {
    let profile: Profile
    let movieCount: Int
    let serieCount: Int
    let liveCount: Int
    @Bindable var viewModel: SettingsViewModel
    let onIntervalChange: (Int) -> Void
    let onRefresh: () -> Void
    let onToggleAdult: (Bool) -> Void

    var body: some View {
        SettingsPanel(
            title: "Content",
            subtitle: lastSyncedText
        ) {
            countsRow
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 10) {
                Text("AUTO-SYNC INTERVAL")
                    .font(.caption2.bold())
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                // Explicit buttons instead of .pickerStyle(.segmented) — on tvOS
                // the segmented picker commits the selection on focus change,
                // so just hovering an option silently changes the setting.
                HStack(spacing: 12) {
                    // Interval chips scroll if they overflow; Refresh stays
                    // pinned to the trailing edge (a Spacer inside the
                    // horizontal scroll would collapse to nothing).
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(intervalOptions, id: \.value) { option in
                                intervalButton(option)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 4)
                    }
                    .scrollClipDisabled(true)

                    Spacer(minLength: 12)

                    Button(action: onRefresh) {
                        HStack(spacing: 10) {
                            if viewModel.isRefreshing {
                                ProgressView().controlSize(.small)
                                Text("Refreshing…")
                            } else {
                                Image(systemName: "arrow.clockwise")
                                Text("Refresh Now")
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(viewModel.isRefreshing)
                }
            }
            .padding(.vertical, 4)
            // Group the interval pills + Refresh so the sparse row is reachable
            // as a unit rather than skipped for the toggles below.
            .focusSection()

            if let message = viewModel.refreshMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }

            if viewModel.isRefreshing {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: viewModel.progress.step.iconName)
                            .font(.callout)
                            .symbolRenderingMode(.hierarchical)
                            .symbolEffect(.pulse, options: .repeating)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 22, alignment: .center)
                            .padding(.trailing, 10)

                        Text(viewModel.progress.step.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 12)

                        Text(viewModel.progress.globalFraction, format: .percent.precision(.fractionLength(0)))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    ProgressView(value: viewModel.progress.globalFraction)
                        .progressViewStyle(.linear)
                        .animation(.smooth(duration: 0.35), value: viewModel.progress.globalFraction)
                }
                .padding(.horizontal, 10)
                .animation(.smooth(duration: 0.35), value: viewModel.progress.step)
            }

            Divider().padding(.vertical, 20)

            Toggle(isOn: Binding(
                get: { profile.hideAdultContent },
                set: { onToggleAdult($0) }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hide adult content")
                        .font(.body)
                        .foregroundStyle(Color.textPrimary)
                    Text("Filters categories and titles flagged as adult.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
        }
    }

    private var countsRow: some View {
        HStack(spacing: 16) {
            countTile(symbol: "film.stack", label: "Movies", value: movieCount)
            countTile(symbol: "tv", label: "Series", value: serieCount)
            countTile(symbol: "antenna.radiowaves.left.and.right", label: "Live TV", value: liveCount)
        }
    }

    private func countTile(symbol: String, label: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                Text(label)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
            Text("\(value)")
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(Color.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .cardSurface(cornerRadius: 14)
    }

    private struct IntervalOption {
        let value: Int
        let label: String
    }

    private var intervalOptions: [IntervalOption] {
        [
            .init(value: 3, label: "3 days"),
            .init(value: 7, label: "7 days"),
            .init(value: 14, label: "14 days"),
            .init(value: Int.max, label: "Manual")
        ]
    }

    private func intervalButton(_ option: IntervalOption) -> some View {
        let isSelected = profile.syncIntervalDays == option.value
        // Single Button + parameterized style so selecting an option doesn't
        // swap the Button's identity and bounce focus to the first chip.
        return Button {
            onIntervalChange(option.value)
        } label: {
            Text(option.label)
        }
        .buttonStyle(SelectableChipButtonStyle(isSelected: isSelected))
    }

    private var lastSyncedText: String {
        guard let last = profile.lastSyncedAt else { return "Never synced" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last synced \(formatter.localizedString(for: last, relativeTo: .now))"
    }
}

