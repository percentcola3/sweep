import Combine
import Foundation

enum DockerResourceKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case images
    case containers
    case volumes
    case buildCache = "build-cache"

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .images: return "docker.kind.images"
        case .containers: return "docker.kind.containers"
        case .volumes: return "docker.kind.volumes"
        case .buildCache: return "docker.kind.buildCache"
        }
    }

    var symbolName: String {
        switch self {
        case .images: return "shippingbox.fill"
        case .containers: return "rectangle.3.group.fill"
        case .volumes: return "externaldrive.fill"
        case .buildCache: return "hammer.fill"
        }
    }
}

struct DockerResourceItem: Identifiable, Equatable, Sendable {
    let kind: DockerResourceKind
    let resourceID: String
    let title: String
    let detail: String
    let sizeLabel: String?
    let reclaimableLabel: String?
    let isActive: Bool?
    let rawFields: [String: String]

    /// One image ID can legitimately have several repository:tag rows.
    var id: String {
        kind == .images
            ? "\(kind.rawValue)#\(resourceID)#\(title)"
            : "\(kind.rawValue)#\(resourceID)"
    }
}

enum DockerInventoryPhase: Equatable, Sendable {
    case idle
    case loading
    case ready
    case unavailable
    case partial(String)
    case failed(String)
}

enum DockerInventory {
    struct CommandResult: Sendable {
        let kind: DockerResourceKind
        let succeeded: Bool
        let output: String
        let diagnostic: String
    }

    struct ScanResult: Sendable {
        let items: [DockerResourceItem]
        let phase: DockerInventoryPhase
        let completedKinds: Set<DockerResourceKind>
        let diagnosticsByKind: [DockerResourceKind: String]
    }

    private struct DecodeResult {
        let items: [DockerResourceItem]
        let invalidRowCount: Int
    }

    /// Decode `kind<TAB>{docker format JSON}` records. Docker has changed some
    /// template field names across releases, so values are normalized to a
    /// small string dictionary and read through explicit aliases.
    static func decodeItems(_ output: String) -> [DockerResourceItem] {
        decode(output, expectedKind: nil).items
    }

    /// Consolidate the four fixed read-only commands without hiding failures.
    /// Empty output is a valid empty inventory; non-empty undecodable output is
    /// a protocol failure and must surface as partial/failed.
    static func scanResult(from results: [CommandResult]) -> ScanResult {
        var collected: [DockerResourceItem] = []
        var diagnostics: [String] = []
        var kindDiagnostics: [DockerResourceKind: [String]] = [:]
        var completedKinds: Set<DockerResourceKind> = []

        for result in results {
            guard result.succeeded else {
                let diagnostic = result.diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = diagnostic.isEmpty
                    ? "Docker \(result.kind.rawValue) inventory failed without diagnostics."
                    : diagnostic
                diagnostics.append(message)
                kindDiagnostics[result.kind, default: []].append(message)
                continue
            }

            let decoded = decode(result.output, expectedKind: result.kind)
            collected += decoded.items
            if decoded.invalidRowCount > 0 {
                let message = "Docker \(result.kind.rawValue) inventory returned \(decoded.invalidRowCount) unparseable row(s)."
                diagnostics.append(message)
                kindDiagnostics[result.kind, default: []].append(message)
            } else {
                completedKinds.insert(result.kind)
            }
        }

        let phase: DockerInventoryPhase
        if completedKinds.isEmpty && collected.isEmpty {
            phase = .failed(diagnostics.joined(separator: "\n"))
        } else if completedKinds.count == DockerResourceKind.allCases.count,
                  diagnostics.isEmpty {
            phase = .ready
        } else {
            let diagnostic = diagnostics.isEmpty
                ? "Docker inventory completed only \(completedKinds.count) of \(DockerResourceKind.allCases.count) categories."
                : diagnostics.joined(separator: "\n")
            phase = .partial(diagnostic)
        }
        return ScanResult(
            items: sorted(collected),
            phase: phase,
            completedKinds: completedKinds,
            diagnosticsByKind: kindDiagnostics.mapValues { $0.joined(separator: "\n") })
    }

    private static func decode(_ output: String,
                               expectedKind: DockerResourceKind?) -> DecodeResult {
        var items: [DockerResourceItem] = []
        var invalidRowCount = 0
        for rawLine in output.components(separatedBy: .newlines) {
            guard !rawLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            let parts = rawLine.split(separator: "\t", maxSplits: 1,
                                      omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let kind = DockerResourceKind(rawValue: String(parts[0])),
                  expectedKind == nil || kind == expectedKind,
                  let data = String(parts[1]).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any] else {
                invalidRowCount += 1
                continue
            }

            let fields = dictionary.reduce(into: [String: String]()) { result, entry in
                if let value = normalizedString(entry.value) {
                    result[entry.key] = value
                }
            }
            guard let item = makeItem(kind: kind, fields: fields) else {
                invalidRowCount += 1
                continue
            }
            items.append(item)
        }
        return DecodeResult(items: sorted(items), invalidRowCount: invalidRowCount)
    }

    private static func sorted(_ items: [DockerResourceItem]) -> [DockerResourceItem] {
        items.sorted {
            if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
            let titleOrder = $0.title.localizedStandardCompare($1.title)
            return titleOrder == .orderedSame ? $0.resourceID < $1.resourceID : titleOrder == .orderedAscending
        }
    }

    private static func makeItem(kind: DockerResourceKind,
                                 fields: [String: String]) -> DockerResourceItem? {
        func value(_ names: String...) -> String? {
            for name in names {
                if let match = fields.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame }),
                   !match.value.isEmpty {
                    return match.value
                }
            }
            return nil
        }

        let rawID: String?
        let title: String
        let detailParts: [String?]
        let active: Bool?

        switch kind {
        case .images:
            rawID = value("ID", "Id", "Digest")
            let repository = value("Repository")
            let tag = value("Tag")
            if let repository, repository != "<none>" {
                title = (tag == nil || tag == "<none>") ? repository : "\(repository):\(tag!)"
            } else {
                title = shortIdentifier(rawID) ?? "<none>"
            }
            detailParts = [shortIdentifier(rawID), value("CreatedSince", "CreatedAt")]
            active = integer(value("Containers")).map { $0 > 0 }

        case .containers:
            rawID = value("ID", "Id")
            title = value("Names", "Name") ?? shortIdentifier(rawID) ?? "--"
            detailParts = [value("Image"), value("Status")]
            active = value("State").map { $0.caseInsensitiveCompare("running") == .orderedSame }

        case .volumes:
            rawID = value("Name", "ID", "Id")
            title = value("Name") ?? shortIdentifier(rawID) ?? "--"
            detailParts = [value("Driver"), value("Scope")]
            active = integer(value("Links", "RefCount")).map { $0 > 0 }

        case .buildCache:
            rawID = value("ID", "Id")
            title = value("Description") ?? shortIdentifier(rawID) ?? "--"
            detailParts = [shortIdentifier(rawID), value("CreatedAt", "LastUsedAt")]
            active = boolean(value("InUse", "Shared"))
        }

        guard let resourceID = rawID, !resourceID.isEmpty else { return nil }
        let detail = detailParts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return DockerResourceItem(
            kind: kind,
            resourceID: resourceID,
            title: title,
            detail: detail,
            sizeLabel: value("Size", "Usage", "DiskUsage"),
            reclaimableLabel: value("Reclaimable", "ReclaimableSize"),
            isActive: active,
            rawFields: fields
        )
    }

    private static func normalizedString(_ value: Any) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    private static func shortIdentifier(_ value: String?) -> String? {
        guard var value, !value.isEmpty else { return nil }
        if value.hasPrefix("sha256:") { value.removeFirst("sha256:".count) }
        return String(value.prefix(12))
    }

    private static func boolean(_ value: String?) -> Bool? {
        guard let value else { return nil }
        switch value.lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return nil
        }
    }

    private static func integer(_ value: String?) -> Int? {
        guard let value else { return nil }
        return Int(value)
    }
}

#if !INVENTORY_PARSER_TESTS
@MainActor
final class DockerInventoryStore: ObservableObject {
    @Published private(set) var items: [DockerResourceItem] = []
    @Published private(set) var phase: DockerInventoryPhase = .idle
    @Published private(set) var completedKinds: Set<DockerResourceKind> = []
    @Published private(set) var diagnosticsByKind: [DockerResourceKind: String] = [:]

    func items(for kind: DockerResourceKind) -> [DockerResourceItem] {
        items.filter { $0.kind == kind }
    }

    func scan() {
        guard phase != .loading else { return }
        phase = .loading
        Task {
            var results: [DockerInventory.CommandResult] = []

            // These four bridge modes are read-only and strictly whitelisted.
            // Sequential execution keeps older Docker daemons from receiving a
            // burst of simultaneous inventory requests.
            for kind in DockerResourceKind.allCases {
                let result = await MoleEngine.shared.runBridge(
                    "bin/app_docker_details.sh", arguments: [kind.rawValue], timeout: 120)
                results.append(.init(kind: kind,
                                     succeeded: result.succeeded,
                                     output: result.output,
                                     diagnostic: result.diagnosticOutput))
            }

            let scan = DockerInventory.scanResult(from: results)
            items = scan.items
            phase = scan.phase
            completedKinds = scan.completedKinds
            diagnosticsByKind = scan.diagnosticsByKind
        }
    }
}
#endif
