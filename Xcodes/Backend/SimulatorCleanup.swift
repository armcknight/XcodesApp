//
//  SimulatorCleanup.swift
//  Xcodes
//
//  Lists simulators and installed simulator runtimes with their sizes, and deletes the simulators the user
//  selects. Xcodes can delete simulator runtimes, but a deleted runtime leaves its simulators on disk.
//

import Foundation
import os.log
import XcodesKit

// MARK: - Models

struct SimulatorDevice: Identifiable, Hashable, Sendable {
    var id: String { udid }

    let udid: String
    let name: String
    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-1`
    let runtimeIdentifier: String
    /// `Booted`, `Shutdown`, …
    let state: String
    /// False when the simulator's runtime is not installed.
    let isAvailable: Bool
    let availabilityError: String?
    /// The simulator's folder in ~/Library/Developer/CoreSimulator/Devices.
    let directory: URL?
    let lastBooted: Date?
    var sizeBytes: Int64?

    var isBooted: Bool { state == "Booted" }

    /// `iOS 26.1`
    var runtimeName: String { SimulatorCleanup.runtimeName(forRuntimeIdentifier: runtimeIdentifier) }

    /// Nil for a runtime identifier that is not in the form `….SimRuntime.<platform>-<version>`.
    var platform: DevicePlatform? { SimulatorCleanup.platform(forRuntimeIdentifier: runtimeIdentifier) }
}

/// An installed runtime disk image, from `xcrun simctl runtime list -j`.
struct InstalledRuntimeInfo: Sendable {
    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-1`, which simulators refer to, or nil when `simctl` leaves it out
    let runtimeIdentifier: String?
    let sizeBytes: Int64?
    let lastUsed: Date?
}

/// What `SimulatorCleanupStore` reports to the user, with the messages of the failed steps.
enum SimulatorCleanupFailure: Equatable {
    /// `simctl` could not list the simulators or runtimes.
    case load(String)
    /// Some of the selected simulators could not be deleted.
    case delete(String)
}

enum SimulatorCleanupError: LocalizedError {
    case commandFailed(command: String, message: String)
    case unexpectedOutput(command: String, output: String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(command, message):
            return "`\(command)` failed: \(message)"
        case let .unexpectedOutput(command, output):
            return "`\(command)` printed unexpected output: \(output)"
        }
    }
}

/// A platform as runtime identifiers spell it. A platform that Xcodes does not know yet keeps the name from the
/// identifier, so it still shows.
enum DevicePlatform: Hashable, Sendable {
    case known(DownloadableRuntime.Platform)
    case unknown(String)

    /// `iOS`, `macOS`, `watchOS`, `tvOS`, or `visionOS` and its old name `xrOS`
    init(name: String) {
        switch name {
        case "iOS": self = .known(.iOS)
        case "macOS": self = .known(.macOS)
        case "watchOS": self = .known(.watchOS)
        case "tvOS": self = .known(.tvOS)
        case "visionOS", "xrOS": self = .known(.visionOS)
        default: self = .unknown(name)
        }
    }

    /// `iOS`, or the name from the identifier for an unknown platform
    var name: String {
        switch self {
        case let .known(platform): return platform.shortName
        case let .unknown(name): return name
        }
    }
}

// MARK: - Service

/// The commands that `SimulatorCleanupStore` uses. Tests replace them.
struct SimulatorCleanupService: Sendable {
    /// The output of `xcrun simctl list devices -j`
    var listDevicesOutput: @Sendable () async throws -> String
    /// The output of `xcrun simctl runtime list -j`
    var listRuntimesOutput: @Sendable () async throws -> String
    /// Deletes the simulator with this UDID with `xcrun simctl delete`.
    var deleteSimulator: @Sendable (_ udid: String) async throws -> Void
    /// The allocated size of a file or folder, from `du -sk`.
    var diskUsage: @Sendable (URL) async throws -> Int64

    init(
        listDevicesOutput: @escaping @Sendable () async throws -> String = {
            try await SimulatorCleanup.run("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"])
        },
        listRuntimesOutput: @escaping @Sendable () async throws -> String = {
            try await SimulatorCleanup.run("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"])
        },
        deleteSimulator: @escaping @Sendable (_ udid: String) async throws -> Void = { udid in
            try await SimulatorCleanup.run("/usr/bin/xcrun", ["simctl", "delete", udid])
        },
        diskUsage: @escaping @Sendable (URL) async throws -> Int64 = { url in
            try await SimulatorCleanup.diskUsage(url)
        }
    ) {
        self.listDevicesOutput = listDevicesOutput
        self.listRuntimesOutput = listRuntimesOutput
        self.deleteSimulator = deleteSimulator
        self.diskUsage = diskUsage
    }
}

// MARK: - Scanning and deleting

enum SimulatorCleanup {

    private struct DeviceList: Decodable {
        struct Device: Decodable {
            let udid: String
            let name: String
            let state: String
            let isAvailable: Bool
            let availabilityError: String?
            let dataPath: String?
            let dataPathSize: Int64?
            let lastBootedAt: String?
        }
        let devices: [String: [Device]]
    }

    /// All simulators, from `xcrun simctl list devices -j`, with their sizes.
    static func loadSimulators(using service: SimulatorCleanupService) async throws -> [SimulatorDevice] {
        let output = try await service.listDevicesOutput()
        let list = try JSONDecoder().decode(DeviceList.self, from: Data(output.utf8))
        let dates = ISO8601DateFormatter()

        var simulators = list.devices.flatMap { runtimeIdentifier, devices in
            devices.map { device in
                SimulatorDevice(
                    udid: device.udid,
                    name: device.name,
                    runtimeIdentifier: runtimeIdentifier,
                    state: device.state,
                    isAvailable: device.isAvailable,
                    availabilityError: device.availabilityError,
                    directory: device.dataPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() },
                    lastBooted: device.lastBootedAt.flatMap { dates.date(from: $0) },
                    sizeBytes: device.dataPathSize
                )
            }
        }

        // older versions of simctl leave out dataPathSize
        let missing = simulators.indices.compactMap { index in
            simulators[index].sizeBytes == nil ? simulators[index].directory.map { (index, $0) } : nil
        }
        for (index, size) in await sizes(of: missing, using: service) {
            simulators[index].sizeBytes = size
        }
        return simulators
    }

    private struct DiskImageRuntime: Decodable {
        let sizeBytes: Int64?
        let lastUsedAt: String?
        let runtimeIdentifier: String?
    }

    /// Installed runtime disk images by UUID.
    static func loadRuntimes(using service: SimulatorCleanupService) async throws -> [String: InstalledRuntimeInfo] {
        let output = try await service.listRuntimesOutput()
        let images = try JSONDecoder().decode([String: DiskImageRuntime].self, from: Data(output.utf8))
        let dates = ISO8601DateFormatter()
        return images.mapValues { image in
            InstalledRuntimeInfo(
                runtimeIdentifier: image.runtimeIdentifier,
                sizeBytes: image.sizeBytes,
                lastUsed: image.lastUsedAt.flatMap { dates.date(from: $0) }
            )
        }
    }

    // MARK: Helpers

    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-1` → (`iOS`, [`26`, `1`])
    private static func parseRuntimeIdentifier(_ identifier: String) -> (platformName: String, version: [Substring])? {
        guard let range = identifier.range(of: "SimRuntime.") else { return nil }
        let parts = identifier[range.upperBound...].split(separator: "-")
        guard let platformName = parts.first else { return nil }
        return (String(platformName), Array(parts.dropFirst()))
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-1` → `.known(.iOS)`
    static func platform(forRuntimeIdentifier identifier: String) -> DevicePlatform? {
        parseRuntimeIdentifier(identifier).map { DevicePlatform(name: $0.platformName) }
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-1` → `iOS 26.1`
    static func runtimeName(forRuntimeIdentifier identifier: String) -> String {
        guard let parsed = parseRuntimeIdentifier(identifier) else { return identifier }
        let name = DevicePlatform(name: parsed.platformName).name
        return parsed.version.isEmpty ? name : "\(name) \(parsed.version.joined(separator: "."))"
    }

    /// Allocated sizes from `du -sk`, 8 at a time. An item whose size cannot be measured is left out.
    private static func sizes(of items: [(Int, URL)], using service: SimulatorCleanupService) async -> [(Int, Int64)] {
        await withTaskGroup(of: (Int, Int64?).self) { group in
            var iterator = items.makeIterator()
            for _ in 0..<8 {
                guard let next = iterator.next() else { break }
                group.addTask { (next.0, await measuredSize(of: next.1, using: service)) }
            }
            var results: [(Int, Int64)] = []
            while let result = await group.next() {
                if let size = result.1 { results.append((result.0, size)) }
                if let next = iterator.next() {
                    group.addTask { (next.0, await measuredSize(of: next.1, using: service)) }
                }
            }
            return results
        }
    }

    /// The size of the item, or nil when `du` fails. One item that cannot be measured must not stop the whole list.
    private static func measuredSize(of url: URL, using service: SimulatorCleanupService) async -> Int64? {
        do {
            return try await service.diskUsage(url)
        } catch {
            Logger.appState.error("Could not measure the size of \(url.path): \(error.localizedDescription)")
            return nil
        }
    }

    fileprivate static func diskUsage(_ url: URL) async throws -> Int64 {
        let arguments = ["-sk", url.path]
        let output = try await run("/usr/bin/du", arguments)
        guard let first = output.split(whereSeparator: \.isWhitespace).first, let kilobytes = Int64(first) else {
            throw SimulatorCleanupError.unexpectedOutput(command: (["/usr/bin/du"] + arguments).joined(separator: " "), output: output)
        }
        return kilobytes * 1024
    }

    @discardableResult
    fileprivate static func run(_ executable: String, _ arguments: [String]) async throws -> String {
        let command = ([executable] + arguments).joined(separator: " ")
        do {
            let output = try await Process.runAsync(URL(fileURLWithPath: executable), arguments)
            guard output.status == 0 else {
                throw SimulatorCleanupError.commandFailed(command: command, message: output.err.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return output.out
        } catch let error as SimulatorCleanupError {
            throw error
        } catch {
            throw SimulatorCleanupError.commandFailed(command: command, message: error.localizedDescription)
        }
    }
}

// MARK: - Store

@MainActor
final class SimulatorCleanupStore: ObservableObject {
    @Published private(set) var simulators: [SimulatorDevice] = []
    /// Installed runtime disk images by UUID (`CoreSimulatorImage.uuid`).
    @Published private(set) var runtimes: [String: InstalledRuntimeInfo] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    /// Ids of the items that are being deleted now.
    @Published private(set) var deleting: Set<String> = []
    /// The last load or delete that failed, until the user dismisses its alert.
    @Published var failure: SimulatorCleanupFailure?
    private let service: SimulatorCleanupService

    init(service: SimulatorCleanupService = SimulatorCleanupService()) {
        self.service = service
    }

    var unavailableSimulators: [SimulatorDevice] { simulators.filter { !$0.isAvailable } }

    func simulators(forRuntimeIdentifier runtimeIdentifier: String) -> [SimulatorDevice] {
        simulators.filter { $0.runtimeIdentifier == runtimeIdentifier }
    }

    func simulator(withID id: String?) -> SimulatorDevice? {
        simulators.first { $0.id == id }
    }

    /// Available simulators by runtime, newest runtime first.
    var simulatorsByRuntime: [(runtime: String, simulators: [SimulatorDevice])] {
        Dictionary(grouping: simulators.filter(\.isAvailable), by: \.runtimeName)
            .map { ($0.key, $0.value.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) }
            .sorted { $0.runtime.localizedStandardCompare($1.runtime) == .orderedDescending }
    }

    func reload() async {
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        async let loadedSimulators = SimulatorCleanup.loadSimulators(using: service)
        async let loadedRuntimes = SimulatorCleanup.loadRuntimes(using: service)
        var failures: [String] = []
        do {
            simulators = try await loadedSimulators
        } catch {
            failures.append(error.localizedDescription)
        }
        do {
            runtimes = try await loadedRuntimes
        } catch {
            failures.append(error.localizedDescription)
        }
        if !failures.isEmpty {
            failure = .load(failures.joined(separator: "\n"))
        }
    }

    func delete(simulators toDelete: [SimulatorDevice]) async {
        var failures: [String] = []
        for simulator in toDelete where !simulator.isBooted {
            deleting.insert(simulator.id)
            do {
                try await service.deleteSimulator(simulator.udid)
                simulators.removeAll { $0.id == simulator.id }
            } catch {
                failures.append("\(simulator.name): \(error.localizedDescription)")
            }
            deleting.remove(simulator.id)
        }
        if !failures.isEmpty {
            failure = .delete(failures.joined(separator: "\n"))
        }
    }

    /// Deletes the simulators first, so that `simctl` does not delete a runtime that a simulator still uses, then
    /// the runtime, then loads everything again. A simulator that cannot be deleted goes to `failure`, and the
    /// runtime is still deleted. An error from deleting the runtime is thrown after the reload.
    func deleteRuntime(simulators: [SimulatorDevice], deleteRuntime: () async throws -> Void) async throws {
        await delete(simulators: simulators)
        do {
            try await deleteRuntime()
        } catch {
            await reload()
            throw error
        }
        await reload()
    }
}
