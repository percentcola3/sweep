import Foundation
import Combine

enum SavedScanLocationAvailability: String, Codable, Sendable {
    case available
    case unavailable
}

/// A user-selected scan root. This is intentionally separate from automatic
/// cleanup rules: saving a location grants read-only discovery, not deletion.
struct SavedScanLocation: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var path: String
    var displayName: String
    var createdAt: Date
    var lastScannedAt: Date?
    var availability: SavedScanLocationAvailability

    init(id: UUID = UUID(),
         path: String,
         displayName: String? = nil,
         createdAt: Date = Date(),
         lastScannedAt: Date? = nil,
         availability: SavedScanLocationAvailability = .unavailable) {
        self.id = id
        self.path = path
        self.displayName = displayName ?? URL(fileURLWithPath: path).lastPathComponent
        self.createdAt = createdAt
        self.lastScannedAt = lastScannedAt
        self.availability = availability
    }
}

enum SavedScanLocationError: LocalizedError, Equatable {
    case relativePath(String)
    case emptyPath
    case duplicate(String)

    var errorDescription: String? {
        switch self {
        case .relativePath(let path): return "Scan location must be absolute: \(path)"
        case .emptyPath: return "Scan location cannot be empty"
        case .duplicate(let path): return "Scan location is already saved: \(path)"
        }
    }
}

@MainActor
final class SavedScanLocationStore: ObservableObject {
    private struct Payload: Codable {
        var schemaVersion: Int
        var locations: [SavedScanLocation]
    }

    static let schemaVersion = 1

    static var defaultFileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/ForgeSweep", isDirectory: true)
            .appendingPathComponent("saved-scan-locations-v1.json", isDirectory: false)
    }

    @Published private(set) var locations: [SavedScanLocation]
    @Published private(set) var lastError: String?

    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL? = nil,
         fileManager: FileManager = .default) {
        let resolvedFileURL = fileURL ?? Self.defaultFileURL
        let loaded = Self.loadResult(from: resolvedFileURL, fileManager: fileManager)
        self.fileURL = resolvedFileURL
        self.fileManager = fileManager
        self.locations = loaded.locations
        self.lastError = loaded.error
    }

    @discardableResult
    func add(path rawPath: String, displayName: String? = nil) throws -> SavedScanLocation {
        let path = try Self.normalizedPath(rawPath)
        guard !locations.contains(where: { $0.path == path }) else {
            throw SavedScanLocationError.duplicate(path)
        }
        let availability = Self.availability(of: path, fileManager: fileManager)
        let location = SavedScanLocation(path: path,
                                         displayName: displayName,
                                         availability: availability)
        var next = locations
        next.append(location)
        next.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        try commit(next)
        return location
    }

    @discardableResult
    func remove(id: UUID) -> Bool {
        let next = locations.filter { $0.id != id }
        guard next != locations else { return true }
        return commitIfPossible(next)
    }

    @discardableResult
    func markScanned(id: UUID, at date: Date = Date()) -> Bool {
        guard let index = locations.firstIndex(where: { $0.id == id }) else { return true }
        var next = locations
        next[index].lastScannedAt = date
        next[index].availability = Self.availability(
            of: next[index].path, fileManager: fileManager)
        return commitIfPossible(next)
    }

    /// Missing paths remain in the store and are surfaced as unavailable.
    @discardableResult
    func refreshAvailability(persist shouldPersist: Bool = true) -> Bool {
        var next = locations
        var changed = false
        for index in next.indices {
            let current = Self.availability(of: next[index].path, fileManager: fileManager)
            if next[index].availability != current {
                next[index].availability = current
                changed = true
            }
        }
        guard changed else { return true }
        if shouldPersist { return commitIfPossible(next) }
        locations = next
        return true
    }

    @discardableResult
    func replaceForTesting(_ replacement: [SavedScanLocation]) -> Bool {
        commitIfPossible(replacement)
    }

    private func commit(_ next: [SavedScanLocation]) throws {
        do {
            try Self.save(next, to: fileURL, fileManager: fileManager)
            locations = next
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    private func commitIfPossible(_ next: [SavedScanLocation]) -> Bool {
        do {
            try commit(next)
            return true
        } catch {
            return false
        }
    }

    static func normalizedPath(_ rawPath: String) throws -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SavedScanLocationError.emptyPath }
        guard (trimmed as NSString).isAbsolutePath else {
            throw SavedScanLocationError.relativePath(trimmed)
        }
        return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.path
    }

    static func availability(of path: String,
                             fileManager: FileManager = .default) -> SavedScanLocationAvailability {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            ? .available
            : .unavailable
    }

    static func load(from fileURL: URL,
                     fileManager: FileManager = .default) -> [SavedScanLocation] {
        loadResult(from: fileURL, fileManager: fileManager).locations
    }

    private static func loadResult(from fileURL: URL,
                                   fileManager: FileManager) -> (locations: [SavedScanLocation],
                                                                 error: String?) {
        guard fileManager.fileExists(atPath: fileURL.path) else { return ([], nil) }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(Payload.self, from: data)
            guard payload.schemaVersion == schemaVersion else {
                return ([], "Saved scan locations use an unsupported data version.")
            }
            let locations = payload.locations.map { location in
                var loaded = location
                // Loading preferences must not probe user-selected folders.
                // Availability is refreshed only after the caller confirms
                // Full Disk Access for the current process.
                loaded.availability = .unavailable
                return loaded
            }
            return (locations, nil)
        } catch {
            return ([], "Could not load saved scan locations: \(error.localizedDescription)")
        }
    }

    static func save(_ locations: [SavedScanLocation],
                     to fileURL: URL,
                     fileManager: FileManager = .default) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory,
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o700)],
                                      ofItemAtPath: directory.path)
        let payload = Payload(schemaVersion: schemaVersion, locations: locations)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                                      ofItemAtPath: fileURL.path)
    }
}
