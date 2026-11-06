import Foundation
import os
import XCTest
import XcodesKit

@testable import Xcodes

/// Records what the fake service was asked to do, from any task.
private final class CallLog: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: [String]())

    func append(_ call: String) {
        storage.withLock { $0.append(call) }
    }

    var calls: [String] {
        storage.withLock { $0 }
    }
}

private struct FakeError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

// MARK: - Parsing

final class SimulatorCleanupParsingTests: XCTestCase {
    func test_DevicePlatform_KnownNames() {
        XCTAssertEqual(DevicePlatform(name: "iOS"), .known(.iOS))
        XCTAssertEqual(DevicePlatform(name: "macOS"), .known(.macOS))
        XCTAssertEqual(DevicePlatform(name: "watchOS"), .known(.watchOS))
        XCTAssertEqual(DevicePlatform(name: "tvOS"), .known(.tvOS))
        XCTAssertEqual(DevicePlatform(name: "visionOS"), .known(.visionOS))
        XCTAssertEqual(DevicePlatform(name: "xrOS"), .known(.visionOS))
    }

    func test_DevicePlatform_UnknownNameIsKept() {
        let platform = DevicePlatform(name: "carOS")
        XCTAssertEqual(platform, .unknown("carOS"))
        XCTAssertEqual(platform.name, "carOS")
    }

    func test_RuntimeName() {
        XCTAssertEqual(SimulatorCleanup.runtimeName(forRuntimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-1"), "iOS 26.1")
        XCTAssertEqual(SimulatorCleanup.runtimeName(forRuntimeIdentifier: "com.apple.CoreSimulator.SimRuntime.xrOS-2-0"), "visionOS 2.0")
        XCTAssertEqual(SimulatorCleanup.runtimeName(forRuntimeIdentifier: "com.apple.CoreSimulator.SimRuntime.carOS-1-2-3"), "carOS 1.2.3")
        XCTAssertEqual(SimulatorCleanup.runtimeName(forRuntimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS"), "iOS")
        XCTAssertEqual(SimulatorCleanup.runtimeName(forRuntimeIdentifier: "something.else"), "something.else")
    }

    func test_PlatformForRuntimeIdentifier() {
        XCTAssertEqual(SimulatorCleanup.platform(forRuntimeIdentifier: "com.apple.CoreSimulator.SimRuntime.watchOS-11-0"), .known(.watchOS))
        XCTAssertEqual(SimulatorCleanup.platform(forRuntimeIdentifier: "com.apple.CoreSimulator.SimRuntime.carOS-1-0"), .unknown("carOS"))
        XCTAssertNil(SimulatorCleanup.platform(forRuntimeIdentifier: "something.else"))
    }

    func test_SimulatorSystemImage() {
        func image(name: String, runtime: String) -> SystemImage {
            Self.simulator(name: name, runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.\(runtime)").systemImage
        }
        XCTAssertEqual(image(name: "iPhone 17 Pro", runtime: "iOS-26-1"), .iPhone)
        XCTAssertEqual(image(name: "iPad Pro 11-inch (M4)", runtime: "iOS-26-1"), .iPad)
        XCTAssertEqual(image(name: "Apple Watch Series 11 (46mm)", runtime: "watchOS-26-1"), .watch)
        XCTAssertEqual(image(name: "Apple TV 4K", runtime: "tvOS-26-1"), .tv)
        XCTAssertEqual(image(name: "Apple Vision Pro", runtime: "xrOS-26-1"), .visionPro)
        XCTAssertEqual(image(name: "Car", runtime: "carOS-1-0"), .simulators)
        XCTAssertEqual(Self.simulator(name: "Odd", runtimeIdentifier: "something.else").systemImage, .simulators)
    }

    private static func simulator(name: String, runtimeIdentifier: String) -> SimulatorDevice {
        SimulatorDevice(
            udid: "UDID",
            name: name,
            runtimeIdentifier: runtimeIdentifier,
            state: "Shutdown",
            isAvailable: true,
            availabilityError: nil,
            directory: nil,
            lastBooted: nil,
            sizeBytes: nil
        )
    }
}

// MARK: - Store

@MainActor
final class SimulatorCleanupStoreTests: XCTestCase {
    private static let iOSRuntime = "com.apple.CoreSimulator.SimRuntime.iOS-26-1"
    private static let removedRuntime = "com.apple.CoreSimulator.SimRuntime.iOS-17-0"

    // MARK: Loading simulators

    func test_Reload_DecodesSimulators() async throws {
        let store = SimulatorCleanupStore(service: service())

        await store.reload()

        XCTAssertNil(store.failure)
        XCTAssertTrue(store.hasLoaded)
        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(store.simulators.count, 4)

        let booted = try XCTUnwrap(store.simulator(withID: "BOOTED"))
        XCTAssertEqual(booted.name, "iPhone 17 Pro")
        XCTAssertEqual(booted.runtimeIdentifier, Self.iOSRuntime)
        XCTAssertEqual(booted.state, "Booted")
        XCTAssertTrue(booted.isBooted)
        XCTAssertTrue(booted.isAvailable)
        XCTAssertEqual(booted.sizeBytes, 1_000)
        XCTAssertEqual(booted.directory?.path, "/Devices/BOOTED")
        XCTAssertEqual(booted.lastBooted, ISO8601DateFormatter().date(from: "2026-11-01T10:00:00Z"))

        let orphan = try XCTUnwrap(store.simulator(withID: "ORPHAN"))
        XCTAssertFalse(orphan.isAvailable)
        XCTAssertEqual(orphan.availabilityError, "runtime profile not found")
        XCTAssertEqual(orphan.runtimeName, "iOS 17.0")
    }

    func test_Reload_MeasuresSimulatorsWithoutDataPathSize() async throws {
        let measured = CallLog()
        let store = SimulatorCleanupStore(service: service(diskUsage: { url in
            measured.append(url.path)
            if url.path == "/Devices/UNMEASURABLE" { throw FakeError("du failed") }
            return 4_096
        }))

        await store.reload()

        XCTAssertEqual(Set(measured.calls), ["/Devices/SHUTDOWN", "/Devices/UNMEASURABLE"])
        XCTAssertEqual(store.simulator(withID: "SHUTDOWN")?.sizeBytes, 4_096)
        // a size that cannot be measured stays unknown, and is not a load failure
        XCTAssertNil(store.simulator(withID: "UNMEASURABLE")?.sizeBytes)
        XCTAssertNil(store.failure)
    }

    func test_UnavailableSimulatorsAndSimulatorsByRuntime() async throws {
        let store = SimulatorCleanupStore(service: service())

        await store.reload()

        XCTAssertEqual(store.unavailableSimulators.map(\.id), ["ORPHAN"])
        XCTAssertEqual(store.simulatorsByRuntime.map(\.runtime), ["iOS 26.1"])
        // sorted by name in a runtime
        XCTAssertEqual(store.simulatorsByRuntime.first?.simulators.map(\.name), ["iPad Air", "iPhone 17", "iPhone 17 Pro"])
        XCTAssertEqual(store.simulators(forRuntimeIdentifier: Self.iOSRuntime).count, 3)
    }

    func test_Reload_ReportsSimulatorsWithoutRequiredFieldsAsLoadFailure() async throws {
        let store = SimulatorCleanupStore(service: service(listDevicesOutput: {
            #"{"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-1": [{"udid": "A", "name": "iPhone"}]}}"#
        }))

        await store.reload()

        XCTAssertTrue(store.simulators.isEmpty)
        guard case .load = store.failure else {
            return XCTFail("Expected a load failure, got \(String(describing: store.failure))")
        }
    }

    // MARK: Loading runtimes

    func test_Reload_DecodesRuntimes() async throws {
        let store = SimulatorCleanupStore(service: service())

        await store.reload()

        let runtime = try XCTUnwrap(store.runtimes["IMAGE-1"])
        XCTAssertEqual(runtime.runtimeIdentifier, Self.iOSRuntime)
        XCTAssertEqual(runtime.sizeBytes, 8_000_000_000)
        XCTAssertEqual(runtime.lastUsed, ISO8601DateFormatter().date(from: "2026-10-01T08:00:00Z"))
        XCTAssertNil(try XCTUnwrap(store.runtimes["IMAGE-2"]).runtimeIdentifier)
    }

    func test_Reload_KeepsWhatLoadedWhenOneStepFails() async throws {
        let store = SimulatorCleanupStore(service: service(listRuntimesOutput: { throw FakeError("simctl runtime list failed") }))

        await store.reload()

        XCTAssertEqual(store.simulators.count, 4)
        XCTAssertTrue(store.runtimes.isEmpty)
        XCTAssertEqual(store.failure, .load("simctl runtime list failed"))
    }

    func test_Reload_CollectsEveryLoadFailure() async throws {
        let store = SimulatorCleanupStore(service: service(
            listDevicesOutput: { throw FakeError("devices failed") },
            listRuntimesOutput: { throw FakeError("runtimes failed") }
        ))

        await store.reload()

        XCTAssertEqual(store.failure, .load("devices failed\nruntimes failed"))
    }

    // MARK: Deleting

    func test_DeleteSimulators_SkipsBootedAndRemovesDeleted() async throws {
        let deleted = CallLog()
        let store = SimulatorCleanupStore(service: service(deleteSimulator: { deleted.append($0) }))
        await store.reload()

        await store.delete(simulators: store.simulators(forRuntimeIdentifier: Self.iOSRuntime))

        XCTAssertEqual(Set(deleted.calls), ["SHUTDOWN", "UNMEASURABLE"])
        XCTAssertEqual(store.simulators.map(\.id).sorted(), ["BOOTED", "ORPHAN"])
        XCTAssertTrue(store.deleting.isEmpty)
        XCTAssertNil(store.failure)
    }

    func test_DeleteSimulators_ReportsFailuresAndKeepsThem() async throws {
        let store = SimulatorCleanupStore(service: service(deleteSimulator: { udid in
            if udid == "SHUTDOWN" { throw FakeError("in use") }
        }))
        await store.reload()

        await store.delete(simulators: [try XCTUnwrap(store.simulator(withID: "SHUTDOWN")), try XCTUnwrap(store.simulator(withID: "ORPHAN"))])

        XCTAssertNotNil(store.simulator(withID: "SHUTDOWN"))
        XCTAssertNil(store.simulator(withID: "ORPHAN"))
        XCTAssertEqual(store.failure, .delete("iPhone 17: in use"))
    }

    func test_DeleteRuntime_DeletesSimulatorsFirstThenRuntimeThenReloads() async throws {
        let log = CallLog()
        let store = SimulatorCleanupStore(service: service(
            listDevicesOutput: { log.append("list"); return Self.devicesJSON },
            deleteSimulator: { log.append("delete \($0)") }
        ))
        await store.reload()
        let simulators = store.simulators(forRuntimeIdentifier: Self.iOSRuntime).filter { !$0.isBooted }.sorted { $0.id < $1.id }

        try await store.deleteRuntime(simulators: simulators) { log.append("delete runtime") }

        XCTAssertEqual(log.calls, ["list", "delete SHUTDOWN", "delete UNMEASURABLE", "delete runtime", "list"])
    }

    func test_DeleteRuntime_ThrowsRuntimeErrorAfterReloading() async throws {
        let log = CallLog()
        let store = SimulatorCleanupStore(service: service(listDevicesOutput: { log.append("list"); return Self.devicesJSON }))
        await store.reload()

        do {
            try await store.deleteRuntime(simulators: []) { throw FakeError("runtime is in use") }
            XCTFail("Expected the runtime error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "runtime is in use")
        }
        XCTAssertEqual(log.calls, ["list", "list"])
    }

    func test_DeleteRuntime_StillDeletesRuntimeWhenASimulatorFails() async throws {
        let log = CallLog()
        let store = SimulatorCleanupStore(service: service(deleteSimulator: { _ in throw FakeError("in use") }))
        await store.reload()

        try await store.deleteRuntime(simulators: [try XCTUnwrap(store.simulator(withID: "SHUTDOWN"))]) { log.append("delete runtime") }

        XCTAssertEqual(log.calls, ["delete runtime"])
        XCTAssertEqual(store.failure, .delete("iPhone 17: in use"))
    }

    // MARK: Helpers

    private func service(
        listDevicesOutput: @escaping @Sendable () async throws -> String = { SimulatorCleanupStoreTests.devicesJSON },
        listRuntimesOutput: @escaping @Sendable () async throws -> String = { SimulatorCleanupStoreTests.runtimesJSON },
        deleteSimulator: @escaping @Sendable (String) async throws -> Void = { _ in },
        diskUsage: @escaping @Sendable (URL) async throws -> Int64 = { _ in 4_096 }
    ) -> SimulatorCleanupService {
        SimulatorCleanupService(
            listDevicesOutput: listDevicesOutput,
            listRuntimesOutput: listRuntimesOutput,
            deleteSimulator: deleteSimulator,
            diskUsage: diskUsage
        )
    }

    /// Four simulators: booted with a size, shut down without a size, one whose size cannot be measured, and one
    /// whose runtime is not installed.
    nonisolated private static let devicesJSON = """
    {
      "devices": {
        "com.apple.CoreSimulator.SimRuntime.iOS-26-1": [
          {
            "udid": "BOOTED",
            "name": "iPhone 17 Pro",
            "state": "Booted",
            "isAvailable": true,
            "dataPath": "/Devices/BOOTED/data",
            "dataPathSize": 1000,
            "lastBootedAt": "2026-11-01T10:00:00Z"
          },
          {
            "udid": "SHUTDOWN",
            "name": "iPhone 17",
            "state": "Shutdown",
            "isAvailable": true,
            "dataPath": "/Devices/SHUTDOWN/data"
          },
          {
            "udid": "UNMEASURABLE",
            "name": "iPad Air",
            "state": "Shutdown",
            "isAvailable": true,
            "dataPath": "/Devices/UNMEASURABLE/data"
          }
        ],
        "com.apple.CoreSimulator.SimRuntime.iOS-17-0": [
          {
            "udid": "ORPHAN",
            "name": "iPhone 15",
            "state": "Shutdown",
            "isAvailable": false,
            "availabilityError": "runtime profile not found",
            "dataPath": "/Devices/ORPHAN/data",
            "dataPathSize": 2000
          }
        ]
      }
    }
    """

    nonisolated private static let runtimesJSON = """
    {
      "IMAGE-1": {
        "identifier": "IMAGE-1",
        "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-1",
        "sizeBytes": 8000000000,
        "lastUsedAt": "2026-10-01T08:00:00Z"
      },
      "IMAGE-2": {
        "identifier": "IMAGE-2"
      }
    }
    """
}
