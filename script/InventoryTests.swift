import Foundation

#if INVENTORY_PARSER_TESTS
enum CleanupRisk: Equatable {
    case safe
    case warning
    case protected
}

enum CleanupDisposal: Equatable {
    case trash
    case command
    case privileged
    case transform
    case none
}
#endif

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
private enum InventoryTests {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw TestFailure(description: "usage: InventoryTests <fixture-root>")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try testSimulatorDecoder(root: root)
        try testDockerDecoder()
        print("inventory parser tests passed")
    }

    private static func testSimulatorDecoder(root: URL) throws {
        let fileManager = FileManager()
        let home = root.appendingPathComponent("home", isDirectory: true)
        let devicesRoot = home.appendingPathComponent(
            "Library/Developer/CoreSimulator/Devices", isDirectory: true)
        let shutdownID = "11111111-1111-4111-8111-111111111111"
        let bootedID = "22222222-2222-4222-8222-222222222222"
        let unknownID = "33333333-3333-4333-8333-333333333333"
        let dataRoot = devicesRoot
            .appendingPathComponent(shutdownID.uppercased(), isDirectory: true)
            .appendingPathComponent("data", isDirectory: true)
        try fileManager.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        try Data(repeating: 0x5a, count: 32 * 1024)
            .write(to: dataRoot.appendingPathComponent("cache.bin"))

        let external = root.appendingPathComponent("external.bin")
        try Data(repeating: 0x33, count: 3 * 1024 * 1024).write(to: external)
        try fileManager.createSymbolicLink(
            at: dataRoot.appendingPathComponent("external-link"),
            withDestinationURL: external)

        let json = #"""
        simctl note before JSON
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-18-0": [
              {
                "name": "iPhone Test",
                "udid": "11111111-1111-4111-8111-111111111111",
                "state": "Shutdown",
                "isAvailable": true,
                "lastBootedAt": "2026-08-01T10:00:00.000Z",
                "dataPath": "/private/should-not-be-used"
              },
              {
                "name": "Running Phone",
                "udid": "22222222-2222-4222-8222-222222222222",
                "state": "Booted",
                "isAvailable": true
              },
              {
                "name": "Transitioning Phone",
                "udid": "33333333-3333-4333-8333-333333333333",
                "state": "Creating",
                "isAvailable": false,
                "availabilityError": "runtime missing"
              },
              {
                "name": "Bad Identifier",
                "udid": "../../etc",
                "state": "Shutdown"
              }
            ]
          }
        }
        """#

        let devices = try SimulatorInventory.decodeDevices(json, homeDirectory: home)
        try expect(devices.count == 3, "invalid simulator UUID was not discarded")
        guard let shutdown = devices.first(where: { $0.udid == shutdownID.uppercased() }),
              let booted = devices.first(where: { $0.udid == bootedID.uppercased() }),
              let unknown = devices.first(where: { $0.udid == unknownID.uppercased() }) else {
            throw TestFailure(description: "decoded simulator devices are incomplete")
        }
        try expect(shutdown.runtimeName == "iOS 18.0", "runtime display name is unstable")
        try expect(shutdown.risk == .warning && shutdown.disposal == .command,
                   "stopped simulator was not kept manual-warning only")
        try expect(booted.risk == .protected && !booted.canDeleteManually,
                   "booted simulator was not protected")
        try expect(unknown.risk == .protected && !unknown.canDeleteManually,
                   "unknown simulator state was not protected")
        try expect((shutdown.dataBytes ?? 0) > 0, "fixed simulator data directory was not measured")
        try expect((shutdown.dataBytes ?? UInt64.max) < 2 * 1024 * 1024,
                   "simulator size scan followed a symlink outside its UUID directory")
        try expect(booted.dataBytes == 0, "missing simulator data directory should report zero")

        let summary = SimulatorInventory.deleteSummary("removed=2\nskipped=1\nfailed=3\n")
        try expect(summary == SimulatorDeleteSummary(removed: 2, skipped: 1, failed: 3),
                   "simulator delete summary parsing failed")
    }

    private static func testDockerDecoder() throws {
        let text = #"""
        images	{"Containers":"2","CreatedSince":"2 days ago","ID":"sha256:abcdef1234567890","Repository":"swift","Size":"1.2GB","Tag":"latest"}
        images	{"Containers":"2","CreatedSince":"2 days ago","ID":"sha256:abcdef1234567890","Repository":"swift","Size":"1.2GB","Tag":"nightly"}
        containers	{"ID":"1234567890abcdef","Image":"api:dev","Names":"api-dev","Size":"14MB (virtual 800MB)","State":"running","Status":"Up 2 hours"}
        volumes	{"Driver":"local","Name":"build-cache","Scope":"local"}
        build-cache	{"Description":"frontend build","ID":"cache-record-1","InUse":false,"Size":"420MB"}
        images	not-json
        unknown	{"ID":"ignored"}
        """#
        let items = DockerInventory.decodeItems(text)
        try expect(items.count == 5, "Docker JSONL parser accepted invalid rows or lost valid rows")
        let imageRows = items.filter { $0.kind == .images }
        try expect(Set(imageRows.map(\.id)).count == 2,
                   "multi-tag Docker image rows reused the same UI identity")

        guard let image = items.first(where: { $0.kind == .images }),
              let container = items.first(where: { $0.kind == .containers }),
              let volume = items.first(where: { $0.kind == .volumes }),
              let cache = items.first(where: { $0.kind == .buildCache }) else {
            throw TestFailure(description: "Docker categories were not decoded")
        }
        try expect(image.title == "swift:latest" && image.isActive == true,
                   "Docker image fields were not normalized")
        try expect(container.title == "api-dev" && container.isActive == true,
                   "Docker container state was not normalized")
        try expect(volume.resourceID == "build-cache", "Docker volume identity is unstable")
        try expect(cache.title == "frontend build" && cache.isActive == false,
                   "Docker build cache fields were not normalized")

        let emptySuccesses = DockerResourceKind.allCases.map {
            DockerInventory.CommandResult(kind: $0, succeeded: true,
                                          output: "", diagnostic: "")
        }
        try expect(DockerInventory.scanResult(from: emptySuccesses).phase == .ready,
                   "empty successful Docker inventory was not treated as ready")

        let silentPartial = DockerResourceKind.allCases.map { kind in
            DockerInventory.CommandResult(kind: kind,
                                          succeeded: kind != .images,
                                          output: "", diagnostic: "")
        }
        let silentPartialResult = DockerInventory.scanResult(from: silentPartial)
        guard case .partial(let silentDiagnostic) = silentPartialResult.phase else {
            throw TestFailure(description: "silent Docker command failure was reported ready")
        }
        try expect(silentDiagnostic.contains("failed without diagnostics"),
                   "silent Docker command failure lost its fallback diagnostic")
        try expect(silentPartialResult.diagnosticsByKind[.images] != nil
                   && !silentPartialResult.completedKinds.contains(.images),
                   "failed Docker category was indistinguishable from an empty category")

        let allSilentFailures = DockerResourceKind.allCases.map {
            DockerInventory.CommandResult(kind: $0, succeeded: false,
                                          output: "", diagnostic: "")
        }
        guard case .failed(let failedDiagnostic) = DockerInventory.scanResult(
            from: allSilentFailures).phase else {
            throw TestFailure(description: "all silent Docker failures were not failed")
        }
        try expect(!failedDiagnostic.isEmpty,
                   "all silent Docker failures produced an empty diagnostic")

        let malformed = DockerResourceKind.allCases.map { kind in
            DockerInventory.CommandResult(
                kind: kind,
                succeeded: true,
                output: kind == .images ? "images\tnot-json\n" : "",
                diagnostic: "")
        }
        let malformedScan = DockerInventory.scanResult(from: malformed)
        guard case .partial(let malformedDiagnostic) = malformedScan.phase else {
            throw TestFailure(description: "non-empty malformed Docker output was reported ready")
        }
        try expect(malformedScan.items.isEmpty && malformedDiagnostic.contains("unparseable"),
                   "malformed Docker output did not surface a protocol diagnostic")
    }

    private static func expect(_ condition: @autoclosure () -> Bool,
                               _ message: String) throws {
        if !condition() { throw TestFailure(description: message) }
    }
}
