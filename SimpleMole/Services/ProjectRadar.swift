import Foundation
import Combine

enum ProjectArtifactKind: String, Codable, CaseIterable, Sendable {
    case cacheTag
    case pythonCache
    case javascriptCache
    case rustTarget
    case javaCache
    case swiftBuild
    case dartCache
    case zigCache
    case nativeBuildCache
    case coverage
    case dependencyNodeModules
    case dependencyPods
    case dependencyComposer
    case dependencyVirtualEnv
    case genericBuildOutput
    case unknown

    var isDependency: Bool {
        switch self {
        case .dependencyNodeModules, .dependencyPods, .dependencyComposer,
             .dependencyVirtualEnv:
            return true
        default:
            return false
        }
    }
}

struct ProjectArtifact: Identifiable, Codable, Equatable, Sendable {
    var id: String { path }
    let projectRoot: String
    let path: String
    let identity: String
    let kind: ProjectArtifactKind
    let risk: AutomationRisk
    let bytes: UInt64
    let modifiedAt: Date

    func automationItem(runtimeState: AutomationRuntimeState) -> AutomationItem {
        AutomationItem(path: path,
                       identity: identity,
                       bytes: bytes,
                       risk: risk,
                       disposition: .trash,
                       source: .projectArtifact,
                       requiresPrivilege: false,
                       runtimeState: runtimeState)
    }
}

struct RadarProject: Identifiable, Codable, Equatable, Sendable {
    /// Bind persisted automation scope to both the normalized path and current
    /// filesystem object. Reused inodes at another path never inherit consent.
    var id: String { "\(rootPath.utf8.count):\(rootPath):\(rootIdentity)" }
    let rootPath: String
    let rootIdentity: String
    let lastActivityAt: Date
    var artifacts: [ProjectArtifact]

    var displayName: String {
        URL(fileURLWithPath: rootPath, isDirectory: true).lastPathComponent
    }

    var safeArtifacts: [ProjectArtifact] { artifacts.filter { $0.risk == .safe } }
    var warningArtifacts: [ProjectArtifact] { artifacts.filter { $0.risk == .warning } }
    var protectedArtifacts: [ProjectArtifact] { artifacts.filter { $0.risk == .protected } }

    var safeBytes: UInt64 { safeArtifacts.reduce(0) { $0 &+ $1.bytes } }
    var warningBytes: UInt64 { warningArtifacts.reduce(0) { $0 &+ $1.bytes } }
    var protectedBytes: UInt64 { protectedArtifacts.reduce(0) { $0 &+ $1.bytes } }
}

struct ProjectRadarSnapshot: Equatable, Sendable {
    var projects: [RadarProject]
    var availableLocations: [String]
    var unavailableLocations: [String]

    static let empty = ProjectRadarSnapshot(projects: [],
                                            availableLocations: [],
                                            unavailableLocations: [])
}

enum ProjectRadarError: LocalizedError, Equatable {
    case malformedRecord(String)

    var errorDescription: String? {
        switch self {
        case .malformedRecord(let type): return "Malformed project radar record: \(type)"
        }
    }
}

struct ProjectActivityStatus: Equatable, Sendable {
    let projectRoot: String
    let state: AutomationRuntimeState
    let reason: String
}

enum ProjectActivity {
    static func requestData(for projectRoots: [String]) -> Data {
        var data = Data()
        for root in projectRoots {
            data.append(contentsOf: root.utf8)
            data.append(0)
        }
        return data
    }

    /// Protocol: activity, root, idle|active|unknown, reason; summary, checked, active, unknown.
    static func parse(_ data: Data) throws -> [String: ProjectActivityStatus] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false).map {
            String(decoding: $0, as: UTF8.self)
        }
        var index = 0
        var result: [String: ProjectActivityStatus] = [:]
        while index < fields.count {
            let record = fields[index]
            index += 1
            if record.isEmpty { continue }
            switch record {
            case "activity":
                guard index + 3 <= fields.count,
                      let state = AutomationRuntimeState(rawValue: fields[index + 1]),
                      !fields[index].isEmpty else {
                    throw ProjectRadarError.malformedRecord(record)
                }
                let root = fields[index]
                result[root] = ProjectActivityStatus(projectRoot: root,
                                                     state: state,
                                                     reason: fields[index + 2])
                index += 3
            case "summary":
                guard index + 3 <= fields.count,
                      Int(fields[index]) != nil,
                      Int(fields[index + 1]) != nil,
                      Int(fields[index + 2]) != nil else {
                    throw ProjectRadarError.malformedRecord(record)
                }
                index += 3
            default:
                throw ProjectRadarError.malformedRecord(record)
            }
        }
        return result
    }
}

enum ProjectRadar {
    /// NUL-delimited roots preserve spaces and tabs without granting any write authority.
    static func requestData(for locations: [SavedScanLocation]) -> Data {
        var data = Data()
        for location in locations {
            data.append(contentsOf: location.path.utf8)
            data.append(0)
        }
        return data
    }

    static func parse(_ text: String) throws -> ProjectRadarSnapshot {
        try parse(Data(text.utf8))
    }

    /// Protocol:
    /// - location, path, available|unavailable
    /// - project, root, dev:inode, lastActivityEpoch
    /// - artifact, projectRoot, risk, kind, bytes, mtimeEpoch, identity, path
    /// - summary, projectCount, artifactCount, unavailableCount
    static func parse(_ data: Data) throws -> ProjectRadarSnapshot {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false).map {
            String(decoding: $0, as: UTF8.self)
        }
        var index = 0
        var projectOrder: [String] = []
        var projectValues: [String: (identity: String, lastActivity: Date)] = [:]
        var artifacts: [String: [ProjectArtifact]] = [:]
        var available: [String] = []
        var unavailable: [String] = []

        func require(_ count: Int, record: String) throws {
            guard index + count <= fields.count else {
                throw ProjectRadarError.malformedRecord(record)
            }
        }

        while index < fields.count {
            let record = fields[index]
            index += 1
            if record.isEmpty { continue }
            switch record {
            case "location":
                try require(2, record: record)
                let path = fields[index]
                let state = fields[index + 1]
                index += 2
                if state == "available" {
                    if !available.contains(path) { available.append(path) }
                } else if state == "unavailable" {
                    if !unavailable.contains(path) { unavailable.append(path) }
                } else {
                    throw ProjectRadarError.malformedRecord(record)
                }

            case "project":
                try require(3, record: record)
                let root = fields[index]
                let identity = fields[index + 1]
                let epoch = TimeInterval(fields[index + 2])
                index += 3
                guard !root.isEmpty, !identity.isEmpty, let epoch else {
                    throw ProjectRadarError.malformedRecord(record)
                }
                if projectValues[root] == nil { projectOrder.append(root) }
                projectValues[root] = (identity, Date(timeIntervalSince1970: epoch))

            case "artifact":
                try require(7, record: record)
                let root = fields[index]
                let risk = AutomationRisk(rawValue: fields[index + 1])
                let kind = ProjectArtifactKind(rawValue: fields[index + 2]) ?? .unknown
                let bytes = UInt64(fields[index + 3])
                let epoch = TimeInterval(fields[index + 4])
                let identity = fields[index + 5]
                let path = fields[index + 6]
                index += 7
                guard let risk, let bytes, let epoch,
                      !root.isEmpty, !identity.isEmpty, !path.isEmpty else {
                    throw ProjectRadarError.malformedRecord(record)
                }
                let artifact = ProjectArtifact(projectRoot: root,
                                               path: path,
                                               identity: identity,
                                               kind: kind,
                                               risk: risk,
                                               bytes: bytes,
                                               modifiedAt: Date(timeIntervalSince1970: epoch))
                if !(artifacts[root] ?? []).contains(where: { $0.path == path }) {
                    artifacts[root, default: []].append(artifact)
                }

            case "summary":
                try require(3, record: record)
                index += 3

            default:
                throw ProjectRadarError.malformedRecord(record)
            }
        }

        let projects = projectOrder.compactMap { root -> RadarProject? in
            guard let value = projectValues[root] else { return nil }
            let sortedArtifacts = (artifacts[root] ?? []).sorted {
                if $0.risk != $1.risk {
                    let rank: [AutomationRisk: Int] = [.safe: 0, .warning: 1, .protected: 2]
                    return (rank[$0.risk] ?? 3) < (rank[$1.risk] ?? 3)
                }
                return $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
            return RadarProject(rootPath: root,
                                rootIdentity: value.identity,
                                lastActivityAt: value.lastActivity,
                                artifacts: sortedArtifacts)
        }.sorted { $0.rootPath.localizedStandardCompare($1.rootPath) == .orderedAscending }

        return ProjectRadarSnapshot(projects: projects,
                                    availableLocations: available.sorted(),
                                    unavailableLocations: unavailable.sorted())
    }
}

#if !PROJECT_RADAR_PARSER_TESTS
@MainActor
final class ProjectRadarStore: ObservableObject {
    @Published private(set) var snapshot: ProjectRadarSnapshot = .empty
    @Published private(set) var isScanning = false
    @Published private(set) var lastError: String?

    func scan(locations: [SavedScanLocation], fullDiskAccessGranted: Bool) {
        guard !isScanning else { return }
        Task {
            _ = await reload(
                locations: locations,
                fullDiskAccessGranted: fullDiskAccessGranted)
        }
    }

    /// Returns true only when this invocation produced a fresh, fully parsed
    /// snapshot. Callers that authorize automation must never reuse stale UI
    /// data after a failed or overlapping scan.
    @discardableResult
    func reload(locations: [SavedScanLocation],
                fullDiskAccessGranted: Bool) async -> Bool {
        guard fullDiskAccessGranted else {
            snapshot = .empty
            lastError = "Full Disk Access is required for project scanning."
            return false
        }
        guard !isScanning else { return false }
        isScanning = true
        defer { isScanning = false }

        let input = ProjectRadar.requestData(for: locations)
        let result = await MoleEngine.shared.runBridgeWithStdin(
            "bin/app_project_radar.sh",
            stdinData: input,
            extraEnvironment: ["FORGESWEEP_FULL_DISK_AUTHORIZED": "1"],
            timeout: 300)
        guard result.succeeded else {
            snapshot = .empty
            lastError = result.diagnosticOutput.isEmpty
                ? "Project radar scan failed without diagnostics."
                : result.diagnosticOutput
            return false
        }
        do {
            snapshot = try ProjectRadar.parse(Data(result.output.utf8))
            lastError = nil
            return true
        } catch {
            snapshot = .empty
            lastError = error.localizedDescription
            return false
        }
    }
}
#endif
