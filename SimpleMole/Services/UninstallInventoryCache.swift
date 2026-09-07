import Foundation

/// Persistent uninstall inventory. Stale rows whose app object identity no
/// longer matches are discarded at restore time; a silent refresh follows at
/// launch and filesystem changes trigger another refresh.
enum UninstallInventoryCache {
    // One serial queue keeps older saves from overtaking newer inventories.
    // JSON encoding, disk writes and restore-time identity checks never block UI.
    private static let ioQueue = DispatchQueue(label: "com.forgesweep.uninstall-cache", qos: .utility)
    private static let version = 2
    private static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    private struct Payload: Codable {
        let version: Int
        let createdAt: Date
        let records: [Record]
    }

    private struct Record: Codable {
        let app: UninstallApp
        let plan: UninstallPlan
    }

    static func restoreInBackground() async -> [UninstallInventoryRecord] {
        await withCheckedContinuation { continuation in
            ioQueue.async { continuation.resume(returning: restore()) }
        }
    }

    static func saveInBackground(_ records: [UninstallInventoryRecord]) {
        ioQueue.async { save(records) }
    }

    private static var cacheURL: URL {
        let directory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/ForgeSweep", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        return directory.appendingPathComponent("uninstall-inventory.json")
    }

    static func save(_ records: [UninstallInventoryRecord], to explicitURL: URL? = nil) {
        let payload = Payload(version: version,
                              createdAt: Date(),
                              records: records.map { .init(app: $0.app, plan: $0.plan) })
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let target = explicitURL ?? cacheURL
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: target, options: .atomic)
    }

    static func restore(from explicitURL: URL? = nil,
                        now: Date = Date()) -> [UninstallInventoryRecord] {
        guard let data = try? Data(contentsOf: explicitURL ?? cacheURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == version,
              now.timeIntervalSince(payload.createdAt) >= 0,
              now.timeIntervalSince(payload.createdAt) <= maximumAge else { return [] }

        return payload.records.compactMap { record in
            guard DeletionPlan.identity(at: record.app.path) == record.app.appIdentity,
                  (DeletionPlan.identity(at: record.app.path + "/Contents/Info.plist") ?? "missing")
                    == record.app.infoIdentity else { return nil }
            return .init(app: record.app, plan: record.plan)
        }
    }
}
