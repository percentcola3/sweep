import Foundation

/// Short-lived display cache. Directory signatures detect some changes, but
/// cannot prove recursive freshness; explicit scans always bypass this cache.
enum CleanupCache {
    // Bump whenever the unified scanner's source set or safety classification
    // changes. In particular, the cleanup page now includes all ordinary
    // top-level Trash entries and the expanded AI safe-cache bridge; restoring
    // an older snapshot would silently hide those candidates.
    private static let version = 16
    private static let maximumAge: TimeInterval = 5 * 60

    private static var cacheURL: URL {
        let directory = NSHomeDirectory().appending("/Library/Application Support/ForgeSweep")
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return URL(fileURLWithPath: directory).appendingPathComponent("cleanup-cache.json")
    }

    private struct Payload: Codable {
        var version: Int
        var createdAt: TimeInterval
        var categories: [Category]
        var signatures: [FileSignature]

        struct Category: Codable {
            var name: String
            var paths: [String]
            var bytes: UInt64
            var pathBytes: [String: UInt64]
            var source: CleanupSource
            var risk: CleanupRisk
            var disposal: CleanupDisposal
            var applyRoute: CleanupApplyRoute
            var activityGuard: CleanupActivityGuard
            var reasonKey: String
        }

        struct FileSignature: Codable {
            var path: String
            var exists: Bool
            var device: UInt64
            var inode: UInt64
            var mtime: Double
            var size: UInt64
        }
    }

    static func save(_ categories: [CleanupCategory], to explicitURL: URL? = nil) {
        let payload = Payload(version: version,
                              createdAt: Date().timeIntervalSince1970,
                              categories: categories.map {
                                  .init(name: $0.name, paths: $0.paths, bytes: $0.bytes,
                                        pathBytes: $0.pathBytes,
                                        source: $0.source, risk: $0.risk,
                                        disposal: $0.disposal, applyRoute: $0.applyRoute,
                                        activityGuard: $0.activityGuard, reasonKey: $0.reasonKey)
                              },
                              signatures: signatures(for: categories))
        if let data = try? JSONEncoder().encode(payload) {
            let targetURL = explicitURL ?? cacheURL
            try? FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: targetURL, options: .atomic)
        }
    }

    static func invalidate() {
        try? FileManager.default.removeItem(at: cacheURL)
    }

    /// 命中缓存时返回类别列表与缓存年龄（秒）；未命中返回 nil。
    static func restore(from explicitURL: URL? = nil,
                        now: Date = Date()) -> (categories: [CleanupCategory], age: TimeInterval)? {
        guard let data = try? Data(contentsOf: explicitURL ?? cacheURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == version else { return nil }
        let age = now.timeIntervalSince1970 - payload.createdAt
        guard age >= 0, age <= maximumAge else { return nil }
        for saved in payload.signatures {
            let current = signature(at: saved.path)
            if current.exists != saved.exists
                || current.device != saved.device
                || current.inode != saved.inode
                || abs(current.mtime - saved.mtime) > 1.0
                || current.size != saved.size {
                return nil
            }
        }
        let categories = payload.categories.map {
            CleanupCategory(name: $0.name, paths: $0.paths, bytes: $0.bytes,
                            pathBytes: $0.pathBytes,
                            source: $0.source, risk: $0.risk,
                            disposal: $0.disposal, applyRoute: $0.applyRoute,
                            activityGuard: $0.activityGuard, reasonKey: $0.reasonKey)
        }
        return (categories, age)
    }

    private static func signatures(for categories: [CleanupCategory]) -> [Payload.FileSignature] {
        var watchPaths: [String] = []
        func appendUnique(_ path: String) {
            guard !path.isEmpty, !watchPaths.contains(path) else { return }
            watchPaths.append(path)
        }
        for category in categories {
            for path in category.paths {
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                let watchPath = (exists && isDirectory.boolValue)
                    ? path
                    : ((path as NSString).deletingLastPathComponent)
                appendUnique(watchPath)
            }
        }
        let home = NSHomeDirectory()
        // Empty snapshots need a cheap signal for newly-created candidates too;
        // when there are no category paths to sign, watching only the whitelist
        // and Trash would keep an empty result alive for a day. These are the
        // roots touched by the unified scanner, not arbitrary user data.
        let sourceRoots = [
            home + "/Library/Caches",
            home + "/Library/Logs",
            home + "/Library/Application Support",
            home + "/Library/Developer",
            home + "/Library/Containers",
            home + "/Library/Developer/Xcode/SourcePackages",
            home + "/.Trash",
            home + "/.cache",
            home + "/.claude/statsig",
            home + "/.npm",
            home + "/.bun/install/cache",
            home + "/.yarn/cache",
            home + "/.m2/repository",
            home + "/.gradle/caches",
            home + "/.cargo/registry/cache",
            home + "/go/pkg/mod",
            home + "/Library/pnpm/store",
            home + "/Library/Caches/Codex",
            home + "/Library/Application Support/Code",
            home + "/Library/Application Support/Cursor",
            home + "/.cache/chrome-devtools-mcp/chrome-profile",
            home + "/.config/mole/whitelist"
        ]
        sourceRoots.forEach(appendUnique)
        // App-leftover results depend on both the trashed bundle evidence and
        // the absence of a live installation. Any install/restore/Trash change
        // must invalidate the whole cleanup snapshot before it can be applied.
        appendUnique("/Applications")
        appendUnique(home + "/Applications")
        return watchPaths.map(signature(at:))
    }

    private static func signature(at path: String) -> Payload.FileSignature {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return .init(path: path, exists: false, device: 0, inode: 0, mtime: 0, size: 0)
        }
        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        return .init(path: path, exists: true, device: device, inode: inode, mtime: mtime, size: size)
    }
}
