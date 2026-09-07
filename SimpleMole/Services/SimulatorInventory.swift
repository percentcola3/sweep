import Combine
import Darwin
import Foundation

struct SimulatorDevice: Identifiable, Equatable, Sendable {
    let udid: String
    let name: String
    let runtimeIdentifier: String
    let runtimeName: String
    let state: String
    let isAvailable: Bool
    let availabilityError: String?
    let dataBytes: UInt64?
    let lastActivityAt: Date?

    var id: String { udid }

    /// Simulator devices contain app data and user sessions. Even a stopped
    /// device is a manual warning-level operation; running/unknown states are
    /// protected and cannot be submitted to the delete bridge.
    var risk: CleanupRisk {
        normalizedState == "shutdown" ? .warning : .protected
    }

    var disposal: CleanupDisposal { risk == .warning ? .command : .none }
    var reasonKey: String {
        if normalizedState == "shutdown" { return "cleanup.risk.userSession" }
        if normalizedState == "booted" { return "cleanup.risk.runningApplication" }
        return "cleanup.risk.runtimeUnknown"
    }

    var canDeleteManually: Bool { risk == .warning }

    private var normalizedState: String {
        state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct SimulatorDeleteSummary: Equatable, Sendable {
    let removed: Int
    let skipped: Int
    let failed: Int
}

enum SimulatorInventoryPhase: Equatable {
    case idle
    case loading
    case ready
    case unavailable
    case failed(String)
}

enum SimulatorInventoryError: LocalizedError {
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .invalidPayload:
            return "simctl returned an invalid device inventory"
        }
    }
}

enum SimulatorInventory {
    private struct Payload: Decodable {
        let devices: [String: [RawDevice]]
    }

    private struct RawDevice: Decodable {
        let name: String?
        let udid: String?
        let state: String?
        let isAvailable: Bool?
        let availabilityError: String?
        let lastBootedAt: String?
    }

    /// Decode simctl's JSON and measure only the canonical CoreSimulator UUID
    /// data directory. JSON-provided paths are deliberately ignored.
    static func decodeDevices(_ output: String, homeDirectory: URL) throws -> [SimulatorDevice] {
        guard let jsonStart = output.firstIndex(of: "{"),
              let data = String(output[jsonStart...]).data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw SimulatorInventoryError.invalidPayload
        }

        let home = homeDirectory.standardizedFileURL
        var result: [SimulatorDevice] = []
        for (runtimeIdentifier, rawDevices) in payload.devices {
            for raw in rawDevices {
                guard let rawUDID = raw.udid,
                      let uuid = UUID(uuidString: rawUDID),
                      let name = raw.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty else { continue }

                let udid = uuid.uuidString
                let dataURL = home
                    .appendingPathComponent("Library/Developer/CoreSimulator/Devices", isDirectory: true)
                    .appendingPathComponent(udid, isDirectory: true)
                    .appendingPathComponent("data", isDirectory: true)
                let measurement = measureDirectory(at: dataURL)
                let lastBootedAt = raw.lastBootedAt.flatMap(parseISO8601)
                let lastActivity = [lastBootedAt, measurement.modifiedAt]
                    .compactMap { $0 }
                    .max()

                result.append(SimulatorDevice(
                    udid: udid,
                    name: name,
                    runtimeIdentifier: runtimeIdentifier,
                    runtimeName: displayName(forRuntimeIdentifier: runtimeIdentifier),
                    state: raw.state ?? "Unknown",
                    isAvailable: raw.isAvailable ?? false,
                    availabilityError: raw.availabilityError,
                    dataBytes: measurement.bytes,
                    lastActivityAt: lastActivity
                ))
            }
        }
        return result.sorted {
            if $0.runtimeName != $1.runtimeName { return $0.runtimeName < $1.runtimeName }
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.udid < $1.udid
        }
    }

    static func displayName(forRuntimeIdentifier identifier: String) -> String {
        let marker = ".SimRuntime."
        guard let range = identifier.range(of: marker) else { return identifier }
        let suffix = String(identifier[range.upperBound...])
        let parts = suffix.split(separator: "-", omittingEmptySubsequences: true)
        guard let platform = parts.first else { return suffix }
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? String(platform) : "\(platform) \(version)"
    }

    static func deleteSummary(_ output: String) -> SimulatorDeleteSummary {
        var values: [String: Int] = [:]
        for line in output.components(separatedBy: .newlines) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let value = Int(parts[1]) else { continue }
            values[parts[0]] = value
        }
        return SimulatorDeleteSummary(removed: values["removed"] ?? 0,
                                      skipped: values["skipped"] ?? 0,
                                      failed: values["failed"] ?? 0)
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func measureDirectory(at root: URL) -> (bytes: UInt64?, modifiedAt: Date?) {
        var rootStat = stat()
        guard Darwin.lstat(root.path, &rootStat) == 0 else {
            return (0, nil)
        }
        let rootKind = rootStat.st_mode & mode_t(S_IFMT)
        guard rootKind == mode_t(S_IFDIR) else { return (nil, nil) }

        var total = allocatedBytes(rootStat)
        var newest = modificationDate(rootStat)
        var scanFailed = total == nil
        let fileManager = FileManager()
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in
                scanFailed = true
                return false
            }
        ) else { return (nil, newest) }

        while let child = enumerator.nextObject() as? URL {
            var metadata = stat()
            guard Darwin.lstat(child.path, &metadata) == 0 else {
                scanFailed = true
                break
            }
            let kind = metadata.st_mode & mode_t(S_IFMT)
            if kind == mode_t(S_IFLNK) {
                enumerator.skipDescendants()
                continue
            }
            guard let bytes = allocatedBytes(metadata), let current = total else {
                scanFailed = true
                break
            }
            let (sum, overflow) = current.addingReportingOverflow(bytes)
            guard !overflow else {
                scanFailed = true
                break
            }
            total = sum
            newest = max(newest, modificationDate(metadata))
        }
        return (scanFailed ? nil : total, newest)
    }

    private static func allocatedBytes(_ metadata: stat) -> UInt64? {
        guard metadata.st_blocks >= 0 else { return nil }
        let (bytes, overflow) = UInt64(metadata.st_blocks).multipliedReportingOverflow(by: 512)
        return overflow ? nil : bytes
    }

    private static func modificationDate(_ metadata: stat) -> Date {
        Date(timeIntervalSince1970: TimeInterval(metadata.st_mtimespec.tv_sec)
            + TimeInterval(metadata.st_mtimespec.tv_nsec) / 1_000_000_000)
    }
}

#if !INVENTORY_PARSER_TESTS
@MainActor
final class SimulatorInventoryStore: ObservableObject {
    @Published private(set) var devices: [SimulatorDevice] = []
    @Published private(set) var phase: SimulatorInventoryPhase = .idle
    @Published private(set) var isDeleting = false
    @Published private(set) var lastDeleteSummary: SimulatorDeleteSummary?

    var groupedDevices: [(runtime: String, devices: [SimulatorDevice])] {
        var order: [String] = []
        var buckets: [String: [SimulatorDevice]] = [:]
        for device in devices {
            if buckets[device.runtimeName] == nil { order.append(device.runtimeName) }
            buckets[device.runtimeName, default: []].append(device)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    func scan() {
        guard phase != .loading, !isDeleting else { return }
        Task { await reload() }
    }

    /// This is intentionally the only destructive API. Callers must present a
    /// warning confirmation before invoking it; the bridge independently
    /// rejects any device that is not still in Shutdown state.
    func deleteAfterUserConfirmation(_ ids: Set<String>) {
        guard !isDeleting, phase != .loading else { return }
        let allowed = devices.filter { ids.contains($0.id) && $0.canDeleteManually }
        guard !allowed.isEmpty else { return }

        var input = Data()
        for device in allowed {
            input.append(contentsOf: device.udid.utf8)
            input.append(0)
        }
        isDeleting = true
        lastDeleteSummary = nil
        Task {
            let result = await MoleEngine.shared.runBridgeWithStdin(
                "bin/app_simulator_delete.sh", stdinData: input, timeout: 900)
            lastDeleteSummary = SimulatorInventory.deleteSummary(result.output)
            isDeleting = false
            if !result.succeeded, lastDeleteSummary?.failed == 0 {
                phase = .failed(result.diagnosticOutput)
                return
            }
            await reload()
        }
    }

    private func reload() async {
        phase = .loading
        let result = await MoleEngine.shared.runBridge("bin/app_simulator_scan.sh", timeout: 120)
        guard result.succeeded else {
            devices = []
            phase = .failed(result.diagnosticOutput)
            return
        }
        guard !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            devices = []
            phase = .unavailable
            return
        }
        do {
            let output = result.output
            let home = FileManager.default.homeDirectoryForCurrentUser
            devices = try await Task.detached(priority: .utility) {
                try SimulatorInventory.decodeDevices(output, homeDirectory: home)
            }.value
            phase = .ready
        } catch {
            devices = []
            phase = .failed(error.localizedDescription)
        }
    }
}
#endif
