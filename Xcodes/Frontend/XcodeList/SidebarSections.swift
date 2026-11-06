//
//  SidebarSections.swift
//  Xcodes
//
//  The control at the top of the sidebar that switches between its sections, and the lists and detail views
//  of the sections other than Xcodes.
//

import SwiftUI
import XcodesKit

// MARK: - Mode

enum SidebarMode: String, CaseIterable, Identifiable {
    case xcodes, platforms, simulators

    var id: String { rawValue }

    var title: String {
        switch self {
        case .xcodes: return "Xcodes"
        case .platforms: return "Platforms"
        case .simulators: return "Simulators"
        }
    }

    var systemImage: SystemImage {
        switch self {
        case .xcodes: return .xcode
        case .platforms: return .platforms
        case .simulators: return .simulators
        }
    }
}

extension SimulatorDevice {
    var systemImage: SystemImage {
        switch platform {
        case .known(.iOS): return name.contains("iPad") ? .iPad : .iPhone
        case let .known(platform): return platform.systemImage
        // a platform that Xcodes does not know yet, or a runtime identifier in an unexpected form
        case .unknown, nil: return .simulators
        }
    }
}

/// One icon segment per section, each with a tooltip. A segmented `Picker` cannot show a tooltip per segment.
///
/// The segments are not in the focus order: with keyboard navigation on, macOS focuses the first focusable control
/// in a new window, and that would put a focus ring on the first segment at launch instead of on the list.
/// ⌘1, ⌘2 and so on switch the section from the keyboard.
struct SidebarModePicker: View {
    @Binding var mode: SidebarMode

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(SidebarMode.allCases.enumerated()), id: \.element) { index, item in
                let isSelected = item == mode
                let shortcut = Character(String(index + 1))
                Button {
                    mode = item
                } label: {
                    Image(symbol: item.systemImage)
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .keyboardShortcut(KeyEquivalent(shortcut), modifiers: .command)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .help(Text(verbatim: "\(item.title) (⌘\(shortcut))"))
                .accessibilityLabel(Text(verbatim: item.title))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Deletion confirmation

/// What a confirmation asks about.
enum CleanupDeletion: Identifiable {
    case simulators([SimulatorDevice], context: String? = nil)

    var id: String {
        switch self {
        case let .simulators(items, _): return "s" + items.map(\.id).joined()
        }
    }
}

private struct CleanupConfirmation: ViewModifier {
    @Binding var pending: CleanupDeletion?
    @ObservedObject var store: SimulatorCleanupStore

    func body(content: Content) -> some View {
        content.alert(item: $pending) { pending in
            let title: String
            let message: String
            let action: () -> Void
            switch pending {
            case let .simulators(items, context):
                let total = formattedTotal(items.map(\.sizeBytes))
                title = items.count == 1 ? "Delete the simulator “\(items[0].name)”?" : "Delete \(items.count) simulators\(context.map { " \($0)" } ?? "")?"
                message = "This frees \(total). The simulators and all their apps and data are deleted with `xcrun simctl delete`. You cannot undo this."
                action = { Task { await store.delete(simulators: items) } }
            }
            return Alert(
                title: Text(verbatim: title),
                message: Text(verbatim: message),
                primaryButton: .destructive(Text(verbatim: "Delete"), action: action),
                secondaryButton: .cancel()
            )
        }
    }
}

private struct CleanupFailureAlert: ViewModifier {
    @ObservedObject var store: SimulatorCleanupStore

    func body(content: Content) -> some View {
        content.alert(
            Text(verbatim: title),
            isPresented: Binding(get: { store.failure != nil }, set: { if !$0 { store.failure = nil } }),
            presenting: store.failure
        ) { _ in
            Button { store.failure = nil } label: { Text(verbatim: "OK") }
        } message: { failure in
            switch failure {
            case let .load(message), let .delete(message):
                Text(verbatim: message)
            }
        }
    }

    private var title: String {
        switch store.failure {
        case .load: return "Simulators could not be loaded"
        case .delete: return "Some items could not be deleted"
        case nil: return ""
        }
    }
}

extension View {
    fileprivate func cleanupConfirmation(_ pending: Binding<CleanupDeletion?>, store: SimulatorCleanupStore) -> some View {
        modifier(CleanupConfirmation(pending: pending, store: store))
    }

    /// The reload button, the failure alert and the first load for a sidebar list that uses the store.
    fileprivate func cleanupList(store: SimulatorCleanupStore, onReload: @escaping () -> Void = {}) -> some View {
        self
            .modifier(CleanupFailureAlert(store: store))
            .overlay {
                if store.isLoading && !store.hasLoaded {
                    ProgressView()
                }
            }
            .task {
                if !store.hasLoaded { await store.reload() }
            }
            .toolbar {
                ToolbarItem {
                    Button {
                        onReload()
                        Task { await store.reload() }
                    } label: {
                        Label { Text(verbatim: "Reload") } icon: { Image(symbol: .reload) }
                    }
                    .help(Text(verbatim: "Reload"))
                    .disabled(store.isLoading)
                }
            }
    }
}

// MARK: - Shared parts

private func matches(_ text: String, _ searchText: String) -> Bool {
    searchText.isEmpty || text.localizedCaseInsensitiveContains(searchText)
}

/// `1.2 GB`, or a dash when the size is unknown
private func formattedSize(_ bytes: Int64?) -> String {
    bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "–"
}

/// The formatted sum of the sizes that are known
private func formattedTotal<S: Sequence>(_ sizes: S) -> String where S.Element == Int64? {
    formattedSize(sizes.compactMap { $0 }.reduce(0, +))
}

private struct SidebarSectionHeader: View {
    let title: String
    let detail: String
    var buttonTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack {
            Text(verbatim: title)
            Text(verbatim: detail).foregroundStyle(.secondary).fontWeight(.regular)
            Spacer()
            if let buttonTitle, let action {
                Button(action: action) { Text(verbatim: buttonTitle) }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
    }
}

private struct SidebarRow: View {
    let title: String
    let detail: String?
    let systemImage: SystemImage
    let size: Int64?
    var isDeleting = false

    var body: some View {
        HStack {
            Image(symbol: systemImage)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title).lineLimit(1)
                if let detail {
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if isDeleting {
                ProgressView().controlSize(.small)
            } else {
                Text(verbatim: formattedSize(size))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A detail pane: a title, facts as rows, and buttons.
private struct SidebarDetail<Actions: View>: View {
    let title: String
    let systemImage: SystemImage
    let facts: [(String, String)]
    var note: String?
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label { Text(verbatim: title) } icon: { Image(symbol: systemImage) }
                    .font(.title2.weight(.semibold))
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(facts, id: \.0) { fact in
                        GridRow {
                            Text(verbatim: fact.0).foregroundStyle(.secondary)
                            Text(verbatim: fact.1).textSelection(.enabled)
                        }
                    }
                }
                if let note {
                    Text(verbatim: note)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack { actions() }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The detail pane's empty state, the same for every section.
///
/// Everything has a fixed size: the icon sits in a box of one height (SF Symbols have different heights), and the
/// description always keeps room for two lines. So the title and text stay at the same place when you switch modes.
/// `ContentUnavailableView` centers its content by its real height, which moved it by a pixel or two.
struct SidebarPlaceholder: View {
    let mode: SidebarMode

    var body: some View {
        VStack(spacing: 10) {
            Image(symbol: mode.systemImage)
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.tertiary)
                .frame(width: 64, height: 52)
            title
                .font(.title2.weight(.semibold))
                .lineLimit(1)
            Text(verbatim: description)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)
        }
        .frame(width: 320)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var title: some View {
        switch mode {
        case .xcodes: Text("NoXcodeSelected")
        case .platforms: Text(verbatim: "No Platform Selected")
        case .simulators: Text(verbatim: "No Simulator Selected")
        }
    }

    private var description: String {
        switch mode {
        case .xcodes: return "Select an Xcode version in the sidebar to see its details."
        case .platforms: return "Select an installed simulator runtime to see its size and simulators."
        case .simulators: return "Select a simulator to see its size, runtime and data folder."
        }
    }
}

// MARK: - Platforms

/// One installed runtime disk image, with the entry from Apple's list of downloadable runtimes that names it.
///
/// The list is built from the installed images, not from the downloadable runtimes: Apple's list can have several
/// entries for one build (a release candidate and the release, or two architecture variants), and they all share
/// the `DownloadableRuntime.id` "iOS 26.5", so they would show twice and select together.
struct InstalledPlatformRuntime: Identifiable {
    let image: CoreSimulatorImage
    let runtime: DownloadableRuntime

    var id: String { image.uuid }

    @MainActor
    static func all(in appState: AppState) -> [InstalledPlatformRuntime] {
        appState.installedRuntimes.compactMap { image -> InstalledPlatformRuntime? in
            let candidates = appState.downloadableRuntimes.filter { $0.simulatorVersion.buildUpdate == image.runtimeInfo.build }
            let isCandidate = { (runtime: DownloadableRuntime) in
                runtime.name.localizedCaseInsensitiveContains("Release Candidate") || runtime.identifier.localizedCaseInsensitiveContains("_rc")
            }
            guard let runtime = candidates.first(where: { !isCandidate($0) }) ?? candidates.first else { return nil }
            return InstalledPlatformRuntime(image: image, runtime: runtime)
        }
        .sorted { lhs, rhs in
            lhs.runtime.platform != rhs.runtime.platform
                ? lhs.runtime.platform.order < rhs.runtime.platform.order
                : lhs.runtime.simulatorVersion.version.localizedStandardCompare(rhs.runtime.simulatorVersion.version) == .orderedDescending
        }
    }
}

/// The installed simulator runtimes that Xcodes knows from Apple's list of downloadable runtimes, by platform.
struct PlatformsSidebarList: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var store: SimulatorCleanupStore
    /// The selected image's UUID
    @Binding var selection: InstalledPlatformRuntime.ID?
    let searchText: String

    var body: some View {
        let entries = InstalledPlatformRuntime.all(in: appState).filter { matches($0.runtime.name, searchText) }
        let platforms = entries.map(\.runtime.platform).reduce(into: [DownloadableRuntime.Platform]()) { if !$0.contains($1) { $0.append($1) } }
        List(selection: $selection) {
            ForEach(platforms, id: \.self) { platform in
                let platformEntries = entries.filter { $0.runtime.platform == platform }
                Section {
                    ForEach(platformEntries) { entry in
                        let info = store.runtimes[entry.image.uuid]
                        let simulatorCount = info?.runtimeIdentifier.map { store.simulators(forRuntimeIdentifier: $0).count }
                        SidebarRow(
                            title: entry.runtime.name,
                            detail: [entry.image.runtimeInfo.build, simulatorCount.map { $0 == 1 ? "1 simulator" : "\($0) simulators" }]
                                .compactMap { $0 }.joined(separator: " · "),
                            systemImage: .runtime,
                            size: info?.sizeBytes
                        )
                        .tag(entry.id)
                    }
                } header: {
                    SidebarSectionHeader(title: platform.shortName, detail: "\(platformEntries.count)")
                }
            }
        }
        .listStyle(.sidebar)
        .cleanupList(store: store) { appState.updateInstalledRuntimes() }
    }
}

struct PlatformDetailView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var store: SimulatorCleanupStore
    let entry: InstalledPlatformRuntime
    private var runtime: DownloadableRuntime { entry.runtime }
    @State private var isConfirming = false
    @State private var isDeleting = false
    @State private var errorMessage: String?

    var body: some View {
        let info = store.runtimes[entry.image.uuid]
        // nil when simctl does not say which runtime identifier the image has, so its simulators are unknown
        let simulators = info?.runtimeIdentifier.map { store.simulators(forRuntimeIdentifier: $0) }
        var facts = [("Platform", runtime.platform.shortName), ("Version", runtime.completeVersion), ("Build", entry.image.runtimeInfo.build)]
        facts.append(("Size on disk", formattedSize(info?.sizeBytes)))
        if let simulators {
            facts.append(("Simulators", "\(simulators.count), \(formattedTotal(simulators.map(\.sizeBytes)))"))
        }
        if let lastUsed = info?.lastUsed {
            facts.append(("Last used", lastUsed.formatted(date: .abbreviated, time: .shortened)))
        }

        return SidebarDetail(
            title: runtime.name,
            systemImage: .runtime,
            facts: facts,
            note: note(simulators: simulators)
        ) {
            Button(role: .destructive) {
                isConfirming = true
            } label: {
                Text(verbatim: "Delete Runtime…")
            }
            .disabled(isDeleting)
            if isDeleting {
                ProgressView().controlSize(.small)
            }
        }
        .confirmationDialog(Text(verbatim: "Delete \(runtime.name)?"), isPresented: $isConfirming) {
            Button(role: .destructive) {
                delete(simulators: [])
            } label: {
                Text(verbatim: "Delete Runtime (\(formattedSize(info?.sizeBytes)))")
            }
            if let simulators, !simulators.isEmpty {
                let total = formattedTotal((simulators.map(\.sizeBytes)) + [info?.sizeBytes])
                Button(role: .destructive) {
                    delete(simulators: simulators.filter { !$0.isBooted })
                } label: {
                    Text(verbatim: "Delete Runtime and \(simulators.count) Simulators (\(total))")
                }
            }
        } message: {
            Text(verbatim: "The runtime is deleted with `xcrun simctl runtime delete`. You can download it again in Xcode or Xcodes.")
        }
        .alert(
            Text(verbatim: "The runtime could not be deleted"),
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button { errorMessage = nil } label: { Text(verbatim: "OK") }
        } message: {
            Text(verbatim: errorMessage ?? "")
        }
    }

    private func note(simulators: [SimulatorDevice]?) -> String? {
        guard let simulators, !simulators.isEmpty else { return nil }
        return "If you delete only the runtime, its simulators stay on disk but cannot run. They then show as unavailable in Simulators."
    }

    private func delete(simulators: [SimulatorDevice]) {
        isDeleting = true
        Task {
            do {
                try await store.deleteRuntime(simulators: simulators) {
                    try await appState.deleteRuntime(runtime: runtime)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isDeleting = false
        }
    }
}

// MARK: - Simulators

struct SimulatorsSidebarList: View {
    @EnvironmentObject var store: SimulatorCleanupStore
    @Binding var selection: SimulatorDevice.ID?
    let searchText: String
    @State private var pending: CleanupDeletion?

    var body: some View {
        let unavailable = store.unavailableSimulators.filter { matches($0.name, searchText) }
        List(selection: $selection) {
            if !unavailable.isEmpty {
                Section {
                    ForEach(unavailable) { row($0) }
                } header: {
                    SidebarSectionHeader(
                        title: "Unavailable",
                        detail: "\(unavailable.count) · \(formattedTotal(unavailable.map(\.sizeBytes)))",
                        buttonTitle: "Delete All"
                    ) {
                        pending = .simulators(unavailable, context: "whose runtime is not installed")
                    }
                }
            }

            ForEach(store.simulatorsByRuntime, id: \.runtime) { group in
                let simulators = group.simulators.filter { matches($0.name, searchText) }
                if !simulators.isEmpty {
                    // a booted simulator cannot be deleted, so "Delete All" leaves it out
                    let deletable = simulators.filter { !$0.isBooted }
                    Section {
                        ForEach(simulators) { row($0) }
                    } header: {
                        SidebarSectionHeader(
                            title: group.runtime,
                            detail: "\(simulators.count) · \(formattedTotal(simulators.map(\.sizeBytes)))",
                            buttonTitle: deletable.isEmpty ? nil : "Delete All"
                        ) {
                            pending = .simulators(deletable, context: "on \(group.runtime)")
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .cleanupList(store: store)
        .cleanupConfirmation($pending, store: store)
    }

    private func row(_ simulator: SimulatorDevice) -> some View {
        SidebarRow(
            title: simulator.name,
            detail: simulator.isAvailable ? simulator.state : simulator.runtimeName,
            systemImage: simulator.systemImage,
            size: simulator.sizeBytes,
            isDeleting: store.deleting.contains(simulator.id)
        )
        .tag(simulator.id)
    }
}

struct SimulatorDetailView: View {
    @EnvironmentObject var store: SimulatorCleanupStore
    let simulator: SimulatorDevice
    @State private var pending: CleanupDeletion?

    var body: some View {
        var facts = [
            ("Runtime", simulator.runtimeName + (simulator.isAvailable ? "" : " (not installed)")),
            ("State", simulator.state),
            ("Size", formattedSize(simulator.sizeBytes)),
            ("UDID", simulator.udid),
        ]
        if let lastBooted = simulator.lastBooted {
            facts.append(("Last booted", lastBooted.formatted(date: .abbreviated, time: .shortened)))
        }
        if let directory = simulator.directory {
            facts.append(("Folder", directory.path))
        }

        return SidebarDetail(
            title: simulator.name,
            systemImage: simulator.systemImage,
            facts: facts,
            note: simulator.isAvailable ? nil : (simulator.availabilityError ?? "Its runtime is not installed, so it cannot run.")
        ) {
            Button(role: .destructive) {
                pending = .simulators([simulator])
            } label: {
                Text(verbatim: "Delete Simulator…")
            }
            .disabled(simulator.isBooted || store.deleting.contains(simulator.id))
            .help(Text(verbatim: simulator.isBooted ? "Shut down the simulator to delete it" : "Delete with `xcrun simctl delete`"))
            if let directory = simulator.directory {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([directory])
                } label: {
                    Text(verbatim: "Show in Finder")
                }
            }
        }
        .cleanupConfirmation($pending, store: store)
    }
}
