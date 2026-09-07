import Foundation
import Combine
import Darwin

enum ProjectHibernationMode: String, Codable, Sendable {
    case automatic
    case manual
}

enum ProjectHibernationError: LocalizedError, Equatable {
    case invalidProjectRoot(String)
    case unsupportedTrashVolume(String)
    case noEligibleArtifacts
    case projectActive(String)
    case bridgeFailed(String)
    case malformedBridgeRecord(String)

    var errorDescription: String? {
        switch self {
        case .invalidProjectRoot(let path): return "Invalid project root: \(path)"
        case .unsupportedTrashVolume(let path):
            return "Project hibernation currently requires the same volume as your home Trash: \(path)"
        case .noEligibleArtifacts: return "No eligible project artifacts"
        case .projectActive(let reason): return "Project activity prevents hibernation: \(reason)"
        case .bridgeFailed(let message): return message
        case .malformedBridgeRecord(let record): return "Malformed hibernation record: \(record)"
        }
    }
}

struct ProjectHibernationPlan: Identifiable, Equatable, Sendable {
    let id: UUID
    let projectRoot: String
    let projectRootIdentity: String
    let mode: ProjectHibernationMode
    let maximumProjectActivityAt: Date?
    let artifacts: [ProjectArtifact]

    var totalBytes: UInt64 { artifacts.reduce(0) { $0 &+ $1.bytes } }

    /// NUL records: root, rootIdentity, mode, maximumActivityEpochOrDash,
    /// expectedRisk, expectedKind,
    /// artifactPath, artifactIdentity. The bridge recomputes risk and kind.
    var stdinData: Data {
        var data = Data()
        let activityCutoff = maximumProjectActivityAt.map {
            String(Int64($0.timeIntervalSince1970.rounded(.down)))
        } ?? "-"
        for artifact in artifacts {
            let fields = [projectRoot, projectRootIdentity, mode.rawValue,
                          activityCutoff,
                          artifact.risk.rawValue, artifact.kind.rawValue,
                          artifact.path, artifact.identity]
            for field in fields {
                data.append(contentsOf: field.utf8)
                data.append(0)
            }
        }
        return data
    }
}

enum HibernatedArtifactState: String, Codable, Sendable {
    case trashed
    case restored
    case unavailable
}

struct HibernatedArtifactReceipt: Identifiable, Codable, Equatable, Sendable {
    var id: String { originalPath }
    let originalPath: String
    let originalIdentity: String
    var trashPath: String
    var trashIdentity: String
    let bytes: UInt64
    let kind: ProjectArtifactKind
    var state: HibernatedArtifactState
}

enum ProjectHibernationReceiptState: String, Codable, Sendable {
    case hibernated
    case partial
    case restored
    case unavailable
}

struct ProjectHibernationReceipt: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    let planID: UUID
    let projectRoot: String
    let projectRootIdentity: String
    let createdAt: Date
    var state: ProjectHibernationReceiptState
    var artifacts: [HibernatedArtifactReceipt]

    var recoverableArtifacts: [HibernatedArtifactReceipt] {
        artifacts.filter { $0.state == .trashed }
    }

    var recoverableBytes: UInt64 {
        recoverableArtifacts.reduce(0) { $0 &+ $1.bytes }
    }

    /// NUL records: root, rootIdentity, originalPath, originalIdentity,
    /// trashPath, trashIdentity, kind.
    var restoreStdinData: Data {
        var data = Data()
        for artifact in recoverableArtifacts {
            let fields = [projectRoot, projectRootIdentity,
                          artifact.originalPath, artifact.originalIdentity,
                          artifact.trashPath, artifact.trashIdentity,
                          artifact.kind.rawValue]
            for field in fields {
                data.append(contentsOf: field.utf8)
                data.append(0)
            }
        }
        return data
    }
}

struct ProjectRestoreResult: Equatable, Sendable {
    let restoredPaths: [String]
    let failed: Int
}

enum ProjectHibernation {
    static func supportsRecoverableTrash(for projectRoot: String,
                                         homeDirectory: String = NSHomeDirectory()) -> Bool {
        var projectMetadata = stat()
        var homeMetadata = stat()
        guard Darwin.lstat(projectRoot, &projectMetadata) == 0,
              Darwin.lstat(homeDirectory, &homeMetadata) == 0,
              projectMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              homeMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return false }
        return projectMetadata.st_dev == homeMetadata.st_dev
    }

    static func pendingReceipt(for plan: ProjectHibernationPlan,
                               id: UUID = UUID(),
                               now: Date = Date()) -> ProjectHibernationReceipt {
        ProjectHibernationReceipt(
            id: id,
            planID: plan.id,
            projectRoot: plan.projectRoot,
            projectRootIdentity: plan.projectRootIdentity,
            createdAt: now,
            state: .partial,
            artifacts: plan.artifacts.map {
                HibernatedArtifactReceipt(originalPath: $0.path,
                                           originalIdentity: $0.identity,
                                           trashPath: "",
                                           trashIdentity: "",
                                           bytes: $0.bytes,
                                           kind: $0.kind,
                                           state: .unavailable)
            })
    }

    static func makePlan(project: RadarProject,
                         mode: ProjectHibernationMode,
                         runtimeState: AutomationRuntimeState,
                         maximumProjectActivityAt: Date? = nil,
                         manuallyIncludedWarningPaths: Set<String> = []) throws -> ProjectHibernationPlan {
        guard (project.rootPath as NSString).isAbsolutePath,
              !project.rootPath.isEmpty,
              !project.rootIdentity.isEmpty else {
            throw ProjectHibernationError.invalidProjectRoot(project.rootPath)
        }

        let root = URL(fileURLWithPath: project.rootPath, isDirectory: true).standardizedFileURL.path
        let eligible = project.artifacts.filter { artifact in
            let path = URL(fileURLWithPath: artifact.path).standardizedFileURL.path
            guard path != root, path.hasPrefix(root + "/"),
                  !AutomationPolicy.isSensitivePath(path),
                  !artifact.identity.isEmpty else { return false }

            if mode == .automatic {
                return AutomationPolicy.canAutomate(
                    artifact.automationItem(runtimeState: runtimeState))
            }
            if artifact.risk == .safe { return runtimeState == .idle }
            return artifact.risk == .warning
                && manuallyIncludedWarningPaths.contains(artifact.path)
                && runtimeState == .idle
        }
        guard !eligible.isEmpty else { throw ProjectHibernationError.noEligibleArtifacts }
        return ProjectHibernationPlan(id: UUID(),
                                      projectRoot: root,
                                      projectRootIdentity: project.rootIdentity,
                                      mode: mode,
                                      maximumProjectActivityAt: maximumProjectActivityAt,
                                      artifacts: eligible.sorted { $0.path < $1.path })
    }

    /// Output records:
    /// - trashed, root, original, originalIdentity, trashPath, trashIdentity, bytes, kind
    /// - unavailable, root, original, originalIdentity, bytes, kind
    /// - summary, removed, failed
    static func parseHibernateOutput(_ data: Data,
                                     plan: ProjectHibernationPlan,
                                     receiptID: UUID = UUID(),
                                     now: Date = Date()) throws -> ProjectHibernationReceipt {
        let fields = nulFields(data)
        var index = 0
        var artifacts: [HibernatedArtifactReceipt] = []
        var reportedFailures = 0

        func require(_ count: Int, _ record: String) throws {
            guard index + count <= fields.count else {
                throw ProjectHibernationError.malformedBridgeRecord(record)
            }
        }

        while index < fields.count {
            let record = fields[index]
            index += 1
            if record.isEmpty { continue }
            switch record {
            case "trashed":
                try require(7, record)
                let root = fields[index]
                let original = fields[index + 1]
                let originalIdentity = fields[index + 2]
                let trashPath = fields[index + 3]
                let trashIdentity = fields[index + 4]
                let bytes = UInt64(fields[index + 5])
                let kind = ProjectArtifactKind(rawValue: fields[index + 6])
                index += 7
                guard root == plan.projectRoot, let bytes, let kind,
                      !original.isEmpty, !originalIdentity.isEmpty,
                      !trashPath.isEmpty, !trashIdentity.isEmpty else {
                    throw ProjectHibernationError.malformedBridgeRecord(record)
                }
                artifacts.append(.init(originalPath: original,
                                       originalIdentity: originalIdentity,
                                       trashPath: trashPath,
                                       trashIdentity: trashIdentity,
                                       bytes: bytes,
                                       kind: kind,
                                       state: .trashed))

            case "unavailable":
                try require(5, record)
                let root = fields[index]
                let original = fields[index + 1]
                let originalIdentity = fields[index + 2]
                let bytes = UInt64(fields[index + 3])
                let kind = ProjectArtifactKind(rawValue: fields[index + 4])
                index += 5
                guard root == plan.projectRoot, let bytes, let kind else {
                    throw ProjectHibernationError.malformedBridgeRecord(record)
                }
                artifacts.append(.init(originalPath: original,
                                       originalIdentity: originalIdentity,
                                       trashPath: "",
                                       trashIdentity: "",
                                       bytes: bytes,
                                       kind: kind,
                                       state: .unavailable))
                reportedFailures += 1

            case "summary":
                try require(2, record)
                guard UInt64(fields[index]) != nil, let failed = Int(fields[index + 1]) else {
                    throw ProjectHibernationError.malformedBridgeRecord(record)
                }
                reportedFailures = max(reportedFailures, failed)
                index += 2

            default:
                throw ProjectHibernationError.malformedBridgeRecord(record)
            }
        }

        let state: ProjectHibernationReceiptState
        if artifacts.isEmpty {
            state = .unavailable
        } else if reportedFailures > 0 || artifacts.count != plan.artifacts.count {
            state = .partial
        } else {
            state = .hibernated
        }
        return ProjectHibernationReceipt(id: receiptID,
                                         planID: plan.id,
                                         projectRoot: plan.projectRoot,
                                         projectRootIdentity: plan.projectRootIdentity,
                                         createdAt: now,
                                         state: state,
                                         artifacts: artifacts)
    }

    /// Output records: restored, root, original, trashPath, kind; summary, restored, failed.
    static func parseRestoreOutput(_ data: Data) throws -> ProjectRestoreResult {
        let fields = nulFields(data)
        var index = 0
        var restored: [String] = []
        var failed = 0
        while index < fields.count {
            let record = fields[index]
            index += 1
            if record.isEmpty { continue }
            switch record {
            case "restored":
                guard index + 4 <= fields.count else {
                    throw ProjectHibernationError.malformedBridgeRecord(record)
                }
                restored.append(fields[index + 1])
                index += 4
            case "summary":
                guard index + 2 <= fields.count,
                      Int(fields[index]) != nil,
                      let count = Int(fields[index + 1]) else {
                    throw ProjectHibernationError.malformedBridgeRecord(record)
                }
                failed = count
                index += 2
            default:
                throw ProjectHibernationError.malformedBridgeRecord(record)
            }
        }
        return ProjectRestoreResult(restoredPaths: restored, failed: failed)
    }

    static func applying(_ result: ProjectRestoreResult,
                         to receipt: ProjectHibernationReceipt) -> ProjectHibernationReceipt {
        var updated = receipt
        let restored = Set(result.restoredPaths)
        for index in updated.artifacts.indices where restored.contains(updated.artifacts[index].originalPath) {
            updated.artifacts[index].state = .restored
        }
        if updated.artifacts.allSatisfy({ $0.state == .restored }) {
            updated.state = .restored
        } else if updated.artifacts.contains(where: { $0.state == .trashed }) {
            updated.state = .partial
        } else {
            updated.state = .unavailable
        }
        return updated
    }

    private static func nulFields(_ data: Data) -> [String] {
        data.split(separator: 0, omittingEmptySubsequences: false).map {
            String(decoding: $0, as: UTF8.self)
        }
    }
}

@MainActor
final class ProjectHibernationReceiptStore: ObservableObject {
    private struct Payload: Codable {
        var schemaVersion: Int
        var receipts: [ProjectHibernationReceipt]
    }

    static let schemaVersion = 1

    static var defaultFileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/ForgeSweep", isDirectory: true)
            .appendingPathComponent("project-hibernation-v1.json", isDirectory: false)
    }

    @Published private(set) var receipts: [ProjectHibernationReceipt]
    @Published private(set) var lastError: String?

    private let fileURL: URL
    private let fileManager: FileManager
    private let trashDirectoryURL: URL

    init(fileURL: URL? = nil,
         fileManager: FileManager = .default,
         trashDirectoryURL: URL? = nil) {
        let resolvedFileURL = fileURL ?? Self.defaultFileURL
        let loaded = Self.loadResult(from: resolvedFileURL, fileManager: fileManager)
        self.fileURL = resolvedFileURL
        self.fileManager = fileManager
        self.trashDirectoryURL = trashDirectoryURL
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(".Trash", isDirectory: true)
        self.receipts = loaded.receipts
        self.lastError = loaded.error
    }

    @discardableResult
    func upsert(_ receipt: ProjectHibernationReceipt) -> Bool {
        var next = receipts
        if let index = receipts.firstIndex(where: { $0.id == receipt.id }) {
            next[index] = receipt
        } else {
            next.append(receipt)
        }
        return persist(next)
    }

    @discardableResult
    func remove(id: UUID) -> Bool {
        let next = receipts.filter { $0.id != id }
        guard next != receipts else { return true }
        return persist(next)
    }

    func refreshAvailability(persist shouldPersist: Bool = true) {
        var changed = recoverPendingTrashArtifacts()
        for receiptIndex in receipts.indices {
            for artifactIndex in receipts[receiptIndex].artifacts.indices {
                let artifact = receipts[receiptIndex].artifacts[artifactIndex]
                guard artifact.state == .trashed else { continue }
                if artifact.trashPath.isEmpty
                    || Self.pathIdentity(artifact.trashPath) != artifact.trashIdentity {
                    receipts[receiptIndex].artifacts[artifactIndex].state = .unavailable
                    changed = true
                }
            }
            let values = receipts[receiptIndex].artifacts.map(\.state)
            let nextState: ProjectHibernationReceiptState
            if !values.isEmpty && values.allSatisfy({ $0 == .restored }) {
                nextState = .restored
            } else if !values.isEmpty && values.allSatisfy({ $0 == .trashed }) {
                nextState = .hibernated
            } else if values.isEmpty || values.allSatisfy({ $0 == .unavailable }) {
                nextState = .unavailable
            } else {
                nextState = .partial
            }
            if receipts[receiptIndex].state != nextState {
                receipts[receiptIndex].state = nextState
                changed = true
            }
        }
        if changed && shouldPersist { _ = persist(receipts) }
    }

    @discardableResult
    private func persist(_ next: [ProjectHibernationReceipt]) -> Bool {
        do {
            try Self.save(next, to: fileURL, fileManager: fileManager)
            receipts = next
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// A receipt is written before mutation. If the app exits after the bridge
    /// moves an artifact but before stdout is parsed, recover the exact Trash
    /// location by its scan-time device/inode/mtime identity.
    private func recoverPendingTrashArtifacts() -> Bool {
        let unresolved = Set(receipts.flatMap(\.artifacts).compactMap { artifact in
            artifact.state == .unavailable && artifact.trashPath.isEmpty
                ? artifact.originalIdentity : nil
        })
        guard !unresolved.isEmpty,
              let candidates = try? fileManager.contentsOfDirectory(
                at: trashDirectoryURL,
                includingPropertiesForKeys: nil,
                options: []) else { return false }

        let referencedPaths = Set(receipts.flatMap(\.artifacts).compactMap {
            $0.trashPath.isEmpty ? nil : $0.trashPath
        })
        var recoveredByIdentity: [String: URL] = [:]
        for candidate in candidates where !referencedPaths.contains(candidate.path) {
            guard let identity = Self.directoryIdentity(candidate.path),
                  unresolved.contains(identity), recoveredByIdentity[identity] == nil else {
                continue
            }
            recoveredByIdentity[identity] = candidate
        }

        var changed = false
        for receiptIndex in receipts.indices {
            for artifactIndex in receipts[receiptIndex].artifacts.indices {
                let artifact = receipts[receiptIndex].artifacts[artifactIndex]
                guard artifact.state == .unavailable, artifact.trashPath.isEmpty,
                      let recovered = recoveredByIdentity[artifact.originalIdentity] else {
                    continue
                }
                receipts[receiptIndex].artifacts[artifactIndex].trashPath = recovered.path
                receipts[receiptIndex].artifacts[artifactIndex].trashIdentity = artifact.originalIdentity
                receipts[receiptIndex].artifacts[artifactIndex].state = .trashed
                recoveredByIdentity.removeValue(forKey: artifact.originalIdentity)
                changed = true
            }
        }
        return changed
    }

    static func load(from fileURL: URL) -> [ProjectHibernationReceipt] {
        loadResult(from: fileURL, fileManager: .default).receipts
    }

    private static func loadResult(from fileURL: URL,
                                   fileManager: FileManager)
        -> (receipts: [ProjectHibernationReceipt], error: String?) {
        guard fileManager.fileExists(atPath: fileURL.path) else { return ([], nil) }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(Payload.self, from: data)
            guard payload.schemaVersion == schemaVersion else {
                return ([], "Hibernation receipts use an unsupported data version.")
            }
            return (payload.receipts, nil)
        } catch {
            return ([], "Could not load hibernation receipts: \(error.localizedDescription)")
        }
    }

    static func save(_ receipts: [ProjectHibernationReceipt],
                     to fileURL: URL,
                     fileManager: FileManager = .default) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory,
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o700)],
                                      ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Payload(schemaVersion: schemaVersion, receipts: receipts))
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                                      ofItemAtPath: fileURL.path)
    }

    private static func pathIdentity(_ path: String) -> String? {
        var metadata = stat()
        guard Darwin.lstat(path, &metadata) == 0 else { return nil }
        return "\(metadata.st_dev):\(metadata.st_ino):\(metadata.st_mtimespec.tv_sec)"
    }

    private static func directoryIdentity(_ path: String) -> String? {
        var metadata = stat()
        guard Darwin.lstat(path, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return nil }
        return "\(metadata.st_dev):\(metadata.st_ino):\(metadata.st_mtimespec.tv_sec)"
    }
}

#if !PROJECT_HIBERNATION_PARSER_TESTS
@MainActor
final class ProjectHibernationService: ObservableObject {
    @Published private(set) var isWorking = false
    @Published private(set) var lastError: String?

    let receiptStore: ProjectHibernationReceiptStore

    init(receiptStore: ProjectHibernationReceiptStore? = nil) {
        self.receiptStore = receiptStore ?? ProjectHibernationReceiptStore()
    }

    @discardableResult
    func hibernate(project: RadarProject,
                   mode: ProjectHibernationMode,
                   fullDiskAccessGranted: Bool,
                   manuallyIncludedWarningPaths: Set<String> = [],
                   maximumProjectActivityAt: Date? = nil,
                   shouldProceed: @MainActor () -> Bool = { true })
        async -> ProjectHibernationReceipt? {
        guard fullDiskAccessGranted else {
            lastError = "Full Disk Access is required for project hibernation."
            return nil
        }
        guard !isWorking else { return nil }
        isWorking = true
        defer { isWorking = false }

        let environment = ["FORGESWEEP_FULL_DISK_AUTHORIZED": "1"]

        do {
            guard shouldProceed() else { return nil }
            guard ProjectHibernation.supportsRecoverableTrash(for: project.rootPath) else {
                throw ProjectHibernationError.unsupportedTrashVolume(project.rootPath)
            }
            let activityInput = ProjectActivity.requestData(for: [project.rootPath])
            let activityResult = await MoleEngine.shared.runBridgeWithStdin(
                "bin/app_project_activity.sh",
                stdinData: activityInput,
                extraEnvironment: environment,
                timeout: 30)
            guard activityResult.succeeded else {
                throw ProjectHibernationError.bridgeFailed(activityResult.diagnosticOutput)
            }
            let statuses = try ProjectActivity.parse(Data(activityResult.output.utf8))
            guard let activity = statuses[project.rootPath], activity.state == .idle else {
                let status = statuses[project.rootPath]
                throw ProjectHibernationError.projectActive(status?.reason ?? "activity unavailable")
            }
            // Activity probing can take long enough for the user to disable the
            // trigger. Revoke authorization before constructing or persisting
            // any mutation plan.
            guard shouldProceed() else { return nil }

            let plan = try ProjectHibernation.makePlan(
                project: project,
                mode: mode,
                runtimeState: activity.state,
                maximumProjectActivityAt: maximumProjectActivityAt,
                manuallyIncludedWarningPaths: manuallyIncludedWarningPaths)
            let pendingReceipt = ProjectHibernation.pendingReceipt(for: plan)
            guard receiptStore.upsert(pendingReceipt) else {
                throw ProjectHibernationError.bridgeFailed(
                    receiptStore.lastError ?? "Could not persist the hibernation receipt.")
            }
            guard shouldProceed() else {
                _ = receiptStore.remove(id: pendingReceipt.id)
                return nil
            }
            let result = await MoleEngine.shared.runBridgeWithStdin(
                "bin/app_project_hibernate.sh",
                stdinData: plan.stdinData,
                extraEnvironment: environment,
                timeout: 900)
            let receipt = try ProjectHibernation.parseHibernateOutput(
                Data(result.output.utf8), plan: plan, receiptID: pendingReceipt.id)
            guard receiptStore.upsert(receipt) else {
                throw ProjectHibernationError.bridgeFailed(
                    receiptStore.lastError ?? "Artifacts reached Trash, but the receipt could not be saved.")
            }
            guard !receipt.recoverableArtifacts.isEmpty else {
                throw ProjectHibernationError.bridgeFailed(result.diagnosticOutput.isEmpty
                    ? "No project artifacts reached Trash."
                    : result.diagnosticOutput)
            }
            lastError = result.succeeded ? nil : result.diagnosticOutput
            return receipt
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func restore(_ receipt: ProjectHibernationReceipt,
                 fullDiskAccessGranted: Bool) async -> ProjectHibernationReceipt? {
        guard fullDiskAccessGranted else {
            lastError = "Full Disk Access is required for project restore."
            return nil
        }
        guard !isWorking else { return nil }
        receiptStore.refreshAvailability()
        guard let currentReceipt = receiptStore.receipts.first(where: { $0.id == receipt.id }),
              !currentReceipt.recoverableArtifacts.isEmpty else {
            lastError = ProjectHibernationError.noEligibleArtifacts.localizedDescription
            return nil
        }

        isWorking = true
        defer { isWorking = false }
        let result = await MoleEngine.shared.runBridgeWithStdin(
            "bin/app_project_restore.sh",
            stdinData: currentReceipt.restoreStdinData,
            extraEnvironment: ["FORGESWEEP_FULL_DISK_AUTHORIZED": "1"],
            timeout: 900)
        guard result.succeeded else {
            lastError = result.diagnosticOutput
            return nil
        }
        do {
            let parsed = try ProjectHibernation.parseRestoreOutput(Data(result.output.utf8))
            guard parsed.failed == 0 else {
                throw ProjectHibernationError.bridgeFailed("Project restore failed closed.")
            }
            let updated = ProjectHibernation.applying(parsed, to: currentReceipt)
            guard receiptStore.upsert(updated) else {
                throw ProjectHibernationError.bridgeFailed(
                    receiptStore.lastError ?? "Project restored, but the receipt could not be saved.")
            }
            lastError = nil
            return updated
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }
}
#endif
