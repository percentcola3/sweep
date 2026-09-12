import AppKit
import Darwin
import Foundation
import OSLog

/// Thread-safe sink used by the native scanner to publish lightweight progress
/// without coupling the filesystem worker to the UI actor.
struct CleanupScanProgressEvent: Sendable {
    let phase: String
    let completed: Int
    let total: Int
    let currentPath: String
}

final class CleanupScanProgressSink: @unchecked Sendable {
    private let lock = NSLock()
    private let handler: (CleanupScanProgressEvent) -> Void
    private var lastSentAt = Date.distantPast

    init(handler: @escaping (CleanupScanProgressEvent) -> Void) {
        self.handler = handler
    }

    func send(_ event: CleanupScanProgressEvent) {
        // Directory roots can contain thousands of children. Coalesce updates
        // here, before creating a MainActor task, while always forwarding the
        // final item so the bar can reach its terminal state.
        let now = Date()
        lock.lock()
        let shouldSend = (event.total > 0 && event.completed == event.total)
            || now.timeIntervalSince(lastSentAt) >= 0.08
        if shouldSend { lastSentAt = now }
        lock.unlock()
        guard shouldSend else { return }
        handler(event)
    }
}

/// 原生核心服务。
///
/// 五条核心流程不通过外部命令路由转发。清理、卸载和磁盘分析只使用系统
/// API；优化任务只调用明确列出的系统命令。特色能力
/// （图片、Docker、Simulator、AI 等）仍由各自的 bridge 负责。
final class NativeCore: @unchecked Sendable {
    static let shared = NativeCore()

    struct CleanupScan: Sendable {
        let categories: [CleanupCategory]
        let succeeded: Bool
        let error: String?
        var deferredPaths: [String] = []
        var diagnostics: String = ""
    }

    struct ApplySummary: Sendable {
        let removed: Int
        let skipped: Int
        let failed: Int
        let messages: [String]
        var removedPaths: Set<String> = []

        var succeeded: Bool { failed == 0 }
    }

    struct OptimizeTask: Identifiable, Equatable, Sendable {
        enum State: String, Sendable {
            case pending
            case applied
            case unchanged
            case unavailable
            case failed
        }

        let id: String
        let title: String
        let detail: String
        var state: State = .pending
        var message: String = ""
    }

    struct OptimizeReport: Sendable {
        let tasks: [OptimizeTask]
        let finishedAt: Date
    }

    private static let cleanupLogger = Logger(subsystem: "com.forgesweep.app", category: "cleanup")
    private let fileManager = FileManager.default
    private let sizeKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
        .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .fileSizeKey
    ]
    private let maxTraversalEntries = 200_000
    private let maxTraversalSeconds: TimeInterval = 3
    private let largeFileThreshold: UInt64 = 100 * 1024 * 1024

    private struct FileIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    private struct TreeMeasure {
        var bytes: UInt64 = 0
        var files: Int = 0
        var largeFiles: [AnalyzeReport.LargeFile] = []
        var truncated = false
    }

    private init() {}

    // MARK: Cleanup

    func scanCleanup(homeDirectory: String = NSHomeDirectory(),
                     progress: CleanupScanProgressSink? = nil,
                     mode: CleanupScanMode = .quick,
                     control: CleanupScanControl? = nil) async -> CleanupScan {
        let control = control ?? CleanupScanControl(mode: mode)
        return await Task.detached(priority: .utility) { [self] in
            let home = URL(fileURLWithPath: homeDirectory, isDirectory: true)
                .standardizedFileURL
            guard self.fileManager.fileExists(atPath: home.path) else {
                return CleanupScan(categories: [], succeeded: false,
                                   error: "Home directory is unavailable.")
            }

            let roots = self.cleanupRoots(home: home, mode: mode, control: control)
            let orphanNames = self.cleanupOrphanNames(home: home, control: control)
            let whitelist = self.loadWhitelist(homeDirectory: homeDirectory)
            let broadRoots = Set(["Library/Caches", "Library/Logs", "Library/DiagnosticReports",
                                  ".cache", ".Trash"].map { home.appendingPathComponent($0).path })
            var candidates: [CleanupScanCandidate] = []
            var seen = Set<String>()
            for (root, label, _, _) in roots {
                guard !control.shouldStop else { break }
                guard self.cleanupPathIsPhysical(root, home: home) else { continue }
                let entries = broadRoots.contains(root.path) ? self.directChildren(of: root) : [root]
                for entry in entries {
                    let path = entry.standardizedFileURL.path
                    guard self.isAllowedCleanupPath(entry, home: home),
                          self.cleanupPathIsPhysical(entry, home: home),
                          !whitelist.contains(where: {
                              path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/")
                          }) else { continue }
                    // A precise leaf replaces an overlapping broad parent before
                    // traversal. Never size or offer that parent for deletion.
                    if broadRoots.contains(root.path), roots.contains(where: {
                        $0.0 != root && (path == $0.0.path || $0.0.path.hasPrefix(path + "/"))
                    }) { continue }
                    let descriptor: CleanupPolicyDescriptor
                    let name: String
                    if let orphan = orphanNames[path] {
                        descriptor = CleanupRiskPolicy.appLeftover(
                            path: path, bundleIdentifier: orphan.bundleID, homeDirectory: homeDirectory)
                        name = orphan.name + " leftovers"
                    } else {
                        let base = CleanupRiskPolicy.core(section: label, path: path,
                                                          homeDirectory: homeDirectory)
                        descriptor = entry.deletingLastPathComponent().path == home.path + "/.Trash"
                            && base.risk != .protected ? CleanupRiskPolicy.recommendedTrash() : base
                        if broadRoots.contains(root.path), root.lastPathComponent != ".Trash" {
                            let identifier = entry.lastPathComponent
                            let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
                            name = app?.deletingPathExtension().lastPathComponent ?? identifier
                        } else {
                            let supportPrefix = home.path + "/Library/Application Support/"
                            let cachePrefix = home.path + "/Library/Caches/"
                            if path.hasPrefix(supportPrefix) {
                                name = String(path.dropFirst(supportPrefix.count).split(separator: "/").first ?? "")
                            } else if path.hasPrefix(cachePrefix) {
                                name = String(path.dropFirst(cachePrefix.count).split(separator: "/").first ?? "")
                            } else {
                                name = label
                            }
                        }
                    }
                    // Classify first: sessions, models and unverified roots do
                    // not consume the quick scan's I/O budget.
                    guard descriptor.risk == .safe, seen.insert(path).inserted else { continue }
                    candidates.append(CleanupScanCandidate(path: path, name: name, policy: descriptor))
                }
            }
            candidates = Self.nonOverlappingCleanupCandidates(candidates)
            let discoverySeconds = control.elapsed
            let measurements = CleanupScanWorker.measure(candidates.map(\.path), control: control) {
                completed, path in
                progress?.send(CleanupScanProgressEvent(phase: "native", completed: completed,
                    total: candidates.count, currentPath: path))
            }
            var deferred: [String] = []
            var groups: [String: [Int]] = [:]
            for index in candidates.indices {
                guard measurements[index].complete else {
                    deferred.append(candidates[index].path)
                    continue
                }
                guard measurements[index].bytes > 0, measurements[index].files > 0 else { continue }
                let candidate = candidates[index]
                let policy = candidate.policy
                let key = [candidate.name, policy.source.rawValue, policy.applyRoute.rawValue,
                           policy.activityGuard.rawValue].joined(separator: "\t")
                groups[key, default: []].append(index)
            }
            let categories = groups.values.map { indices -> CleanupCategory in
                let first = candidates[indices[0]]
                let sizes = Dictionary(uniqueKeysWithValues: indices.map {
                    (candidates[$0].path, measurements[$0].bytes)
                })
                return CleanupCategory(name: first.name, paths: indices.map { candidates[$0].path },
                    bytes: sizes.values.reduce(0, &+), pathBytes: sizes, selected: true,
                    source: first.policy.source, risk: first.policy.risk,
                    disposal: first.policy.disposal, applyRoute: first.policy.applyRoute,
                    activityGuard: first.policy.activityGuard, reasonKey: first.policy.reasonKey)
            }
            // Discovery itself may exhaust the deadline. Do not cache such a
            // snapshot as complete, even if every admitted candidate was sized.
            if discoverySeconds >= control.totalBudget { deferred.append(home.path) }
            return CleanupScan(categories: categories.sorted(by: CleanupCategory.sizeDescending),
                succeeded: !control.isCancelled,
                error: control.isCancelled ? "Scan cancelled." : nil,
                deferredPaths: deferred,
                diagnostics: String(format: "cleanup[%@] discovery=%.2fs sizing=%.2fs paths=%d deferred=%d files=%d",
                    mode.rawValue, discoverySeconds, control.elapsed - discoverySeconds,
                    candidates.count, deferred.count, measurements.reduce(0) { $0 + $1.files }))
        }.value
    }

    struct CleanupScanCandidate {
        let path: String
        let name: String
        let policy: CleanupPolicyDescriptor
    }

    static func nonOverlappingCleanupCandidates(_ input: [CleanupScanCandidate]) -> [CleanupScanCandidate] {
        // Prefer narrow paths. An ancestor is never retained with an excluded
        // descendant, because the apply step deletes the entire selected path.
        let paths = Set(input.map(\.path))
        var ancestors = Set<String>()
        for path in paths {
            var parent = (path as NSString).deletingLastPathComponent
            while parent != "/" && !parent.isEmpty {
                if paths.contains(parent) { ancestors.insert(parent) }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        var seen = Set<String>()
        return input.filter { !ancestors.contains($0.path) && seen.insert($0.path).inserted }
            .sorted { $0.path < $1.path }
    }

    private func cleanupPathIsPhysical(_ url: URL, home: URL) -> Bool {
        guard url.path.hasPrefix(home.path + "/") else { return false }
        var probe = url
        while probe.path != home.path {
            if isSymlink(probe) { return false }
            probe.deleteLastPathComponent()
        }
        return fileManager.fileExists(atPath: url.path)
    }

    /// Find cache/log leftovers for applications that are present in Trash.
    /// The trashed bundle is the ownership proof; directory names alone are
    /// never treated as evidence. Only rebuildable cache and log leaves are
    /// offered to the clean flow, while app data remains available through the
    /// uninstall/analyze review surfaces.
    private func cleanupOrphanNames(home: URL, control: CleanupScanControl)
        -> [String: (name: String, bundleID: String)] {
            let trash = home.appendingPathComponent(".Trash", isDirectory: true)
            guard cleanupPathIsPhysical(trash, home: home) else { return [:] }
            let trashedApps = self.directChildren(of: trash)
                .filter { $0.pathExtension.lowercased() == "app" && !self.isSymlink($0) }
            // Avoid preparing the installed-app inventory when there is no
            // trashed bundle to correlate. Sizing uses the main queue once.
            guard !trashedApps.isEmpty, !control.shouldStop else { return [:] }

            var installedBundleIDs = Set<String>()
            for (root, _) in self.applicationRoots(home: home) {
                guard !control.shouldStop else { return [:] }
                for item in self.directChildren(of: root)
                    where item.pathExtension.lowercased() == "app" && !self.isSymlink(item) {
                    guard !control.shouldStop else { return [:] }
                    if let bundleID = self.applicationMetadata(at: item)?.bundleID {
                        installedBundleIDs.insert(bundleID)
                    }
                }
            }

            var names: [String: (name: String, bundleID: String)] = [:]
            for item in trashedApps {
                guard !control.shouldStop else { return names }
                guard let metadata = self.applicationMetadata(at: item),
                      !metadata.bundleID.isEmpty,
                      !installedBundleIDs.contains(metadata.bundleID) else { continue }

                let candidates = [
                    home.appendingPathComponent("Library/Caches/\(metadata.bundleID)", isDirectory: true),
                    home.appendingPathComponent("Library/Logs/\(metadata.bundleID)", isDirectory: true)
                ]
                for candidate in candidates {
                    let path = candidate.standardizedFileURL.path
                    names[path] = (metadata.name, metadata.bundleID)
                }
            }
            return names
    }

    /// The native cleanup inventory deliberately contains only rebuildable
    /// leaves.  App data, project sources and system-owned paths are handled by
    /// their dedicated feature or shown as review-only items.  Keeping this
    /// list in Swift makes the core route independent from the vendored Mole
    /// shell catalog while retaining the same conservative path model.
    private func cleanupRoots(home: URL, mode: CleanupScanMode, control: CleanupScanControl)
        -> [(URL, String, CleanupSource, CleanupActivityGuard)] {
        var roots: [(URL, String, CleanupSource, CleanupActivityGuard)] = []
        var seen = Set<String>()

        func add(_ url: URL, _ label: String, _ source: CleanupSource,
                 _ guardKind: CleanupActivityGuard) {
            let path = url.standardizedFileURL.path
            guard !control.shouldStop, self.cleanupPathIsPhysical(url, home: home),
                  seen.insert(path).inserted else { return }
            roots.append((url, label, source, guardKind))
        }

        // Reuse the audited AI list instead of invoking a second du-based
        // scanner. Classification and apply routes remain policy-owned.
        for path in CleanupRiskPolicy.aiCacheRoots(homeDirectory: home.path) {
            let url = URL(fileURLWithPath: path)
            add(url, url.deletingLastPathComponent().lastPathComponent + " · " + url.lastPathComponent,
                .aiCache, .ide)
        }

        add(home.appendingPathComponent("Library/Caches", isDirectory: true),
            "User Caches", .core, .openFile)
        add(home.appendingPathComponent("Library/Logs", isDirectory: true),
            "User Logs", .core, .openFile)
        add(home.appendingPathComponent("Library/DiagnosticReports", isDirectory: true),
            "Diagnostic Reports", .core, .openFile)
        add(home.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true),
            "Xcode DerivedData", .xcodeCache, .xcode)
        add(home.appendingPathComponent("Library/Developer/Xcode/SourcePackages", isDirectory: true),
            "Xcode SourcePackages", .xcodeCache, .xcode)
        add(home.appendingPathComponent("Library/Caches/com.apple.dt.Xcode", isDirectory: true),
            "Xcode Cache", .xcodeCache, .xcode)
        add(home.appendingPathComponent("Library/Developer/CoreSimulator/Caches", isDirectory: true),
            "Simulator Caches", .developerCache, .simulator)
        add(home.appendingPathComponent(".cache", isDirectory: true),
            "User Cache", .core, .openFile)
        add(home.appendingPathComponent(".npm/_cacache", isDirectory: true),
            "npm Cache", .developerCache, .packageManager)
        add(home.appendingPathComponent(".yarn/cache", isDirectory: true),
            "Yarn Cache", .developerCache, .packageManager)
        add(home.appendingPathComponent(".bun/install/cache", isDirectory: true),
            "Bun Cache", .developerCache, .packageManager)
        add(home.appendingPathComponent(".gradle/caches", isDirectory: true),
            "Gradle Cache", .developerCache, .packageManager)
        add(home.appendingPathComponent(".m2/repository", isDirectory: true),
            "Maven Cache", .developerCache, .packageManager)
        add(home.appendingPathComponent(".cargo/registry/cache", isDirectory: true),
            "Cargo Cache", .developerCache, .packageManager)
        add(home.appendingPathComponent(".swiftpm/cache", isDirectory: true),
            "Swift Package Cache", .developerCache, .packageManager)
        add(home.appendingPathComponent(".cache/pip", isDirectory: true),
            "pip Cache", .developerCache, .packageManager)
        add(home.appendingPathComponent(".cache/uv", isDirectory: true),
            "uv Cache", .developerCache, .packageManager)
        add(home.appendingPathComponent(".cache/node/corepack", isDirectory: true),
            "Corepack Cache", .developerCache, .packageManager)
        add(home.appendingPathComponent("Library/Caches/Homebrew/downloads", isDirectory: true),
            "Homebrew Cache", .developerCache, .packageManager)
        add(home.appendingPathComponent("Library/Caches/org.carthage.CarthageKit", isDirectory: true),
            "Carthage Cache", .developerCache, .packageManager)
        add(home.appendingPathComponent("go/pkg/mod/cache", isDirectory: true),
            "Go Module Cache", .developerCache, .packageManager)
        add(home.appendingPathComponent(".Trash", isDirectory: true),
            "Trash", .core, .openFile)

        // Additional fixed developer cache locations. These are all
        // rebuildable package/build caches; project sources and installed
        // runtimes are intentionally not included in the quick inventory.
        let developerCaches: [(String, String)] = [
            ("Library/Caches/pnpm", "pnpm Cache"),
            ("Library/Caches/Yarn", "Yarn Cache"),
            ("Library/Caches/go-build", "Go Build Cache"),
            ("Library/Caches/pip", "pip Cache"),
            ("Library/Caches/pypoetry", "Poetry Cache"),
            ("Library/Caches/NuGet", "NuGet Cache"),
            ("Library/Caches/composer", "Composer Cache"),
            ("Library/Caches/node-gyp", "node-gyp Cache"),
            ("Library/Caches/typescript", "TypeScript Cache"),
            ("Library/Caches/org.swift.swiftpm", "SwiftPM Cache"),
            (".node-gyp", "node-gyp Cache"),
            (".cache/bazel", "Bazel Cache"),
            (".cache/zig", "Zig Cache"),
            (".cache/electron", "Electron Cache"),
            (".cache/node-gyp", "node-gyp Cache"),
            (".turbo/cache", "Turborepo Cache"),
            (".vite/cache", "Vite Cache"),
            (".cache/vite", "Vite Cache"),
            (".cache/webpack", "Webpack Cache"),
            (".parcel-cache", "Parcel Cache"),
            (".cache/eslint", "ESLint Cache"),
            (".cache/prettier", "Prettier Cache"),
            (".cache/swift-package-manager", "SwiftPM Cache")
        ]
        for (relative, label) in developerCaches {
            add(home.appendingPathComponent(relative, isDirectory: true),
                label, .developerCache, .packageManager)
        }

        // 缓存地图：大体积、可重建的应用级缓存。发现层只负责枚举形状
        // （浏览器各 profile、Telegram 各账号、飞书各用户），风险与守卫
        // 由 CleanupRiskPolicy 的知识库裁决；禁区路径不会出现在这里。
        let appSupport = home.appendingPathComponent("Library/Application Support",
                                                     isDirectory: true)
        let browserProfileParents: [(String, String)] = [
            ("Google/Chrome", "Chrome Service Worker"),
            ("Microsoft Edge", "Edge Service Worker"),
            ("BraveSoftware/Brave-Browser", "Brave Service Worker"),
            ("Arc/User Data", "Arc Service Worker")
        ]
        for (relative, label) in browserProfileParents {
            let parentURL = appSupport.appendingPathComponent(relative, isDirectory: true)
            guard !control.shouldStop, cleanupPathIsPhysical(parentURL, home: home) else { continue }
            for profile in directChildren(of: parentURL)
                where !isSymlink(profile) && isDirectory(profile) {
                add(profile.appendingPathComponent("Service Worker", isDirectory: true),
                    label, .core, .browser)
            }
        }
        // 自动化调试的独立 user-data-dir，整个目录可再生。
        add(appSupport.appendingPathComponent("Google/ChromeDebug", isDirectory: true),
            "ChromeDebug Profile", .core, .browser)
        // Telegram 媒体缓存：每个账号一条（老的账号往往最大）；postbox/db
        // 是消息数据库，由策略知识库保护，不会进入发现层。
        let telegramRoot = home.appendingPathComponent(
            "Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram", isDirectory: true)
        if cleanupPathIsPhysical(telegramRoot, home: home) {
            for account in directChildren(of: telegramRoot)
                where account.lastPathComponent.hasPrefix("account-") && !isSymlink(account) {
                add(account.appendingPathComponent("postbox/media", isDirectory: true),
                    "Telegram Media Cache", .core, .messenger)
            }
        }
        // 飞书文档预览缓存：多账号各自堆积，只认 profile_explorer。
        let larkUsers = appSupport.appendingPathComponent("LarkShell/aha/users",
                                                          isDirectory: true)
        if cleanupPathIsPhysical(larkUsers, home: home) {
            for user in directChildren(of: larkUsers) where !isSymlink(user) {
                add(user.appendingPathComponent("profile_explorer", isDirectory: true),
                    "Lark Doc Cache", .core, .messenger)
            }
        }

        // Common IM clients keep disposable thumbnails and web caches in
        // sandbox containers rather than ~/Library/Caches.
        let imContainerCaches: [(String, String)] = [
            ("com.tencent.xinWeChat", "WeChat Cache"),
            ("com.tencent.qq", "QQ Cache"),
            ("com.tencent.meeting", "Tencent Meeting Cache"),
            ("com.alibaba.DingTalkMac", "DingTalk Cache"),
            ("com.bytedance.feishu", "Feishu Cache"),
            ("com.bytedance.lark", "Lark Cache"),
            ("net.whatsapp.WhatsApp", "WhatsApp Cache"),
            ("org.telegram.desktop", "Telegram Cache"),
            ("org.signal.Signal", "Signal Cache"),
            ("com.microsoft.teams2", "Microsoft Teams Cache"),
            ("com.skype.skype", "Skype Cache")
        ]
        for (identifier, label) in imContainerCaches {
            add(home.appendingPathComponent(
                "Library/Containers/\(identifier)/Data/Library/Caches", isDirectory: true),
                label, .core, .browser)
        }
        let imSupportCaches: [(String, String)] = [
            ("WeChat", "WeChat Cache"), ("Tencent/QQ", "QQ Cache"),
            ("Tencent/Meeting", "Tencent Meeting Cache"),
            ("DingTalk", "DingTalk Cache"), ("Feishu", "Feishu Cache"),
            ("Lark", "Lark Cache"), ("WhatsApp", "WhatsApp Cache"),
            ("Telegram Desktop", "Telegram Cache"), ("Signal", "Signal Cache"),
            ("Microsoft Teams", "Microsoft Teams Cache"),
            ("Microsoft Teams 2", "Microsoft Teams Cache"),
            ("Skype", "Skype Cache"), ("Zoom.us", "Zoom Cache"),
            ("Messenger", "Messenger Cache"), ("Rocket.Chat", "Rocket.Chat Cache"),
            ("Mattermost", "Mattermost Cache")
        ]
        for (relative, label) in imSupportCaches {
            add(home.appendingPathComponent("Library/Application Support/\(relative)/Cache",
                                           isDirectory: true), label, .core, .browser)
        }
        add(home.appendingPathComponent(
            "Library/Containers/com.apple.Safari/Data/Library/Caches", isDirectory: true),
            "Safari Cache", .core, .browser)

        // Chromium-family profiles all use the same rebuildable cache leaves.
        // Discover profiles instead of assuming that only Default exists.
        let browsers: [(String, String)] = [
            ("Google/Chrome", "Chrome"),
            ("Google/Chrome Beta", "Chrome Beta"),
            ("Google/Chrome Canary", "Chrome Canary"),
            ("Chromium", "Chromium"),
            ("Microsoft Edge", "Edge"),
            ("BraveSoftware/Brave-Browser", "Brave"),
            ("Arc/User Data", "Arc"),
            ("Vivaldi", "Vivaldi"),
            ("com.operasoftware.Opera", "Opera"),
            ("Firefox/Profiles", "Firefox")
        ]
        let cacheLeaves = ["Cache", "Code Cache", "GPUCache", "GrShaderCache",
                           "GraphiteDawn", "Service Worker/CacheStorage",
                           "Service Worker/ScriptCache", "cache2", "startupCache"]
        for (relative, label) in browsers {
            let browserRoot = home.appendingPathComponent("Library/Application Support/\(relative)",
                                                         isDirectory: true)
            guard !control.shouldStop, cleanupPathIsPhysical(browserRoot, home: home) else { continue }
            for profile in [browserRoot] + directChildren(of: browserRoot)
                where isDirectory(profile) && cleanupPathIsPhysical(profile, home: home) {
                for leaf in cacheLeaves {
                    add(profile.appendingPathComponent(leaf, isDirectory: true),
                        "\(label) \(leaf)",
                        .core, .browser)
                }
            }
        }

        // Electron and IDE applications put rebuildable caches below
        // Application Support rather than Library/Caches.
        let appCacheRoots: [(String, String)] = [
            ("Slack/Cache", "Slack Cache"), ("Slack/Code Cache", "Slack Code Cache"),
            ("Slack/GPUCache", "Slack GPU Cache"),
            ("discord/Cache", "Discord Cache"), ("discord/Code Cache", "Discord Code Cache"),
            ("discord/GPUCache", "Discord GPU Cache"),
            ("WhatsApp/Cache", "WhatsApp Cache"), ("WhatsApp/Code Cache", "WhatsApp Code Cache"),
            ("WhatsApp/GPUCache", "WhatsApp GPU Cache"),
            ("Telegram Desktop/cache", "Telegram Cache"),
            ("Telegram Desktop/Cache", "Telegram Cache"),
            ("Signal/Cache", "Signal Cache"), ("Signal/Code Cache", "Signal Code Cache"),
            ("Microsoft Teams/Cache", "Microsoft Teams Cache"),
            ("Microsoft Teams/Code Cache", "Microsoft Teams Code Cache"),
            ("Microsoft Teams/GPUCache", "Microsoft Teams GPU Cache"),
            ("Microsoft Teams 2/Cache", "Microsoft Teams Cache"),
            ("Skype/Cache", "Skype Cache"), ("Zoom.us/Cache", "Zoom Cache"),
            ("Messenger/Cache", "Messenger Cache"),
            ("Code/Cache", "VS Code Cache"), ("Code/CachedData", "VS Code Cached Data"),
            ("Code/GPUCache", "VS Code GPU Cache"), ("Zed/Cache", "Zed Cache"),
            ("Feishu/Cache", "Feishu Cache"), ("Lark/Cache", "Lark Cache")
        ]
        for (relative, label) in appCacheRoots {
            add(home.appendingPathComponent("Library/Application Support/\(relative)",
                                           isDirectory: true), label, .core, .browser)
        }

        // Broader app discovery is opt-in. Only cache/log leaves become jobs.
        if mode == .deep {
            let containers = home.appendingPathComponent("Library/Containers", isDirectory: true)
            if cleanupPathIsPhysical(containers, home: home) {
                for container in directChildren(of: containers) {
                    guard !control.shouldStop else { break }
                    for leaf in ["Caches", "Logs"] {
                        let root = container.appendingPathComponent("Data/Library/" + leaf)
                        guard cleanupPathIsPhysical(root, home: home) else { continue }
                        for child in directChildren(of: root) {
                            add(child, container.lastPathComponent + " " + leaf, .core, .openFile)
                        }
                    }
                }
            }
            let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
            if cleanupPathIsPhysical(support, home: home) {
                for app in directChildren(of: support) {
                    guard !control.shouldStop, cleanupPathIsPhysical(app, home: home) else { continue }
                    // Inspect only known cache leaf names. No recursive search
                    // through conversations, models or arbitrary user files.
                    for leaf in cacheLeaves + ["Caches", "CachedData", "CachedExtensionVSIXs",
                                                "ShaderCache", "logs", "Crashpad/completed"] {
                        add(app.appendingPathComponent(leaf), app.lastPathComponent + " " + leaf,
                            .core, .openFile)
                    }
                }
            }
        }

        return roots
    }

    /// Apply a previously confirmed deletion plan. Each item carries the
    /// identity captured at confirmation time; a changed identity is skipped.
    func applyCleanup(items: [DeletionPlan.Item], permanent: Bool,
                      homeDirectory: String = NSHomeDirectory(),
                      allowedRoots: [String] = [],
                      allowApplicationBundle: Bool = false) -> ApplySummary {
        let home = URL(fileURLWithPath: homeDirectory).standardizedFileURL.path
        let whitelist = loadWhitelist(homeDirectory: homeDirectory)
        let normalizedRoots = allowedRoots.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        var removed = 0
        var skipped = 0
        var failed = 0
        var messages: [String] = []
        let probeStart = Date()
        var removedPaths = Set<String>()
        Self.cleanupLogger.notice("Open-file safety check started")
        let openFiles = openFileSnapshot()
        let probeSeconds = Date().timeIntervalSince(probeStart)
        Self.cleanupLogger.notice("Open-file safety check finished in \(probeSeconds, privacy: .public)s; available=\(openFiles != nil, privacy: .public)")
        messages.append(String(format: "Open-file check %.2fs; available=%@", probeSeconds, openFiles == nil ? "no" : "yes"))

        let nonOverlapping = DeletionPlan.nonOverlappingPaths(items.map(\.record))
        let itemByRecord = Dictionary(items.map { ($0.record, $0) },
                                      uniquingKeysWith: { first, _ in first })
        for rawPath in nonOverlapping {
            let expectedIdentity = itemByRecord[rawPath]?.identity ?? ""
            let url = URL(fileURLWithPath: rawPath).standardizedFileURL
            let path = url.path
            let isHomePath = path.hasPrefix(home + "/")
            let isAllowedRoot = normalizedRoots.contains { path == $0 || path.hasPrefix($0 + "/") }
            guard isHomePath || isAllowedRoot else {
                skipped += 1
                messages.append("Skipped outside authorized roots: \(path)")
                continue
            }
            guard fileManager.fileExists(atPath: path), !isSymlink(url),
                  !isProtectedCleanupItem(url, allowApplicationBundle: allowApplicationBundle),
                  !matchesWhitelist(path, entries: whitelist) else {
                skipped += 1
                continue
            }
            guard !expectedIdentity.isEmpty,
                  let identity = DeletionPlan.identity(at: path),
                  identity == expectedIdentity else {
                skipped += 1
                messages.append("Skipped changed or unavailable path: \(path)")
                continue
            }
            guard !isOwnedByRunningApplication(path: path) else {
                skipped += 1
                messages.append("Skipped while owning application is running: \(path)")
                continue
            }
            guard let openFiles else {
                skipped += 1
                messages.append("Skipped because open-file state was unavailable: \(path)")
                continue
            }
            guard !openFiles.contains(where: { $0 == path || $0.hasPrefix(path + "/") }) else {
                skipped += 1
                messages.append("Skipped while the path is open: \(path)")
                continue
            }

            do {
                if permanent {
                    try fileManager.removeItem(at: url)
                } else {
                    var resultingURL: NSURL?
                    try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
                }
                removed += 1
                removedPaths.insert(rawPath)
            } catch {
                failed += 1
                messages.append("Failed to remove \(path): \(error.localizedDescription)")
            }
        }
        return ApplySummary(removed: removed, skipped: skipped,
                            failed: failed, messages: messages, removedPaths: removedPaths)
    }

    // MARK: Analyze

    func scanAnalyze(path: String, overview: Bool) async -> AnalyzeReport {
        await Task.detached(priority: .utility) { [self] in
            let target = URL(fileURLWithPath: path).standardizedFileURL
            if overview {
                return self.scanOverview(home: target.path == "/" ? NSHomeDirectory() : target.path)
            }
            return self.scanDirectory(target)
        }.value
    }

    // MARK: Uninstall

    func scanInstalledApps(homeDirectory: String = NSHomeDirectory()) async -> [UninstallApp] {
        await Task.detached(priority: .utility) { [self] in
            let home = URL(fileURLWithPath: homeDirectory, isDirectory: true).standardizedFileURL
            let roots = self.applicationRoots(home: home)
            var apps: [UninstallApp] = []
            var seen = Set<String>()
            for (root, source) in roots {
                for item in self.directChildren(of: root) {
                    guard item.pathExtension.lowercased() == "app",
                          !self.isSymlink(item),
                          let metadata = self.applicationMetadata(at: item),
                          !metadata.bundleID.isEmpty,
                          metadata.bundleID != Bundle.main.bundleIdentifier,
                          !metadata.bundleID.hasPrefix("com.apple."),
                          !seen.contains(item.path) else { continue }
                    seen.insert(item.path)
                    let bytes = self.directorySize(item)
                    apps.append(UninstallApp(
                        name: metadata.name,
                        bundleID: metadata.bundleID,
                        source: source,
                        path: item.path,
                        size: ByteFormat.format(bytes)))
                }
            }
            return apps.sorted {
                let lhs = ByteFormat.parse($0.size)
                let rhs = ByteFormat.parse($1.size)
                if lhs != rhs { return lhs > rhs }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }.value
    }

    /// Enumerate application locations without relying on the Mole inventory
    /// script.  External volumes are included only when macOS reports them as
    /// mounted; hidden volumes and the current app bundle are never traversed.
    private func applicationRoots(home: URL) -> [(URL, String)] {
        var roots: [(URL, String)] = [
            (URL(fileURLWithPath: "/Applications", isDirectory: true), "Applications"),
            (URL(fileURLWithPath: "/System/Applications", isDirectory: true), "System Applications"),
            (home.appendingPathComponent("Applications", isDirectory: true), "User Applications"),
            (home.appendingPathComponent("Library/Application Support/Setapp/Applications",
                                         isDirectory: true), "Setapp"),
            (home.appendingPathComponent("Library/Application Support/Steam/steamapps/common",
                                         isDirectory: true), "Steam")
        ]
        // Package-installed app bundles are occasionally placed outside the
        // normal Applications folders. Include these roots when present; the
        // bundle and Info.plist identities are still required before display
        // or removal.
        for (path, label) in [("/usr/local", "Package install"), ("/opt", "Package install")] {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if fileManager.fileExists(atPath: url.path) {
                roots.append((url, label))
            }
        }
        var seen = Set(roots.map { $0.0.standardizedFileURL.path })
        if let volumes = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                        options: [.skipHiddenVolumes]) {
            for volume in volumes {
                let applications = volume.appendingPathComponent("Applications", isDirectory: true)
                let path = applications.standardizedFileURL.path
                guard seen.insert(path).inserted,
                      fileManager.fileExists(atPath: path) else { continue }
                roots.append((applications, "External Applications"))
            }
        }
        return roots
    }

    func uninstallPlan(for app: UninstallApp,
                       homeDirectory: String = NSHomeDirectory()) async -> UninstallPlan? {
        await Task.detached(priority: .utility) { [self] in
            let appURL = URL(fileURLWithPath: app.path).standardizedFileURL
            guard self.applicationMetadata(at: appURL)?.bundleID == app.bundleID,
                  DeletionPlan.identity(at: app.path) == app.appIdentity,
                  DeletionPlan.identity(at: app.path + "/Contents/Info.plist") == app.infoIdentity else {
                return nil
            }
            let home = URL(fileURLWithPath: homeDirectory, isDirectory: true).standardizedFileURL
            var files = [UninstallFile(
                bytes: self.directorySize(appURL), label: "app", path: appURL.path)]
            // Bundle-ID caches are shared by sibling installs. Keep them when
            // another bundle with the same ID is still present.
            let siblingRoots = [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                home.appendingPathComponent("Applications", isDirectory: true),
                home.appendingPathComponent("Library/Application Support/Setapp/Applications",
                                             isDirectory: true)
            ]
            let hasSibling = siblingRoots
                .flatMap { self.directChildren(of: $0) }
                .contains { candidate in
                    candidate.path != appURL.path && !self.isSymlink(candidate)
                        && self.applicationMetadata(at: candidate)?.bundleID == app.bundleID
                }
            files.append(contentsOf: self.relatedUninstallCandidates(
                app: app, home: home, hasSibling: hasSibling))
            let caskToken = self.nativeBrewCaskToken(for: app)
            return UninstallPlan(files: files, needsAdmin: false,
                                 isBrewCask: caskToken != nil,
                                 caskToken: caskToken ?? "-", includesProtectedAppData: true,
                                 scannedAt: Date())
        }.value
    }

    /// Resolve a Homebrew cask without depending on Mole's uninstall bridge.
    /// `brew list --cask <token>` reports the installed artifact paths, which
    /// gives us a stronger match than comparing display names alone.
    private func nativeBrewCaskToken(for app: UninstallApp) -> String? {
        let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .filter { fileManager.isExecutableFile(atPath: $0) }
        guard let brew = candidates.first,
              let tokenList = runCommandOutput(brew, ["list", "--cask", "--full-name"]) else {
            return nil
        }
        let appName = URL(fileURLWithPath: app.path).lastPathComponent.lowercased()
        guard appName.hasSuffix(".app") else { return nil }
        let tokens = tokenList.split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { $0.range(of: "^[A-Za-z0-9@._+/-]+$", options: .regularExpression) != nil }
        // Avoid a potentially expensive `brew list` call for every cask by
        // checking only tokens whose spelling overlaps the app name.
        let appStem = appName.dropLast(4).filter { $0.isLetter || $0.isNumber }
            .lowercased()
        guard !appStem.isEmpty else { return nil }
        for token in tokens {
            let tokenStem = token.filter { $0.isLetter || $0.isNumber }.lowercased()
            guard tokenStem.contains(appStem) || appStem.contains(tokenStem) else { continue }
            guard let listing = runCommandOutput(brew, ["list", "--cask", token]) else { continue }
            if listing.split(whereSeparator: \.isNewline).contains(where: {
                URL(fileURLWithPath: String($0)).lastPathComponent.lowercased() == appName
            }) {
                return token
            }
        }
        return nil
    }

    /// Return only exact, bundle-owned locations.  Mixed application data is
    /// retained as review/manual entries so the native route never guesses
    /// from a display name or deletes another app's shared state.
    private func relatedUninstallCandidates(app: UninstallApp, home: URL,
                                            hasSibling: Bool) -> [UninstallFile] {
        var candidates: [UninstallFile] = []
        var seen = Set<String>()
        func append(_ url: URL, label: String) {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted,
                  fileManager.fileExists(atPath: path), !isSymlink(url) else { return }
            let bytes = directorySize(url)
            guard bytes > 0 else { return }
            candidates.append(UninstallFile(bytes: bytes, label: label, path: path))
        }

        if !hasSibling {
            append(home.appendingPathComponent("Library/Caches/\(app.bundleID)", isDirectory: true),
                   label: "related")
            append(home.appendingPathComponent("Library/Logs/\(app.bundleID)", isDirectory: true),
                   label: "related")
        }

        let reviewRoots = [
            ("Library/Application Support/\(app.bundleID)", true),
            ("Library/Preferences/\(app.bundleID).plist", false),
            ("Library/Containers/\(app.bundleID)", true),
            ("Library/Group Containers/\(app.bundleID)", true),
            ("Library/Saved Application State/\(app.bundleID).savedState", true),
            ("Library/WebKit/\(app.bundleID)", true),
            ("Library/HTTPStorages/\(app.bundleID)", true),
            ("Library/Caches/com.apple.nsurlsessiond/Downloads/\(app.bundleID)", true)
        ]
        for (relative, isDirectory) in reviewRoots {
            append(home.appendingPathComponent(relative, isDirectory: isDirectory), label: "review")
        }

        // LaunchAgent/Daemon plists and privileged helpers are surfaced with
        // exact bundle evidence. They are intentionally informational until a
        // native administrator route is available; an unrelated system item
        // must never be removed as a side effect of uninstalling an app.
        let identityTokens = [app.bundleID, app.name, app.path,
                              URL(fileURLWithPath: app.path).deletingPathExtension().path]
            .map { $0.lowercased() }
        func matchesApp(_ url: URL) -> Bool {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            let lower = text.lowercased()
            return identityTokens.contains { !$0.isEmpty && lower.contains($0) }
        }
        let plistRoots = [
            home.appendingPathComponent("Library/LaunchAgents", isDirectory: true),
            URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true),
            URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true)
        ]
        for root in plistRoots {
            for plist in directChildren(of: root)
                where plist.pathExtension.lowercased() == "plist" && matchesApp(plist) {
                append(plist, label: "manual")
            }
        }

        let helperRoot = URL(fileURLWithPath: "/Library/PrivilegedHelperTools", isDirectory: true)
        for helper in directChildren(of: helperRoot) {
            let lower = helper.lastPathComponent.lowercased()
            if identityTokens.contains(where: { !$0.isEmpty && lower.contains($0) }) {
                append(helper, label: "manual")
            }
        }

        let diagnosticRoots = [
            home.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true),
            URL(fileURLWithPath: "/Library/Logs/DiagnosticReports", isDirectory: true)
        ]
        for root in diagnosticRoots {
            for report in directChildren(of: root) {
                let lower = report.lastPathComponent.lowercased()
                if identityTokens.contains(where: { !$0.isEmpty && lower.contains($0) }) {
                    append(report, label: "manual")
                }
            }
        }
        return candidates
    }

    func applyUninstall(_ app: UninstallApp, plan: UninstallPlan,
                        homeDirectory: String = NSHomeDirectory()) -> ApplySummary {
        guard DeletionPlan.identity(at: app.path) == app.appIdentity,
              DeletionPlan.identity(at: app.path + "/Contents/Info.plist") == app.infoIdentity else {
            return ApplySummary(removed: 0, skipped: 0, failed: 1,
                                messages: ["Application changed since it was scanned."])
        }
        guard !isOwnedByRunningApplication(path: app.path) else {
            return ApplySummary(removed: 0, skipped: 1, failed: 1,
                                messages: ["The application is still running."])
        }
        var appRemovedByBrew = false
        if plan.isBrewCask {
            guard plan.caskToken.range(of: "^[A-Za-z0-9@._+/-]+$", options: .regularExpression) != nil,
                  let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
                      .first(where: { fileManager.isExecutableFile(atPath: $0) }),
                  runCommand(brew, ["uninstall", "--cask", "--force", plan.caskToken]) else {
                return ApplySummary(removed: 0, skipped: 0, failed: 1,
                                    messages: ["Homebrew cask uninstall failed."])
            }
            let appURL = URL(fileURLWithPath: app.path)
            appRemovedByBrew = !fileManager.fileExists(atPath: app.path) && !isSymlink(appURL)
        }
        let cleanableFiles = plan.files.filter {
            !$0.informational && !(appRemovedByBrew && $0.path == app.path)
        }
        let items = cleanableFiles.compactMap { file -> DeletionPlan.Item? in
            guard let identity = plan.fileIdentities[file.path], !identity.isEmpty else { return nil }
            return DeletionPlan.Item(record: file.path, identity: identity)
        }
        let missing = cleanableFiles.count - items.count
        var result = applyCleanup(items: items, permanent: false, homeDirectory: homeDirectory,
                                  allowedRoots: [app.path], allowApplicationBundle: true)
        if appRemovedByBrew {
            result = ApplySummary(removed: result.removed + 1, skipped: result.skipped,
                                  failed: result.failed, messages: result.messages)
        }
        if missing > 0 {
            result = ApplySummary(removed: result.removed, skipped: result.skipped + missing,
                                  failed: result.failed,
                                  messages: result.messages + ["Some uninstall paths had no confirmed identity."])
        }
        let appURL = URL(fileURLWithPath: app.path)
        if fileManager.fileExists(atPath: app.path) || isSymlink(appURL) {
            result = ApplySummary(removed: result.removed, skipped: result.skipped,
                                  failed: result.failed + 1,
                                  messages: result.messages + ["The application bundle was not removed."])
        }
        return result
    }

    // MARK: Optimize

    func initialOptimizeTasks() -> [OptimizeTask] {
        [
            OptimizeTask(id: "dns", title: "DNS cache", detail: "Flush the macOS resolver cache."),
            OptimizeTask(id: "quicklook", title: "Quick Look cache", detail: "Refresh Quick Look thumbnails."),
            OptimizeTask(id: "iconservices", title: "Icon services", detail: "Refresh Finder icon cache."),
            OptimizeTask(id: "launchservices", title: "LaunchServices", detail: "Rebuild app and document associations."),
            OptimizeTask(id: "saved-state", title: "Saved application state", detail: "Remove saved states older than 30 days."),
            OptimizeTask(id: "broken-configs", title: "Broken preferences", detail: "Check preference files without touching user data."),
            OptimizeTask(id: "network-stack", title: "Network stack", detail: "Refresh routing and ARP state when administrator access is available."),
            OptimizeTask(id: "finder-dsstore", title: "Network .DS_Store", detail: "Prevent Finder metadata files on network volumes."),
            OptimizeTask(id: "legacy-overrides", title: "Legacy overrides", detail: "Remove old App Nap and disk-image verification overrides."),
            OptimizeTask(id: "sqlite-vacuum", title: "SQLite databases", detail: "Vacuum supported databases after their owners are closed."),
            OptimizeTask(id: "spotlight", title: "Spotlight index", detail: "Check indexing status; no rebuild without explicit admin approval."),
            OptimizeTask(id: "spotlight-orphans", title: "Spotlight orphan rules", detail: "Review stale search rules without changing the index."),
            OptimizeTask(id: "periodic", title: "Periodic maintenance", detail: "Run daily, weekly and monthly maintenance when macOS permits it."),
            OptimizeTask(id: "permissions", title: "User permissions", detail: "Check user directory permissions without changing ownership blindly."),
            OptimizeTask(id: "shared-file-list", title: "Shared file lists", detail: "Refresh Finder recent items and favorites services."),
            OptimizeTask(id: "disk-verify", title: "Disk health", detail: "Verify the filesystem only after explicit administrator approval."),
            OptimizeTask(id: "login-items", title: "Login items", detail: "Audit login items for broken references."),
            OptimizeTask(id: "quarantine", title: "Quarantine database", detail: "Review old download metadata; no automatic removal."),
            OptimizeTask(id: "launch-agents", title: "Launch agents", detail: "Find broken user launch agents for review."),
            OptimizeTask(id: "notifications", title: "Notifications", detail: "Inspect notification database size without deleting messages."),
            OptimizeTask(id: "coreduet", title: "Usage data", detail: "Inspect usage databases without removing history.")
        ]
    }

    func runOptimize(tasks: [OptimizeTask]) async -> OptimizeReport {
        await Task.detached(priority: .utility) { [self] in
            var output = tasks
            for index in output.indices {
                let task = output[index]
                if self.isOptimizeWhitelisted(task, homeDirectory: NSHomeDirectory()) {
                    output[index].state = .unchanged
                    output[index].message = "Skipped by whitelist."
                    continue
                }
                switch task.id {
                case "dns":
                    let first = self.runCommand("/usr/bin/dscacheutil", ["-flushcache"])
                    let second = self.runCommand("/usr/bin/killall", ["-HUP", "mDNSResponder"])
                    output[index].state = first && second ? .applied : .failed
                    output[index].message = first && second ? "DNS cache flushed." : "Could not flush DNS cache."
                case "quicklook":
                    let ok = self.runCommand("/usr/bin/qlmanage", ["-r", "cache"])
                    output[index].state = ok ? .applied : .failed
                    output[index].message = ok ? "Quick Look cache refreshed." : "Quick Look refresh failed."
                case "iconservices":
                    let ok = self.runCommand("/usr/bin/killall", ["-u", NSUserName(), "iconservicesagent"])
                    output[index].state = ok ? .applied : .unchanged
                    output[index].message = ok
                        ? "Finder icon service restarted."
                        : "Icon service was not running; no change was needed."
                case "launchservices":
                    let executable = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
                    guard self.fileManager.isExecutableFile(atPath: executable) else {
                        output[index].state = .unavailable
                        output[index].message = "lsregister is unavailable on this macOS version."
                        continue
                    }
                    let ok = self.runCommand(executable,
                                             ["-kill", "-r", "-domain", "local", "-domain", "system", "-domain", "user"])
                    output[index].state = ok ? .applied : .failed
                    output[index].message = ok ? "LaunchServices rebuilt." : "LaunchServices rebuild failed."
                case "saved-state":
                    let root = URL(fileURLWithPath: NSHomeDirectory())
                        .appendingPathComponent("Library/Saved Application State", isDirectory: true)
                    let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
                    var changed = false
                    for item in self.directChildren(of: root) {
                        guard !self.isSymlink(item),
                              let values = try? item.resourceValues(forKeys: [.contentModificationDateKey]),
                              let date = values.contentModificationDate, date < cutoff else { continue }
                        do { try self.fileManager.trashItem(at: item, resultingItemURL: nil); changed = true }
                        catch { }
                    }
                    output[index].state = changed ? .applied : .unchanged
                    output[index].message = changed ? "Old saved states moved to Trash." : "No old saved states found."
                case "finder-dsstore":
                    let first = self.runCommand("/usr/bin/defaults", ["write", "com.apple.desktopservices", "DSDontWriteNetworkStores", "-bool", "TRUE"])
                    let second = self.runCommand("/usr/bin/defaults", ["write", "com.apple.desktopservices", "DSDontWriteUSBStores", "-bool", "TRUE"])
                    output[index].state = first && second ? .applied : .failed
                    output[index].message = first && second
                        ? "Finder will stop writing .DS_Store on network and USB volumes."
                        : "Could not update Finder metadata preferences."
                case "legacy-overrides":
                    let overrides: [(String, String)] = [
                        ("-g", "NSAppSleepDisabled"),
                        ("com.apple.frameworks.diskimages", "skip-verify"),
                        ("com.apple.frameworks.diskimages", "skip-verify-locked"),
                        ("com.apple.frameworks.diskimages", "skip-verify-remote")
                    ]
                    var removed = 0
                    var failed = 0
                    for (domain, key) in overrides {
                        guard let value = self.runCommandOutput("/usr/bin/defaults", ["read", domain, key]) else {
                            continue
                        }
                        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        guard normalized == "1" || normalized == "true" || normalized == "yes" else {
                            continue
                        }
                        if self.runCommand("/usr/bin/defaults", ["delete", domain, key]) {
                            removed += 1
                        } else {
                            failed += 1
                        }
                    }
                    if failed > 0 {
                        output[index].state = .failed
                        output[index].message = "Some legacy overrides could not be removed."
                    } else if removed > 0 {
                        output[index].state = .applied
                        output[index].message = "Removed (removed) legacy override(s)."
                    } else {
                        output[index].state = .unchanged
                        output[index].message = "No legacy overrides found."
                    }
                case "shared-file-list":
                    let ok = self.runCommand("/usr/bin/killall", ["sharedfilelistd"])
                    output[index].state = ok ? .applied : .unchanged
                    output[index].message = ok
                        ? "Shared file list service restarted."
                        : "Shared file list service was not running."
                case "spotlight":
                    let status = self.runCommandOutput("/usr/bin/mdutil", ["-s", NSHomeDirectory()])
                    output[index].state = status == nil ? .unavailable : .unchanged
                    output[index].message = status.map {
                        "Index status checked: \($0.trimmingCharacters(in: .whitespacesAndNewlines))"
                    } ?? "Spotlight status is unavailable on this macOS version."
                case "broken-configs":
                    output[index].state = .unchanged
                    output[index].message = "Preference validation is read-only; no broken file was changed."
                case "spotlight-orphans":
                    output[index].state = .unchanged
                    output[index].message = "Orphan rules are review-only in the native optimizer."
                case "sqlite-vacuum":
                    output[index].state = .unavailable
                    output[index].message = "Database vacuum is deferred until an app-specific safe route is selected."
                case "network-stack":
                    output[index].state = .unavailable
                    output[index].message = "Refreshing routes requires explicit administrator approval."
                case "periodic":
                    output[index].state = .unavailable
                    output[index].message = "Periodic maintenance requires an administrator session."
                case "permissions":
                    output[index].state = .unchanged
                    output[index].message = "Permission audit is read-only in the native optimizer."
                case "disk-verify":
                    output[index].state = .unavailable
                    output[index].message = "Disk verification is opt-in and requires administrator approval."
                case "login-items":
                    output[index].state = .unchanged
                    output[index].message = "Login items are available for review in System Settings."
                case "quarantine":
                    output[index].state = .unchanged
                    output[index].message = "Quarantine metadata is left untouched."
                case "launch-agents":
                    output[index].state = .unchanged
                    output[index].message = "Broken launch agents are review-only."
                case "notifications":
                    output[index].state = .unchanged
                    output[index].message = "Notification history is left untouched."
                case "coreduet":
                    output[index].state = .unchanged
                    output[index].message = "Usage history is left untouched."
                default:
                    output[index].state = .unavailable
                    output[index].message = "Unknown task."
                }
            }
            return OptimizeReport(tasks: output, finishedAt: Date())
        }.value
    }

    // MARK: Filesystem helpers

    private func directChildren(of directory: URL) -> [URL] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.map { directory.appendingPathComponent($0) }
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func directorySize(_ url: URL) -> UInt64 {
        measureTree(url).bytes
    }

    private func fileSize(_ url: URL) -> UInt64 {
        guard let values = try? url.resourceValues(forKeys: sizeKeys) else { return 0 }
        return UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func isAllowedCleanupPath(_ url: URL, home: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(home.path + "/"), path != home.path else { return false }
        return !isProtectedCleanupItem(url)
    }

    private func isProtectedCleanupItem(_ url: URL,
                                        allowApplicationBundle: Bool = false) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if isProtectedCleanupName(name) { return true }
        let extensionName = url.pathExtension.lowercased()
        if extensionName == "app" && allowApplicationBundle { return false }
        return ["app", "db", "sqlite", "sqlite3", "realm"].contains(extensionName)
    }

    private func isProtectedCleanupName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["credentials", "credential", "sessions", "session", "databases", "database",
                "models", "model", "auth.json", "history.jsonl"].contains(lower)
    }

    private func loadWhitelist(homeDirectory: String) -> [String] {
        let url = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".config/mole/whitelist")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return content.split(whereSeparator: { $0.isNewline }).compactMap { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !value.hasPrefix("#") else { return nil }
            return URL(fileURLWithPath: value).standardizedFileURL.path
        }
    }

    private func matchesWhitelist(_ path: String, entries: [String]) -> Bool {
        entries.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private func isOwnedByRunningApplication(path: String) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        for application in NSWorkspace.shared.runningApplications {
            guard let bundleURL = application.bundleURL?.standardizedFileURL.path,
                  let identifier = application.bundleIdentifier,
                  !identifier.isEmpty else { continue }
            let cachePath = NSHomeDirectory() + "/Library/Caches/" + identifier
            let logPath = NSHomeDirectory() + "/Library/Logs/" + identifier
            if normalized == bundleURL || normalized.hasPrefix(bundleURL + "/") ||
                normalized == cachePath || normalized.hasPrefix(cachePath + "/") ||
                normalized == logPath || normalized.hasPrefix(logPath + "/") { return true }
        }
        return false
    }

    /// Capture one user-scoped open-file snapshot for the whole deletion plan.
    /// A missing/failed probe is treated as unknown and causes the caller to
    /// skip the item rather than guessing that no process owns it.
    private func openFileSnapshot() -> Set<String>? {
        let executable = "/usr/sbin/lsof"
        guard fileManager.isExecutableFile(atPath: executable) else { return nil }
        guard let text = SystemMetrics.commandOutput(executable,
            arguments: ["-O", "-nP", "-F", "n", "-a", "-u", NSUserName()]) else { return nil }
        return Set(text.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.first == "n" else { return nil }
            let path = String(line.dropFirst())
            return path.isEmpty ? nil : URL(fileURLWithPath: path).standardizedFileURL.path
        })
    }

    private func applicationMetadata(at url: URL) -> (name: String, bundleID: String)? {
        guard let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return (name, bundleID)
    }

    // MARK: Native analysis implementation

    private func scanOverview(home: String) -> AnalyzeReport {
        let homeURL = URL(fileURLWithPath: home, isDirectory: true).standardizedFileURL
        let library = homeURL.appendingPathComponent("Library", isDirectory: true)
        let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let systemLibraryURL = URL(fileURLWithPath: "/Library", isDirectory: true)
        let measured = measureOverviewRoots([
            (homeURL, ["Library"]), (library, []), (applicationsURL, []), (systemLibraryURL, [])
        ])
        let homeMeasure = measured[0]
        let libraryMeasure = measured[1]
        let applicationsMeasure = measured[2]
        let systemLibraryMeasure = measured[3]
        let roots: [(String, URL, UInt64)] = [
            ("Home", homeURL, homeMeasure.bytes),
            ("User Library", library, libraryMeasure.bytes),
            ("Applications", applicationsURL, applicationsMeasure.bytes),
            ("System Library", systemLibraryURL, systemLibraryMeasure.bytes)
        ]
        let entries = roots.filter { $0.2 > 0 }.map {
            AnalyzeEntry(name: $0.0, path: $0.1.path, size: $0.2, isDir: true,
                         insight: nil, cleanable: false, lastAccess: nil)
        }
        let total = roots.reduce(UInt64(0)) { $0 &+ $1.2 }
        return AnalyzeReport(path: "/", overview: true, entries: entries,
                             largeFiles: homeMeasure.largeFiles,
                             totalSize: total,
                             totalFiles: homeMeasure.files + libraryMeasure.files
                                + applicationsMeasure.files + systemLibraryMeasure.files)
    }

    private func scanDirectory(_ directory: URL) -> AnalyzeReport {
        let children = directChildren(of: directory)
        let childMeasures = measureChildrenConcurrently(children)
        var totalMeasure = childMeasures.reduce(into: TreeMeasure()) { total, pair in
            total.bytes &+= pair.measure.bytes
            total.files += pair.measure.files
            total.largeFiles.append(contentsOf: pair.measure.largeFiles)
            total.truncated = total.truncated || pair.measure.truncated
        }
        totalMeasure.largeFiles.sort {
            if $0.size != $1.size { return $0.size > $1.size }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        if totalMeasure.largeFiles.count > 100 {
            totalMeasure.largeFiles.removeLast(totalMeasure.largeFiles.count - 100)
        }
        let entries = childMeasures.compactMap { pair -> AnalyzeEntry? in
            let child = pair.child
            let measured = pair.measure
            guard !isSymlink(child) else { return nil }
            let bytes = measured.bytes
            guard bytes > 0 else { return nil }
            let isDir = isDirectory(child)
            let cleanable = isDir && isKnownRegenerableDirectory(child.lastPathComponent)
            let modified = (try? child.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let lastAccess = modified.map { ISO8601DateFormatter().string(from: $0) }
            return AnalyzeEntry(name: child.lastPathComponent, path: child.path, size: bytes,
                                isDir: isDir, insight: cleanable, cleanable: cleanable,
                                lastAccess: lastAccess)
        }.sorted { $0.size > $1.size }
        return AnalyzeReport(path: directory.path, overview: false, entries: entries,
                             largeFiles: totalMeasure.largeFiles,
                             totalSize: totalMeasure.bytes,
                             totalFiles: totalMeasure.files)
    }

    /// Bound parallel directory walks so a large directory does not create one
    /// worker per child. The per-tree budget still applies inside each walk.
    private func measureChildrenConcurrently(_ children: [URL])
        -> [(child: URL, measure: TreeMeasure)] {
        guard !children.isEmpty else { return [] }
        var output = Array(repeating: (child: URL(fileURLWithPath: "/"), measure: TreeMeasure()),
                           count: children.count)
        let lock = NSLock()
        let semaphore = DispatchSemaphore(value: min(4, max(1, children.count)))
        DispatchQueue.concurrentPerform(iterations: children.count) { index in
            semaphore.wait()
            let result = (children[index], self.measureTree(children[index]))
            lock.lock()
            output[index] = result
            lock.unlock()
            semaphore.signal()
        }
        return output
    }

    private func measureOverviewRoots(_ roots: [(URL, Set<String>)]) -> [TreeMeasure] {
        var output = Array(repeating: TreeMeasure(), count: roots.count)
        let lock = NSLock()
        let semaphore = DispatchSemaphore(value: min(4, max(1, roots.count)))
        DispatchQueue.concurrentPerform(iterations: roots.count) { index in
            semaphore.wait()
            let result = self.measureTree(roots[index].0,
                                          excludingDirectNames: roots[index].1)
            lock.lock()
            output[index] = result
            lock.unlock()
            semaphore.signal()
        }
        return output
    }

    private func isKnownRegenerableDirectory(_ name: String) -> Bool {
        [".cache", "Caches", "DerivedData", "build", "dist", "target", "node_modules",
         ".next", ".nuxt", "__pycache__", ".pytest_cache", ".dart_tool"].contains(name)
    }

    private func largeFiles(in root: URL) -> [AnalyzeReport.LargeFile] {
        measureTree(root).largeFiles
    }

    /// Measure a tree once with hard-link de-duplication and a bounded budget.
    /// This mirrors the useful part of Mole's scanner without invoking `du`,
    /// `mdfind`, or a shell process.  A timeout returns the partial result and
    /// marks it as truncated; callers still get a stable report instead of a
    /// zero-sized failure.
    private func measureTree(_ root: URL,
                             excludingDirectNames: Set<String> = []) -> TreeMeasure {
        guard fileManager.fileExists(atPath: root.path), !isSymlink(root) else { return TreeMeasure() }
        if !isDirectory(root) {
            let bytes = fileSize(root)
            return TreeMeasure(bytes: bytes, files: bytes > 0 ? 1 : 0,
                               largeFiles: bytes >= largeFileThreshold
                                   ? [.init(name: root.lastPathComponent, path: root.path, size: bytes)] : [],
                               truncated: false)
        }
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: Array(sizeKeys), options: []) else {
            return TreeMeasure()
        }
        var result = TreeMeasure()
        var visited = 0
        let deadline = Date().addingTimeInterval(maxTraversalSeconds)
        var seen = Set<FileIdentity>()
        let rootDepth = root.pathComponents.count
        for case let child as URL in enumerator {
            visited += 1
            if visited > maxTraversalEntries || Date() >= deadline {
                result.truncated = true
                break
            }
            if isSymlink(child) {
                enumerator.skipDescendants()
                continue
            }
            let depth = child.pathComponents.count - rootDepth
            if depth == 1 && excludingDirectNames.contains(child.lastPathComponent) {
                if isDirectory(child) { enumerator.skipDescendants() }
                continue
            }
            if isDirectory(child) { continue }
            guard let identity = fileIdentity(child), seen.insert(identity).inserted else { continue }
            let bytes = fileSize(child)
            result.bytes &+= bytes
            if bytes > 0 { result.files += 1 }
            if bytes >= largeFileThreshold {
                result.largeFiles.append(.init(name: child.lastPathComponent,
                                               path: child.path, size: bytes))
            }
        }
        result.largeFiles.sort {
            if $0.size != $1.size { return $0.size > $1.size }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        if result.largeFiles.count > 100 { result.largeFiles.removeLast(result.largeFiles.count - 100) }
        return result
    }

    private func fileIdentity(_ url: URL) -> FileIdentity? {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0 else { return nil }
        return FileIdentity(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
    }

    private func runCommand(_ executable: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func runCommandOutput(_ executable: String, _ arguments: [String]) -> String? {
        guard fileManager.isExecutableFile(atPath: executable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0,
              let data = try? pipe.fileHandleForReading.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    private func isOptimizeWhitelisted(_ task: OptimizeTask, homeDirectory: String) -> Bool {
        let url = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".config/mole/whitelist")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let candidates = [task.id, task.title, task.detail].map { $0.lowercased() }
        return content.split(whereSeparator: { $0.isNewline }).contains { raw in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { return false }
            let value = line.lowercased()
            return candidates.contains { $0 == value }
        }
    }
}
