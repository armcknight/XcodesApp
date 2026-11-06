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
    case xcodes, platforms

    var id: String { rawValue }

    var title: String {
        switch self {
        case .xcodes: return "Xcodes"
        case .platforms: return "Platforms"
        }
    }

    var systemImage: SystemImage {
        switch self {
        case .xcodes: return .xcode
        case .platforms: return .platforms
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

// MARK: - Shared parts

private func matches(_ text: String, _ searchText: String) -> Bool {
    searchText.isEmpty || text.localizedCaseInsensitiveContains(searchText)
}

/// `1.2 GB`, or a dash when the size is unknown
private func formattedSize(_ bytes: Int64?) -> String {
    bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "–"
}

private struct SidebarSectionHeader: View {
    let title: String
    let detail: String

    var body: some View {
        HStack {
            Text(verbatim: title)
            Text(verbatim: detail).foregroundStyle(.secondary).fontWeight(.regular)
            Spacer()
        }
    }
}

private struct SidebarRow: View {
    let title: String
    let detail: String?
    let systemImage: SystemImage
    let size: Int64?

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
            Text(verbatim: formattedSize(size))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
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
        }
    }

    private var description: String {
        switch mode {
        case .xcodes: return "Select an Xcode version in the sidebar to see its details."
        case .platforms: return "Select an installed simulator runtime to see its details."
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
                        SidebarRow(
                            title: entry.runtime.name,
                            detail: entry.image.runtimeInfo.build,
                            systemImage: .runtime,
                            size: Int64(entry.runtime.fileSize)
                        )
                        .tag(entry.id)
                    }
                } header: {
                    SidebarSectionHeader(title: platform.shortName, detail: "\(platformEntries.count)")
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct PlatformDetailView: View {
    @EnvironmentObject var appState: AppState
    let entry: InstalledPlatformRuntime
    private var runtime: DownloadableRuntime { entry.runtime }
    @State private var isConfirming = false
    @State private var isDeleting = false
    @State private var errorMessage: String?

    var body: some View {
        SidebarDetail(
            title: runtime.name,
            systemImage: .runtime,
            facts: [
                ("Platform", runtime.platform.shortName),
                ("Version", runtime.completeVersion),
                ("Build", entry.image.runtimeInfo.build),
                ("Download size", formattedSize(Int64(runtime.fileSize))),
            ]
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
                delete()
            } label: {
                Text(verbatim: "Delete Runtime")
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

    private func delete() {
        isDeleting = true
        Task {
            do {
                try await appState.deleteRuntime(runtime: runtime)
            } catch {
                errorMessage = error.localizedDescription
            }
            isDeleting = false
        }
    }
}
